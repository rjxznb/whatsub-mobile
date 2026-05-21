# whatsub-mobile — Architecture

iOS consumer client for whatSub. SwiftUI native, iOS 16+. Reads public/private corpus + cloud-synced library subtitles from the [whatsub-license](https://github.com/rjxznb/whatsub-license) backend. Companion to the [desktop Tauri app](https://github.com/rjxznb/whatsub-releases) (private repo for source) which produces the data this app consumes.

**Status**: Phase 1 done (scaffold + CI + TestFlight). Phase 2 (auth + corpus + library detail features) in plan.

## Stack

- **Swift 5.10 + SwiftUI** · iOS 16+ · Xcode 16+
- **XcodeGen 2.43+** generates `.xcodeproj` from `project.yml` (never edit pbxproj directly; `.gitignore`'d)
- **GitHub Actions (`macos-15`)** for CI + TestFlight upload
- **No third-party Swift deps** (URLSession, WKWebView, Keychain Services — all native). Dev only: SwiftLint planned for Phase 2.
- **App Store Connect API key** (`.p8`) for fully-automated signing; no manual cert/profile management

## Repos this app talks to

| Repo | Role | URL |
|---|---|---|
| `whatsub-license` | Backend Hono+Postgres, owns `/api/auth/*`, `/api/corpus/*`, `/api/library/*` | https://github.com/rjxznb/whatsub-license |
| `whatsub-releases` | Desktop Tauri app source (private mirror at `rjxznb/whatsub`) — produces the library data we sync | — |
| `whatsub-website` | Marketing static site at `https://whatsub.eversay.cc` | https://github.com/rjxznb/whatsub-website |

## Layout

```
whatsub-mobile/
├── project.yml              # XcodeGen spec — single source of truth for .xcodeproj
├── ExportOptions.plist      # xcodebuild exportArchive config (method=app-store)
├── whatsub-mobile/          # Swift source target (note: same name as repo root)
│   ├── App/                 # @main + AppState + Theme
│   ├── Views/               # SwiftUI placeholder views (Phase 1) / real views (Phase 2)
│   ├── Assets.xcassets/     # AppIcon + AccentColor
│   ├── Info.plist
│   └── PrivacyInfo.xcprivacy
├── .github/workflows/
│   ├── ci.yml               # every push: simulator build + screenshot artifact
│   └── testflight.yml       # main push: archive + sign + upload TestFlight
└── docs/superpowers/        # spec + plans for v1 (see README.md "Phase" rollout)
```

## Apple Developer config (already established)

- Team ID: `Q3BK52FQT9`
- Bundle ID: `cc.eversay.whatsub.mobile`
- App Store Connect record: `whatSub`
- API Key Name: `GitHub Actions` (App Manager access)
- Internal Tester: `2216681472@qq.com` (in Internal Group `whatsub`)

## Build / dev

```bash
# Local (Mac with Xcode):
brew install xcodegen
xcodegen generate
open whatsub-mobile.xcodeproj

# CI does this automatically on every push.
# Without Mac access: edit .swift / project.yml / .github/workflows on Windows,
# push to GitHub, watch CI artifacts (screenshots) for visual feedback.
```

## CI / TestFlight

Two workflows in `.github/workflows/`:
- `ci.yml` — every push: build for `iPhone 15 Pro` simulator, screenshot launch tab, upload artifact. ~3 min.
- `testflight.yml` — main push: archive + export IPA + `xcrun altool --upload-app`. ~10 min when secrets present.

### One-time secrets (in GitHub repo Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Full content of `AuthKey_<KEY_ID>.p8` including PEM headers |
| `APP_STORE_CONNECT_KEY_ID` | 10-char key ID (filename without prefix/extension) |
| `APP_STORE_CONNECT_ISSUER_ID` | UUID from App Store Connect Integrations page |

The `.p8` file should be deleted from local disk after upload to GitHub Secrets — never commit, never share. `.gitignore` already excludes `AuthKey_*.p8` as a belt-and-suspenders.

## Key design decisions

- **XcodeGen, not Tuist**: Tuist is more powerful but uses a Swift DSL that requires macOS to author. XcodeGen YAML is fully editable from Windows. Single-target v1 doesn't need Tuist's power.
- **Automatic signing + ASC API key**: `xcodebuild -allowProvisioningUpdates -authenticationKey* …` lets the runner fetch a fresh distribution cert + provisioning profile from Apple on every CI run. **No local cert/profile management ever.** The cost: every Archive talks to Apple's API; if Apple is down or the key is revoked, CI fails.
- **TestFlight Internal Testing only for v1**: skips Apple Beta App Review. Limit 100 internal testers; the only one for v1 is the owner.
- **Chinese-only UI hardcoded**: matches the desktop app. No i18n tables for v1. `developmentLanguage: zh-Hans` in project.yml + `CFBundleDevelopmentRegion = zh-Hans` in Info.plist.
- **iOS 16 minimum**: gives us NavigationStack + AsyncImage + the `.foregroundStyle` API; covers ~94% of devices in 2026.
- **0 third-party Swift packages**: every line of code is auditable + builds are reproducible without dependency resolution. Trade-off: more boilerplate (URLSession wrapper, Keychain helper). Acceptable for v1's scope.

## 踩过的坑 (avoid repeating)

### CI / GitHub Actions / iOS toolchain

- **GitHub Actions billing block on private repo can stop all workflows pre-start.** Error message: "recent account payments have failed or your spending limit needs to be increased". This blocks even Linux runs, not just expensive macOS ones. For solo dev hobby projects: simplest fix is `gh repo edit <repo> --visibility public --accept-visibility-change-consequences` — public repos get unlimited free Actions minutes (including macOS). The repo's secrets stay encrypted regardless of visibility. Trade-off: code is world-readable. For consumer apps where the value is in the iOS experience + cloud backend (not the client code itself), public is usually fine.

- **XcodeGen 2.43+ emits `objectVersion 77` pbxproj which only Xcode 16+ can read.** Symptom in CI: `xcodebuild: error: The project 'X' cannot be opened because it is in a future Xcode project file format (77). Adjust the project format using a compatible version of Xcode...`. Fix: `runs-on: macos-15` (Xcode 16.x default), NOT `macos-14` (Xcode 15.4 default). Both have the same 10x-weight cost on private repos; both are free on public.

- **`xcodebuild` `-authenticationKeyPath` requires `-authenticationKeyID` AND `-authenticationKeyIssuerID` non-empty.** Symptom: `xcodebuild: error: The flag -authenticationKeyID is required when specifying -authenticationKeyPath` even though the flag IS in the command. Real cause: the SECRET env var was empty (not the flag). Happens when GitHub Secrets aren't set yet but the workflow runs anyway. Defensive fix: add a `Verify secrets present` step early in the testflight workflow that errors with a clear message if any of the 3 ASC secrets is unset. (Not in CI today; add when the missing-secret pattern bites a second time.)

- **`printf '%s' "$EMPTY_VAR" > file.p8` succeeds silently** — produces an empty file. Then downstream xcodebuild fails with the cryptic flag error above. The earlier step shows green in CI, masking the real cause. Always sanity-check secret content in CI: `wc -c file.p8` should be > 200 for a valid .p8.

### Swift / SwiftUI

- **`.foregroundStyle(.whatsubAccent)` needs the static defined on `ShapeStyle`, not just `Color`.** Symptom: `type 'ShapeStyle' has no member 'whatsubAccent'`. The leading-dot shorthand resolves member lookup against the parameter type (`ShapeStyle`), not the value type (`Color`). Defining `extension Color { static let whatsubAccent = ... }` compiles for `Color.whatsubAccent` but not the `.whatsubAccent` shorthand inside `.foregroundStyle()`. Always pair Color statics with a `ShapeStyle where Self == Color` extension — see `whatsub-mobile/App/Theme.swift` for the template. Built-in SwiftUI does this for `.red` / `.blue` / etc.

- **`.foregroundStyle(.secondary)` works without our help** — `.secondary` is already a `ShapeStyle` static (`HierarchicalShapeStyle.secondary`). The trap is custom colors.

### Local dev on Windows

- **`localhost:3030` curl hits `http_proxy` instead of the loopback** when the user has a VPN/proxy env set (e.g. Clash on 127.0.0.1:7890). Symptom: `HTTP 502 Bad Gateway` with proxy headers in response. Fix: `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY` in the same shell before curl, OR `curl --noproxy '*'`. Backend itself is fine; this is purely a client-side proxy interference.

- **Git on Windows nags about LF → CRLF on every `git add` of text files.** Cosmetic — git stores LF in the blob regardless. To silence: create `.gitattributes` with `* text=auto eol=lf` at repo root. Not done in v1 because the warnings are scrollable noise, not actually breaking anything.

- **`taskkill /F /PID <n>` from Git Bash fails with "无效参数 - 'F:/'"** because Git Bash's MSYS path translation thinks `/F` is a Unix path. Fix: use PowerShell tool with `Stop-Process -Id <n> -Force`, or escape: `taskkill //F //PID <n>` (double slash).

- **`docker exec -i ... psql ... < file.sql` from Git Bash works** but make sure the file path is the Windows path (`/c/Users/...`) since the shell resolves it before docker sees it.

## Companion docs

- `docs/superpowers/specs/2026-05-21-whatsub-ios-mobile-v1-design.md` — full v1 spec (3 features, scope, architecture)
- `docs/superpowers/plans/2026-05-21-backend-library-sync.md` — Plan 1 (DONE: backend `/api/library/*` shipped)
- `docs/superpowers/plans/2026-05-21-ios-scaffold-and-ci.md` — Plan 2 Phase 1 (this scaffold + CI + TestFlight)
- Future: `docs/superpowers/plans/<date>-desktop-library-sync.md` (Plan 3) + `<date>-ios-phase2-features.md` (Plan 2 Phase 2)
