# Plan 2 Phase 2a: iOS Auth + Networking Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** iOS app gains a real email-OTP login. After login, the session token is persisted in Keychain (30-day), and the 我的 tab shows the user's email + license status + logout. This is the foundation every other Phase 2 feature (corpus, library) builds on — they all need an authenticated session.

**Architecture:** A `WhatsubAPI` actor wraps URLSession + Codable DTOs + an `APIError` enum. `KeychainStore` persists the `Session`. `AuthViewModel` (ObservableObject) drives the `AuthGateView` (email → 6-digit code → session). `AppState` holds the session; the root scene shows `AuthGateView` as a full-screen cover until a valid session exists. On any 401, the session is cleared and the gate reappears.

**Tech Stack:** SwiftUI · async/await · URLSession · Security framework (Keychain) · XCTest (unit tests run in CI on macos-15) · XcodeGen.

**Working dir:** `C:\Users\renjx\Desktop\whatsub-mobile`.

**Backend endpoints (already live in prod, used by the desktop app today):**
- `POST https://whatsub.eversay.cc/api/license/auth/send-code` body `{email}` → `{ok: true}` or `{error}`
- `POST .../api/license/auth/verify-code` body `{email, code}` → `{sessionToken, expiresAt}` or `{error}`
- `GET .../api/license/auth/me` header `Authorization: Bearer <token>` → `{email, hasActiveLicense, isAdmin}`
- `POST .../api/license/auth/logout` header `Authorization: Bearer <token>` → `{ok}`

(The `/api/license/` prefix is nginx-stripped to `/api/` at the backend. The desktop's `auth.rs` uses exactly these URLs — they're proven in prod.)

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `whatsub-mobile/Networking/Endpoints.swift` | Base URLs + path builders | Create |
| `whatsub-mobile/Networking/APIError.swift` | Error enum + Chinese mapping | Create |
| `whatsub-mobile/Networking/DTOs.swift` | Codable request/response structs | Create |
| `whatsub-mobile/Networking/WhatsubAPI.swift` | `actor` wrapping URLSession; auth methods | Create |
| `whatsub-mobile/Auth/Session.swift` | `Session` model (email, token, expiresAt) | Create |
| `whatsub-mobile/Auth/KeychainStore.swift` | Save/load/delete Session in Keychain | Create |
| `whatsub-mobile/Auth/AuthViewModel.swift` | `ObservableObject` for the login flow | Create |
| `whatsub-mobile/Auth/AuthGateView.swift` | Email → OTP UI (replaces nothing; new) | Create |
| `whatsub-mobile/App/AppState.swift` | Hold `session`, `currentUser`; load on launch | Modify (replace stub) |
| `whatsub-mobile/App/WhatsubMobileApp.swift` | Show AuthGateView cover until session valid | Modify |
| `whatsub-mobile/Me/MeView.swift` | Replace placeholder: real email + license + logout | Create (replace MePlaceholderView usage) |
| `whatsub-mobile/App/WhatsubMobileApp.swift` | Swap MePlaceholderView → MeView in tab 3 | Modify |
| `project.yml` | Add a unit-test target | Modify |
| `whatsub-mobileTests/DTOTests.swift` | Decode sample JSON → DTOs | Create |
| `whatsub-mobileTests/APIErrorTests.swift` | Error → Chinese mapping | Create |
| `.github/workflows/ci.yml` | Run `xcodebuild test` + screenshot AuthGate via launch-arg mock | Modify |

**Existing scaffold to keep:** `CorpusPlaceholderView` + `LibraryPlaceholderView` stay as placeholders (Phase 2b/2c replace them). Only the 我的 tab gets a real view in 2a.

---

## Pre-flight

- [ ] **Confirm clean state on main**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git status                 # working tree clean (ci-screenshot png + AuthKey .p8 are gitignored/untracked)
git checkout main && git pull
git checkout -b feat/ios-phase2a-auth
```

Note: there is no local Xcode, so Swift compiles + tests only run in CI on push. Each task's "verify" is either a local non-Swift check (yaml lint) OR deferred to the CI run at the end. Plan tasks COMMIT frequently; the FINAL task pushes + watches CI green.

---

### Task 1: Session model + KeychainStore

**Files:**
- Create: `whatsub-mobile/Auth/Session.swift`
- Create: `whatsub-mobile/Auth/KeychainStore.swift`

- [ ] **Step 1: Session.swift**

```swift
import Foundation

/// A logged-in session. Persisted in Keychain; mirrors the backend's
/// verify-code response + the email used to obtain it.
struct Session: Codable, Equatable {
    let email: String
    let sessionToken: String
    /// Unix ms (matches the backend's `expiresAt`).
    let expiresAt: Int64

    var isValid: Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return expiresAt > nowMs
    }
}
```

- [ ] **Step 2: KeychainStore.swift**

```swift
import Foundation
import Security

/// Stores the Session as a single JSON blob in the iOS Keychain under one
/// generic-password item. Accessible after first unlock (so a backgrounded
/// app can still read it, but it's not in an always-accessible class).
enum KeychainStore {
    private static let service = "cc.eversay.whatsub.mobile.session"
    private static let account = "session"

    static func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        // Delete any existing item first (SecItemUpdate is fiddlier).
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func load() -> Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git add whatsub-mobile/Auth/Session.swift whatsub-mobile/Auth/KeychainStore.swift
git commit -m "feat(ios/auth): Session model + KeychainStore"
```

---

### Task 2: Endpoints + APIError + DTOs

**Files:**
- Create: `whatsub-mobile/Networking/Endpoints.swift`
- Create: `whatsub-mobile/Networking/APIError.swift`
- Create: `whatsub-mobile/Networking/DTOs.swift`

- [ ] **Step 1: Endpoints.swift**

```swift
import Foundation

/// Central URL builder. Three bases because nginx routes them differently:
/// - auth lives under /api/license/auth/* (nginx strips /license → backend /api/auth/*)
/// - corpus + library are verbatim /api/corpus/* and /api/library/*
enum Endpoints {
    static let authBase = "https://whatsub.eversay.cc/api/license/auth"
    static let corpusBase = "https://whatsub.eversay.cc/api/corpus"
    static let libraryBase = "https://whatsub.eversay.cc/api/library"

    static func auth(_ path: String) -> URL { URL(string: "\(authBase)/\(path)")! }
    static func corpus(_ path: String) -> URL { URL(string: "\(corpusBase)/\(path)")! }
    static func library(_ path: String) -> URL { URL(string: "\(libraryBase)/\(path)")! }
}
```

- [ ] **Step 2: APIError.swift**

```swift
import Foundation

enum APIError: Error, Equatable {
    case network(String)         // transport failure (no connection, timeout, TLS)
    case unauthorized            // 401 — session expired/invalid
    case server(Int, String?)    // non-2xx with a parsed `error` string if any
    case decoding(String)        // response didn't match the expected shape
    case badInput(String)        // client-side validation (e.g. bad email)

    /// Chinese message for display in the UI.
    var chinese: String {
        switch self {
        case .network(let detail):
            return "网络连接失败：\(detail)"
        case .unauthorized:
            return "登录已过期，请重新登录"
        case .server(let code, let err):
            switch err {
            case "invalid_email": return "邮箱格式不对"
            case "invalid_input": return "输入有误"
            case "no_code": return "请先获取验证码"
            case "wrong_code": return "验证码错误"
            case "too_many_attempts": return "尝试次数过多，请重新获取验证码"
            default: return "服务器错误（\(code)）"
            }
        case .decoding(let detail):
            return "数据解析失败：\(detail)"
        case .badInput(let detail):
            return detail
        }
    }
}
```

- [ ] **Step 3: DTOs.swift**

```swift
import Foundation

// ----- Auth -----

struct SendCodeRequest: Encodable { let email: String }

struct VerifyCodeRequest: Encodable {
    let email: String
    let code: String
}

struct VerifyCodeResponse: Decodable {
    let sessionToken: String
    let expiresAt: Int64
}

struct MeResponse: Decodable {
    let email: String
    let hasActiveLicense: Bool
    let isAdmin: Bool?
}

/// Generic `{ ok: true }` or `{ error: "..." }` envelope used by several routes.
struct OkResponse: Decodable { let ok: Bool? }
struct ErrorResponse: Decodable { let error: String? }
```

- [ ] **Step 4: Commit**

```bash
git add whatsub-mobile/Networking/
git commit -m "feat(ios/net): Endpoints + APIError + auth DTOs"
```

---

### Task 3: WhatsubAPI actor (auth methods)

**Files:**
- Create: `whatsub-mobile/Networking/WhatsubAPI.swift`

- [ ] **Step 1: WhatsubAPI.swift**

```swift
import Foundation

/// All backend HTTP lives here. An actor so concurrent calls serialize their
/// access to the (rare) shared state and so the type is Sendable-safe.
actor WhatsubAPI {
    static let shared = WhatsubAPI()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // ----- Auth -----

    func sendCode(email: String) async throws {
        let body = try JSONEncoder().encode(SendCodeRequest(email: email))
        _ = try await postExpectingOk(Endpoints.auth("send-code"), body: body, bearer: nil)
    }

    func verifyCode(email: String, code: String) async throws -> Session {
        let body = try JSONEncoder().encode(VerifyCodeRequest(email: email, code: code))
        let data = try await post(Endpoints.auth("verify-code"), body: body, bearer: nil)
        let resp = try decode(VerifyCodeResponse.self, from: data)
        return Session(email: email, sessionToken: resp.sessionToken, expiresAt: resp.expiresAt)
    }

    func me(token: String) async throws -> MeResponse {
        let data = try await get(Endpoints.auth("me"), bearer: token)
        return try decode(MeResponse.self, from: data)
    }

    func logout(token: String) async throws {
        _ = try? await postExpectingOk(Endpoints.auth("logout"), body: Data("{}".utf8), bearer: token)
    }

    // ----- HTTP primitives -----

    private func get(_ url: URL, bearer: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyBearer(&req, bearer)
        return try await send(req)
    }

    private func post(_ url: URL, body: Data, bearer: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        applyBearer(&req, bearer)
        return try await send(req)
    }

    @discardableResult
    private func postExpectingOk(_ url: URL, body: Data, bearer: String?) async throws -> Data {
        try await post(url, body: body, bearer: bearer)
    }

    private func applyBearer(_ req: inout URLRequest, _ bearer: String?) {
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("no http response")
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let err = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw APIError.server(http.statusCode, err?.error)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Networking/WhatsubAPI.swift
git commit -m "feat(ios/net): WhatsubAPI actor with auth methods"
```

---

### Task 4: AuthViewModel + AppState

**Files:**
- Create: `whatsub-mobile/Auth/AuthViewModel.swift`
- Modify: `whatsub-mobile/App/AppState.swift`

- [ ] **Step 1: AppState.swift (replace the stub)**

```swift
import Foundation
import SwiftUI

/// Root state. Holds the session + current user. On launch, tries to restore
/// a valid session from Keychain. Exposes a published `isAuthenticated` the
/// root scene reads to decide whether to show the AuthGate.
@MainActor
final class AppState: ObservableObject {
    @Published var session: Session?
    @Published var currentUser: MeResponse?

    var isAuthenticated: Bool { session?.isValid == true }

    init() {
        // Restore a non-expired session synchronously at launch.
        if let saved = KeychainStore.load(), saved.isValid {
            session = saved
        } else if KeychainStore.load() != nil {
            KeychainStore.clear() // expired — drop it
        }
    }

    func setSession(_ s: Session) {
        try? KeychainStore.save(s)
        session = s
    }

    func logout() {
        if let token = session?.sessionToken {
            Task { await WhatsubAPI.shared.logout(token: token) }
        }
        KeychainStore.clear()
        session = nil
        currentUser = nil
    }

    /// Called after login + on app foreground to refresh license status.
    func refreshMe() async {
        guard let token = session?.sessionToken else { return }
        do {
            currentUser = try await WhatsubAPI.shared.me(token: token)
        } catch APIError.unauthorized {
            // Session died server-side — force re-login.
            await MainActor.run { self.forceLogout() }
        } catch {
            // Non-fatal: keep last-known currentUser, UI shows stale-but-usable.
        }
    }

    func forceLogout() {
        KeychainStore.clear()
        session = nil
        currentUser = nil
    }
}
```

- [ ] **Step 2: AuthViewModel.swift**

```swift
import Foundation
import SwiftUI

@MainActor
final class AuthViewModel: ObservableObject {
    enum Step { case email, code }

    @Published var step: Step = .email
    @Published var email: String = ""
    @Published var code: String = ""
    @Published var busy = false
    @Published var error: String?

    private let emailRegex = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#)

    private func emailValid(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return emailRegex.firstMatch(in: s, range: range) != nil
    }

    func sendCode() async {
        let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard emailValid(trimmed) else { error = "邮箱格式不对"; return }
        busy = true; error = nil
        do {
            try await WhatsubAPI.shared.sendCode(email: trimmed)
            email = trimmed
            step = .code
        } catch let e as APIError {
            error = e.chinese
        } catch {
            error = "发送失败，请重试"
        }
        busy = false
    }

    /// Returns the Session on success so the caller (AuthGateView) can hand it
    /// to AppState. Returns nil on failure (error is published).
    func verify() async -> Session? {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            error = "请输入 6 位数字验证码"; return nil
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let s = try await WhatsubAPI.shared.verifyCode(email: email, code: code)
            return s
        } catch let e as APIError {
            error = e.chinese; return nil
        } catch {
            error = "验证失败，请重试"; return nil
        }
    }

    func backToEmail() {
        step = .email
        code = ""
        error = nil
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add whatsub-mobile/Auth/AuthViewModel.swift whatsub-mobile/App/AppState.swift
git commit -m "feat(ios/auth): AppState session restore + AuthViewModel login flow"
```

---

### Task 5: AuthGateView

**Files:**
- Create: `whatsub-mobile/Auth/AuthGateView.swift`

- [ ] **Step 1: AuthGateView.swift**

```swift
import SwiftUI

struct AuthGateView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = AuthViewModel()
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.whatsubBg.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.whatsubAccent)
                    Text("whatSub")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.whatsubInk)
                    Text(vm.step == .email ? "用邮箱登录 · 已购用户自动识别" : "验证码已发到 \(vm.email)")
                        .font(.callout)
                        .foregroundStyle(.whatsubInkMuted)
                        .multilineTextAlignment(.center)
                }

                if vm.step == .email {
                    emailField
                } else {
                    codeField
                }

                if let error = vm.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .onAppear { focused = true }
    }

    private var emailField: some View {
        VStack(spacing: 14) {
            TextField("you@example.com", text: $vm.email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(14)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.whatsubInk)

            Button {
                Task { await vm.sendCode() }
            } label: {
                primaryLabel(vm.busy ? "发送中…" : "发送验证码")
            }
            .disabled(vm.busy)
        }
    }

    private var codeField: some View {
        VStack(spacing: 14) {
            TextField("6 位验证码", text: $vm.code)
                .keyboardType(.numberPad)
                .focused($focused)
                .padding(14)
                .background(Color.whatsubBgElev, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.whatsubInk)
                .onChange(of: vm.code) { _, newValue in
                    if newValue.count > 6 { vm.code = String(newValue.prefix(6)) }
                }

            Button {
                Task {
                    if let s = await vm.verify() {
                        appState.setSession(s)
                        await appState.refreshMe()
                    }
                }
            } label: {
                primaryLabel(vm.busy ? "验证中…" : "验证登录")
            }
            .disabled(vm.busy)

            Button("← 换个邮箱 / 重新发送") { vm.backToEmail() }
                .font(.footnote)
                .foregroundStyle(.whatsubInkMuted)
        }
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.whatsubAccent, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Auth/AuthGateView.swift
git commit -m "feat(ios/auth): AuthGateView email + OTP screen"
```

---

### Task 6: MeView (real account)

**Files:**
- Create: `whatsub-mobile/Me/MeView.swift`

- [ ] **Step 1: MeView.swift**

```swift
import SwiftUI

struct MeView: View {
    @EnvironmentObject var appState: AppState

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.whatsubBg.ignoresSafeArea()
                List {
                    Section("账号") {
                        LabeledContent("邮箱", value: appState.session?.email ?? "—")
                            .foregroundStyle(.whatsubInk)
                        licenseRow
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    if appState.currentUser?.hasActiveLicense == false {
                        Section {
                            Link(destination: URL(string: "https://whatsub.eversay.cc/#pricing")!) {
                                Label("去网站购买授权", systemImage: "cart")
                                    .foregroundStyle(.whatsubAccent)
                            }
                        } footer: {
                            Text("购买后用同一邮箱登录即可解锁公共语料库 + 云端 library。")
                        }
                        .listRowBackground(Color.whatsubBgElev)
                    }

                    Section("关于") {
                        LabeledContent("版本", value: versionString)
                            .foregroundStyle(.whatsubInk)
                        Link("官网 whatsub.eversay.cc", destination: URL(string: "https://whatsub.eversay.cc")!)
                            .foregroundStyle(.whatsubAccent)
                    }
                    .listRowBackground(Color.whatsubBgElev)

                    Section {
                        Button(role: .destructive) {
                            appState.logout()
                        } label: {
                            Text("退出登录").frame(maxWidth: .infinity)
                        }
                    }
                    .listRowBackground(Color.whatsubBgElev)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("我的")
            .task { await appState.refreshMe() }
        }
    }

    @ViewBuilder
    private var licenseRow: some View {
        HStack {
            Text("授权状态").foregroundStyle(.whatsubInk)
            Spacer()
            switch appState.currentUser?.hasActiveLicense {
            case .some(true):
                Label("有效", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            case .some(false):
                Label("未购买", systemImage: "xmark.seal")
                    .foregroundStyle(.whatsubInkMuted)
            case .none:
                Text("查询中…").foregroundStyle(.whatsubInkFaint)
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/Me/MeView.swift
git commit -m "feat(ios/me): real account view — email + license + logout"
```

---

### Task 7: Wire AuthGate + MeView into the app root

**Files:**
- Modify: `whatsub-mobile/App/WhatsubMobileApp.swift`

- [ ] **Step 1: Gate the tabs + swap MeView**

In `WhatsubMobileApp.swift`, change `ContentView` so the TabView only shows when authenticated, otherwise the AuthGateView covers it. Replace the existing `body` of `ContentView`:

```swift
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: Int = 0

    var body: some View {
        Group {
            if appState.isAuthenticated {
                TabView(selection: $selectedTab) {
                    LibraryPlaceholderView()
                        .tabItem { Label("Library", systemImage: "play.rectangle") }
                        .tag(0)

                    CorpusPlaceholderView()
                        .tabItem { Label("语料库", systemImage: "books.vertical") }
                        .tag(1)

                    MeView()
                        .tabItem { Label("我的", systemImage: "person.crop.circle") }
                        .tag(2)
                }
            } else {
                AuthGateView()
            }
        }
    }
}
```

(Note: `MePlaceholderView` is no longer referenced. Leave the file in place for now — a later cleanup task removes it. Or delete it now if you prefer; it has no other references.)

- [ ] **Step 2: Commit**

```bash
git add whatsub-mobile/App/WhatsubMobileApp.swift
git commit -m "feat(ios): gate tabs behind AuthGateView; tab 3 uses MeView"
```

---

### Task 8: Unit-test target + DTO/APIError tests

**Files:**
- Modify: `project.yml` — add a unit-test target
- Create: `whatsub-mobileTests/DTOTests.swift`
- Create: `whatsub-mobileTests/APIErrorTests.swift`

- [ ] **Step 1: Add test target to project.yml**

In `project.yml`, under `targets:`, after the `whatsub-mobile:` app target, add:

```yaml
  whatsub-mobileTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - whatsub-mobileTests
    dependencies:
      - target: whatsub-mobile
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: cc.eversay.whatsub.mobileTests
        GENERATE_INFOPLIST_FILE: YES
```

Also add a scheme so `xcodebuild test` knows what to run. At the top level of `project.yml` (after `targets:` block), add:

```yaml
schemes:
  whatsub-mobile:
    build:
      targets:
        whatsub-mobile: all
        whatsub-mobileTests: [test]
    test:
      targets:
        - whatsub-mobileTests
```

- [ ] **Step 2: DTOTests.swift**

```swift
import XCTest
@testable import whatsub_mobile

final class DTOTests: XCTestCase {
    func testVerifyCodeResponseDecodes() throws {
        let json = #"{"sessionToken":"abc123","expiresAt":1779999999999}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(VerifyCodeResponse.self, from: json)
        XCTAssertEqual(resp.sessionToken, "abc123")
        XCTAssertEqual(resp.expiresAt, 1_779_999_999_999)
    }

    func testMeResponseDecodesWithoutIsAdmin() throws {
        let json = #"{"email":"a@b.com","hasActiveLicense":true}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(MeResponse.self, from: json)
        XCTAssertEqual(resp.email, "a@b.com")
        XCTAssertTrue(resp.hasActiveLicense)
        XCTAssertNil(resp.isAdmin)
    }

    func testSessionValidity() {
        let future = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        let past = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
        XCTAssertTrue(Session(email: "a@b.com", sessionToken: "t", expiresAt: future).isValid)
        XCTAssertFalse(Session(email: "a@b.com", sessionToken: "t", expiresAt: past).isValid)
    }
}
```

- [ ] **Step 3: APIErrorTests.swift**

```swift
import XCTest
@testable import whatsub_mobile

final class APIErrorTests: XCTestCase {
    func testServerErrorMapping() {
        XCTAssertEqual(APIError.server(400, "wrong_code").chinese, "验证码错误")
        XCTAssertEqual(APIError.server(400, "too_many_attempts").chinese, "尝试次数过多，请重新获取验证码")
        XCTAssertEqual(APIError.unauthorized.chinese, "登录已过期，请重新登录")
    }

    func testUnknownServerErrorFallsBackToCode() {
        XCTAssertEqual(APIError.server(500, "boom").chinese, "服务器错误（500）")
    }
}
```

- [ ] **Step 4: Lint yaml + commit (Swift compiles in CI)**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
node -e "const s=require('fs').readFileSync('project.yml','utf-8');if(s.includes('\t')){console.error('tab!');process.exit(1)}console.log('ok',s.length)"
git add project.yml whatsub-mobileTests/
git commit -m "test(ios): unit-test target + DTO + APIError tests"
```

---

### Task 9: CI runs tests + screenshots AuthGate

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add a test step before the screenshot step**

In `ci.yml`, after "Build for Simulator" and before "Boot simulator + install app", add a test step:

```yaml
      - name: Run unit tests
        env:
          UDID: ${{ steps.pick-sim.outputs.udid }}
        run: |
          set -o pipefail
          xcodebuild \
            -project whatsub-mobile.xcodeproj \
            -scheme whatsub-mobile \
            -configuration Debug \
            -destination "platform=iOS Simulator,id=${UDID}" \
            -derivedDataPath ./DerivedData \
            CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
            test | xcbeautify
```

The existing screenshot step will now capture the AuthGate (since no session exists on a fresh simulator install, the app launches to AuthGateView). Rename the screenshot file to reflect this:

Change `screenshots/01-corpus.png` to `screenshots/01-authgate.png` in the "Screenshot the launch tab" step.

- [ ] **Step 2: Lint + commit**

```bash
node -e "const s=require('fs').readFileSync('.github/workflows/ci.yml','utf-8');if(s.includes('\t')){console.error('tab!');process.exit(1)}console.log('ok')"
git add .github/workflows/ci.yml
git commit -m "ci: run unit tests + screenshot AuthGate on fresh launch"
```

---

### Task 10: Push + watch CI + first authenticated TestFlight build

**Files:** none (CI + verification)

- [ ] **Step 1: Merge to main + push**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git checkout main
git merge --no-ff feat/ios-phase2a-auth -m "feat(ios): Phase 2a — email OTP auth + networking foundation"
git push origin main
git branch -d feat/ios-phase2a-auth
```

- [ ] **Step 2: Watch CI (build + tests + screenshot)**

```bash
gh run watch $(gh run list --repo rjxznb/whatsub-mobile --workflow ci.yml --limit 1 --json databaseId -q '.[0].databaseId') --repo rjxznb/whatsub-mobile --exit-status
```

Expected: build green, unit tests pass, AuthGate screenshot uploaded. If build fails (Swift compile error), read the log, fix, re-push. Common first-compile issues:
- `@testable import whatsub_mobile` — the module name has a hyphen→underscore conversion. If the import fails, the module name might be different; check the actual `PRODUCT_MODULE_NAME` (XcodeGen derives it from target name `whatsub-mobile` → `whatsub_mobile`). Usually correct.
- `onChange(of:)` two-param closure requires iOS 17. Our target is iOS 16. If CI errors on this, use the iOS 16 single-param form: `.onChange(of: vm.code) { newValue in ... }`.
- `LabeledContent` is iOS 16+ — fine.

- [ ] **Step 3: Watch TestFlight workflow**

```bash
gh run watch $(gh run list --repo rjxznb/whatsub-mobile --workflow testflight.yml --limit 1 --json databaseId -q '.[0].databaseId') --repo rjxznb/whatsub-mobile --exit-status
```

Expected: upload succeeds (~10 min). New build appears in App Store Connect.

- [ ] **Step 4: User installs + tests login (manual)**

User on iPhone TestFlight:
1. Open the new build → lands on AuthGateView (whatSub logo + email field)
2. Enter the email associated with a purchased license → 发送验证码
3. Check email for 6-digit code (QQ mailbox — backend sends via SMTP)
4. Enter code → 验证登录
5. App shows the 3 tabs; tap 我的 → email shown, 授权状态 = 有效 (green) if that email has a license
6. Tap 退出登录 → returns to AuthGate

User reports back: "login works + license shows correctly" → Phase 2a DONE.

---

## Done criteria

- iOS app gates behind email-OTP login; session persists across app restarts (Keychain)
- 我的 tab shows real email + license status + working logout
- 401 from any call clears the session + returns to AuthGate
- CI runs unit tests (DTO + APIError + Session) + screenshots AuthGate
- TestFlight build is installable + login works end-to-end with a real licensed email
- Corpus + Library tabs still show placeholders (Phase 2b/2c replace them)

Ready for **Phase 2b** (corpus browse + phrase detail + YouTube embed).
