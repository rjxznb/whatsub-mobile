# Plan 2 Phase 1: iOS Scaffold + CI + TestFlight Pipeline

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]` syntax.

**Goal:** Empty SwiftUI app (3-tab placeholder content) auto-built + signed + uploaded to TestFlight via GitHub Actions, appearing in the user's TestFlight app on iPhone/Mac. Validates the entire build→sign→upload chain before investing weeks in feature work.

**Architecture:** SwiftUI native iOS 16+. **XcodeGen** generates the `.xcodeproj` from a YAML spec (so we can author iOS projects from Windows without ever touching the binary pbxproj). GitHub Actions on `macos-14` runner does `xcodegen → xcodebuild archive → xcodebuild exportArchive → xcrun altool --upload-app`. App Store Connect API key auth (no certs/profiles to manage; Xcode's `-allowProvisioningUpdates` fetches them automatically).

**Tech Stack:** Swift 5.10 · SwiftUI · XcodeGen 2.42+ · GitHub Actions (macos-14) · App Store Connect API · TestFlight Internal Testing.

**Working dir:** `C:\Users\renjx\Desktop\whatsub-mobile`. All file paths in this plan are relative to that.

**Apple Developer config** (already set up by user):
- Bundle ID: `cc.eversay.whatsub.mobile`
- Team ID: `Q3BK52FQT9`
- App Store Connect API Key ID: `6S7NJ74QKC`
- App Store Connect Issuer ID: `ade49b8d-41c9-426a-bb41-96a069108140`
- App Store Connect record: `whatSub` (created)
- Internal Tester: `2216681472@qq.com` (added to Internal Group named "whatsub")
- `.p8` file: on user's Desktop, NOT to be read by Claude (security)

---

## File Structure

| File | Responsibility |
|---|---|
| `.gitignore` (create) | Xcode/macOS/secrets exclusions |
| `README.md` (create) | One-screen setup + dev loop docs |
| `project.yml` (create) | XcodeGen spec — single source of truth for .xcodeproj |
| `whatsub-mobile/App/WhatsubMobileApp.swift` (create) | `@main` entry, root TabView |
| `whatsub-mobile/App/AppState.swift` (create) | Empty `ObservableObject` for future state |
| `whatsub-mobile/App/Theme.swift` (create) | Brand colors as `Color` extensions |
| `whatsub-mobile/Views/CorpusPlaceholderView.swift` (create) | "Coming soon" placeholder for tab 1 |
| `whatsub-mobile/Views/LibraryPlaceholderView.swift` (create) | "Coming soon" placeholder for tab 2 |
| `whatsub-mobile/Views/MePlaceholderView.swift` (create) | Email + version + "Coming soon" for tab 3 |
| `whatsub-mobile/Assets.xcassets/AppIcon.appiconset/Contents.json` (create) | App icon spec (placeholder square SVG-derived PNGs come in Phase 2) |
| `whatsub-mobile/Assets.xcassets/AccentColor.colorset/Contents.json` (create) | Brand accent `#3B9BFF` |
| `whatsub-mobile/Info.plist` (create) | Bundle config (CFBundleDisplayName, UISupportedInterfaceOrientations, etc.) |
| `whatsub-mobile/PrivacyInfo.xcprivacy` (create) | Apple required privacy manifest (we collect nothing v1) |
| `ExportOptions.plist` (create) | xcodebuild exportArchive config (method=app-store) |
| `.github/workflows/ci.yml` (create) | Per-push: build for simulator + screenshot |
| `.github/workflows/testflight.yml` (create) | main-push: build + archive + upload TestFlight |
| `.github/workflows/manual-screenshot.yml` (create) | workflow_dispatch: on-demand sim screenshot |

**Why XcodeGen vs Tuist vs hand-written pbxproj**:
- **XcodeGen**: single YAML → reproducible pbxproj. Small binary, brew-install on macOS, no Swift dep. Excellent for solo devs.
- **Tuist**: same idea but Swift-based DSL + more powerful. Overkill for v1 single-target app.
- **Hand-written pbxproj**: fragile XML, hard to merge, hard to author from Windows. Avoid.

---

## Pre-flight (one-time, before Task 1)

- [ ] **Verify XcodeGen YAML schema knowledge accessible**

The plan assumes XcodeGen 2.42+ schema. Reference: https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md

We won't run XcodeGen on Windows (it's macOS-only), but CI will. Local validation = YAML syntax only (any YAML linter).

- [ ] **Verify the `whatsub-mobile` working dir contents**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
ls -la
```

Expected: `docs/` (with spec + Plan 1 + Plan 2). No `.git`, no `whatsub-mobile/` subdir (the iOS Swift target), no `project.yml`. We're starting fresh.

---

### Task 1: Initialize git repo + `.gitignore` + initial docs commit

**Files:**
- Create: `.gitignore`
- (already exist: `docs/superpowers/specs/*.md`, `docs/superpowers/plans/*.md`)

- [ ] **Step 1: Init git + write .gitignore**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git init
git branch -M main
```

Create `.gitignore`:

```gitignore
# macOS
.DS_Store

# Xcode build artifacts
build/
DerivedData/
*.xcuserstate
*.xcuserdata/
xcuserdata/
*.moved-aside

# XcodeGen-generated project — checked in OR not? See README. Default: not checked in.
# Comment the next line if you want to commit the .xcodeproj instead.
whatsub-mobile.xcodeproj/

# Swift Package Manager
.swiftpm/
Packages/
Package.resolved

# Secrets — never commit
*.p12
*.p8
*.mobileprovision
AuthKey_*.p8
secrets/

# Environment
.env
.env.local

# IDE / OS
.idea/
.vscode/
*.swp
*.swo
Thumbs.db
```

- [ ] **Step 2: Stage + commit initial docs**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git add .gitignore docs/
git status --short
```

Expected: `A .gitignore`, `A docs/superpowers/specs/...md`, `A docs/superpowers/plans/...md` (3 files in docs).

```bash
git commit -m "docs: spec + plans for iOS v1 (Plan 1 done, Plan 2 phase 1 + 2 pending)"
```

- [ ] **Step 3: Verify**

```bash
git log --oneline
git status
```

Expected: 1 commit, working tree clean (only the .p8 file untracked which is in .gitignore via `AuthKey_*.p8`).

---

### Task 2: Write `project.yml` (XcodeGen spec)

**Files:**
- Create: `project.yml`

- [ ] **Step 1: Write `project.yml`**

```yaml
name: whatsub-mobile
options:
  bundleIdPrefix: cc.eversay.whatsub
  deploymentTarget:
    iOS: "16.0"
  developmentLanguage: zh-Hans
  xcodeVersion: "15.4"
  createIntermediateGroups: true
  generateEmptyDirectories: true
  groupSortPosition: top

settings:
  base:
    DEVELOPMENT_TEAM: Q3BK52FQT9
    MARKETING_VERSION: "0.0.1"
    CURRENT_PROJECT_VERSION: "1"
    SWIFT_VERSION: "5.10"
    IPHONEOS_DEPLOYMENT_TARGET: "16.0"
    TARGETED_DEVICE_FAMILY: "1,2"
    # Phase 1 keeps signing simple: use automatic + the team's distribution
    # cert that App Store Connect cloud-manages. The CI workflow passes
    # -allowProvisioningUpdates so xcodebuild fetches profile+cert as needed.
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_IDENTITY: "Apple Development"
    # Localization defaults to Chinese (matches spec § 5.1 "仅中文 hardcoded")
    SWIFT_EMIT_LOC_STRINGS: NO
  configs:
    Debug:
      ENABLE_TESTABILITY: YES
      SWIFT_OPTIMIZATION_LEVEL: "-Onone"
    Release:
      SWIFT_OPTIMIZATION_LEVEL: "-O"

targets:
  whatsub-mobile:
    type: application
    platform: iOS
    sources:
      - path: whatsub-mobile
        excludes:
          - "Info.plist"
          - "PrivacyInfo.xcprivacy"
    resources:
      - whatsub-mobile/Assets.xcassets
      - whatsub-mobile/PrivacyInfo.xcprivacy
    info:
      path: whatsub-mobile/Info.plist
      properties:
        CFBundleDisplayName: whatSub
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        UILaunchScreen:
          UIColorName: AccentColor
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UIApplicationSupportsIndirectInputEvents: true
        ITSAppUsesNonExemptEncryption: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: cc.eversay.whatsub.mobile
        INFOPLIST_KEY_CFBundleDisplayName: whatSub
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
```

- [ ] **Step 2: Validate YAML syntax** (basic check from Windows)

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
node -e "const yaml=require('yaml');const fs=require('fs');try{const o=yaml.parse(fs.readFileSync('project.yml','utf-8'));console.log('Parsed OK. Target:',Object.keys(o.targets));}catch(e){console.error('BAD YAML:',e.message);process.exit(1);}"
```

If `yaml` package isn't installed, fall back to:
```bash
node -e "const fs=require('fs');const s=fs.readFileSync('project.yml','utf-8');if(s.includes('\t')){console.error('TAB CHARS PRESENT (yaml forbids tabs)');process.exit(1);}console.log('No tabs, len',s.length);"
```

Expected: `Parsed OK. Target: ['whatsub-mobile']` (or `No tabs, len <N>` if no yaml pkg).

- [ ] **Step 3: Commit**

```bash
git add project.yml
git commit -m "feat(ios): XcodeGen project spec"
```

---

### Task 3: Write minimal Swift source files

**Files:**
- Create: `whatsub-mobile/App/WhatsubMobileApp.swift`
- Create: `whatsub-mobile/App/AppState.swift`
- Create: `whatsub-mobile/App/Theme.swift`
- Create: `whatsub-mobile/Views/CorpusPlaceholderView.swift`
- Create: `whatsub-mobile/Views/LibraryPlaceholderView.swift`
- Create: `whatsub-mobile/Views/MePlaceholderView.swift`

- [ ] **Step 1: WhatsubMobileApp.swift** (entry + root TabView)

```swift
import SwiftUI

@main
struct WhatsubMobileApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .tint(.whatsubAccent)
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            CorpusPlaceholderView()
                .tabItem {
                    Label("语料库", systemImage: "books.vertical")
                }
                .tag(0)

            LibraryPlaceholderView()
                .tabItem {
                    Label("Library", systemImage: "play.rectangle")
                }
                .tag(1)

            MePlaceholderView()
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
                .tag(2)
        }
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
```

- [ ] **Step 2: AppState.swift** (empty stub for Phase 2)

```swift
import Foundation
import Combine

/// Root state for the whatSub iOS app.
///
/// Phase 1: empty stub. Phase 2 will hold session, current user, and
/// child view models. Lives at the root via `@StateObject` in
/// `WhatsubMobileApp` and is injected into views via `.environmentObject`.
final class AppState: ObservableObject {
    // Placeholder — Phase 2 will add session + auth gate + tabs.
}
```

- [ ] **Step 3: Theme.swift** (brand colors from spec § 5.1)

```swift
import SwiftUI

extension Color {
    /// Brand accent — matches desktop client / website (#3B9BFF).
    static let whatsubAccent = Color(red: 0x3B / 255.0, green: 0x9B / 255.0, blue: 0xFF / 255.0)

    /// Highlight color for AI-flagged phrases (#FCD34D).
    static let whatsubHighlight = Color(red: 0xFC / 255.0, green: 0xD3 / 255.0, blue: 0x4D / 255.0)
}
```

- [ ] **Step 4: CorpusPlaceholderView.swift**

```swift
import SwiftUI

struct CorpusPlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 56))
                    .foregroundStyle(.whatsubAccent)
                Text("语料库")
                    .font(.title2.weight(.semibold))
                Text("公共 + 我的语料库浏览\nPhase 2 加上线")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .navigationTitle("语料库")
        }
    }
}

#Preview { CorpusPlaceholderView() }
```

- [ ] **Step 5: LibraryPlaceholderView.swift**

```swift
import SwiftUI

struct LibraryPlaceholderView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 56))
                    .foregroundStyle(.whatsubAccent)
                Text("Library")
                    .font(.title2.weight(.semibold))
                Text("桌面同步 YouTube 字幕\nPhase 2 加上线")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .navigationTitle("Library")
        }
    }
}

#Preview { LibraryPlaceholderView() }
```

- [ ] **Step 6: MePlaceholderView.swift**

```swift
import SwiftUI

struct MePlaceholderView: View {
    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "v\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    Text("未登录 · Phase 2 接邮箱 OTP")
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: versionString)
                    Link("官网 whatsub.eversay.cc", destination: URL(string: "https://whatsub.eversay.cc")!)
                }
            }
            .navigationTitle("我的")
        }
    }
}

#Preview { MePlaceholderView() }
```

- [ ] **Step 7: Commit**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git add whatsub-mobile/
git commit -m "feat(ios): scaffold SwiftUI 3-tab app shell"
```

---

### Task 4: Assets + Info.plist + Privacy Manifest

**Files:**
- Create: `whatsub-mobile/Assets.xcassets/Contents.json`
- Create: `whatsub-mobile/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `whatsub-mobile/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `whatsub-mobile/Info.plist`
- Create: `whatsub-mobile/PrivacyInfo.xcprivacy`

- [ ] **Step 1: Assets.xcassets root**

`whatsub-mobile/Assets.xcassets/Contents.json`:
```json
{
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

- [ ] **Step 2: AppIcon set (PHASE 1 INTENTIONALLY EMPTY — no PNG yet)**

`whatsub-mobile/Assets.xcassets/AppIcon.appiconset/Contents.json`:
```json
{
  "images": [
    {
      "filename": "AppIcon-1024.png",
      "idiom": "universal",
      "platform": "ios",
      "size": "1024x1024"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

For Phase 1 we need a 1024x1024 PNG. **Reuse the desktop app icon** by copying from `C:\Users\renjx\Desktop\Get_Video\client\src-tauri\icons\` (there's a `128x128@2x.png` and an `icon.png` available).

```bash
# Convert/copy the desktop icon to 1024x1024 PNG.
# If you have ImageMagick on Windows:
magick "C:\Users\renjx\Desktop\Get_Video\client\src-tauri\icons\icon.png" -resize 1024x1024 "C:\Users\renjx\Desktop\whatsub-mobile\whatsub-mobile\Assets.xcassets\AppIcon.appiconset\AppIcon-1024.png"

# If you don't have ImageMagick: copy the largest existing PNG as-is and CI will warn;
# the build will still succeed because iOS doesn't strictly require 1024x1024 at archive
# time, only at App Store submission (Phase 2 will produce a proper icon).
cp "C:\Users\renjx\Desktop\Get_Video\client\src-tauri\icons\icon.png" "C:\Users\renjx\Desktop\whatsub-mobile\whatsub-mobile\Assets.xcassets\AppIcon.appiconset\AppIcon-1024.png"
```

(If neither path works, manually drop any square PNG named `AppIcon-1024.png` into the folder. Plan B: use the placeholder `whatsub-wordmark.png` from `C:\Users\renjx\Desktop\whatsub-website\public\` cropped to square.)

- [ ] **Step 3: AccentColor**

`whatsub-mobile/Assets.xcassets/AccentColor.colorset/Contents.json`:
```json
{
  "colors": [
    {
      "color": {
        "color-space": "srgb",
        "components": {
          "alpha": "1.000",
          "blue": "1.000",
          "green": "0.608",
          "red": "0.231"
        }
      },
      "idiom": "universal"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

(0.231/0.608/1.000 ≈ #3B9BFF — matches the brand accent.)

- [ ] **Step 4: Info.plist**

`whatsub-mobile/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleDisplayName</key>
  <string>whatSub</string>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key>
  <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
  <key>CFBundleShortVersionString</key>
  <string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key>
  <string>$(CURRENT_PROJECT_VERSION)</string>
  <key>LSRequiresIPhoneOS</key>
  <true/>
  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <false/>
  </dict>
  <key>UILaunchScreen</key>
  <dict>
    <key>UIColorName</key>
    <string>AccentColor</string>
  </dict>
  <key>UIRequiredDeviceCapabilities</key>
  <array>
    <string>arm64</string>
  </array>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
</dict>
</plist>
```

- [ ] **Step 5: PrivacyInfo.xcprivacy** (Apple-required, v1 collects nothing)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key>
  <false/>
  <key>NSPrivacyTrackingDomains</key>
  <array/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array>
        <string>CA92.1</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
```

(`CA92.1` = "App functionality" reason for UserDefaults. We don't actually use UserDefaults in Phase 1 but Apple's static analyzer flags any app that imports Foundation; declaring it pre-empts a TestFlight rejection.)

- [ ] **Step 6: Commit**

```bash
git add whatsub-mobile/Assets.xcassets whatsub-mobile/Info.plist whatsub-mobile/PrivacyInfo.xcprivacy
git commit -m "feat(ios): assets + Info.plist + privacy manifest"
```

---

### Task 5: ExportOptions.plist

**Files:**
- Create: `ExportOptions.plist`

- [ ] **Step 1: Write ExportOptions.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store</string>
  <key>destination</key>
  <string>export</string>
  <key>teamID</key>
  <string>Q3BK52FQT9</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>uploadBitcode</key>
  <false/>
  <key>compileBitcode</key>
  <false/>
</dict>
</plist>
```

`method=app-store` produces an .ipa suitable for App Store Connect upload (and TestFlight). `signingStyle=automatic` + the CI flag `-allowProvisioningUpdates` lets Xcode fetch the matching distribution cert + provisioning profile on-demand from App Store Connect using the API key. **No manual cert/profile management needed.**

- [ ] **Step 2: Commit**

```bash
git add ExportOptions.plist
git commit -m "feat(ios): ExportOptions.plist for app-store distribution"
```

---

### Task 6: GitHub Actions — `ci.yml` (build for simulator + screenshot)

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: ['**']
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-simulator:
    name: Build for iOS Simulator + Screenshot
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Show Xcode + SDK
        run: |
          xcodebuild -version
          xcrun --show-sdk-version --sdk iphonesimulator

      - name: Generate .xcodeproj
        run: xcodegen generate --quiet

      - name: Pick a stable iOS Simulator
        id: pick-sim
        run: |
          xcrun simctl list devices available | sed -n '/-- iOS [0-9.]* --/,/^--/p' | head -50
          # Prefer iPhone 15 Pro; fall back to first available iPhone
          DEVICE_NAME="iPhone 15 Pro"
          DEVICE_UDID=$(xcrun simctl list devices available -j | jq -r --arg name "$DEVICE_NAME" '.devices | to_entries | .[] | select(.key | contains("iOS")) | .value[] | select(.name == $name) | .udid' | head -1)
          if [ -z "$DEVICE_UDID" ]; then
            DEVICE_UDID=$(xcrun simctl list devices available -j | jq -r '.devices | to_entries | .[] | select(.key | contains("iOS")) | .value[] | select(.name | startswith("iPhone")) | .udid' | head -1)
          fi
          echo "Using device UDID: $DEVICE_UDID"
          echo "udid=$DEVICE_UDID" >> "$GITHUB_OUTPUT"

      - name: Build for Simulator
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
            build | xcbeautify || (echo "build failed"; exit 1)

      - name: Boot simulator + install app
        env:
          UDID: ${{ steps.pick-sim.outputs.udid }}
        run: |
          xcrun simctl boot "$UDID" || true
          xcrun simctl bootstatus "$UDID" -b
          APP_PATH=$(find DerivedData/Build/Products/Debug-iphonesimulator -maxdepth 2 -name "whatsub-mobile.app" | head -1)
          echo "App: $APP_PATH"
          test -d "$APP_PATH"
          xcrun simctl install "$UDID" "$APP_PATH"
          xcrun simctl launch "$UDID" cc.eversay.whatsub.mobile
          # Wait for first frame
          sleep 3

      - name: Screenshot each tab
        env:
          UDID: ${{ steps.pick-sim.outputs.udid }}
        run: |
          mkdir -p screenshots
          # Tab 1 (default): 语料库
          xcrun simctl io "$UDID" screenshot screenshots/01-corpus.png
          # Tab 2: Library — tap by coordinates (TabBar items at bottom).
          # x = screen_width / 6, y near bottom (~ 96% of height). Default iPhone 15 Pro = 1179x2556 @ scale 3 = 393x852 pts logical.
          # simctl io can't tap; we send via xcrun simctl spawn UI events instead — but easiest:
          # use deep linking-style scheme or runtime arg launch. For Phase 1 we just snap the home tab.
          # Phase 2's UI test target will navigate properly. Phase 1: 1 screenshot suffices.
          ls -la screenshots/

      - name: Upload screenshots artifact
        uses: actions/upload-artifact@v4
        with:
          name: simulator-screenshots-${{ github.sha }}
          path: screenshots/
          retention-days: 14
          if-no-files-found: error
```

(Phase 1 takes ONE screenshot of the default tab. Phase 2 adds a UI test target that taps through all tabs/states.)

- [ ] **Step 2: Lint YAML locally**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
node -e "const yaml=require('yaml');const fs=require('fs');yaml.parse(fs.readFileSync('.github/workflows/ci.yml','utf-8'));console.log('CI yaml OK');" 2>&1 || \
  node -e "const s=require('fs').readFileSync('.github/workflows/ci.yml','utf-8');if(s.includes('\t')){console.error('tab chars!');process.exit(1);}console.log('no tabs, len',s.length);"
```

Expected: `CI yaml OK` (or `no tabs, len <N>`).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "feat(ci): build for iOS Simulator + screenshot artifact"
```

---

### Task 7: GitHub Actions — `testflight.yml` (archive + sign + upload)

**Files:**
- Create: `.github/workflows/testflight.yml`

- [ ] **Step 1: Write `.github/workflows/testflight.yml`**

```yaml
name: TestFlight

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: testflight
  cancel-in-progress: false  # never cancel an upload in flight

jobs:
  upload:
    name: Archive + Upload to TestFlight
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate .xcodeproj
        run: xcodegen generate --quiet

      - name: Write ASC API key to disk
        env:
          ASC_API_KEY_P8: ${{ secrets.APP_STORE_CONNECT_API_KEY_P8 }}
          ASC_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
        run: |
          mkdir -p ~/.appstoreconnect/private_keys
          # altool + xcodebuild both look up the key by ID in this dir,
          # with filename pattern AuthKey_<KEY_ID>.p8.
          printf '%s' "$ASC_API_KEY_P8" > ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
          chmod 600 ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
          # Also drop a copy at $RUNNER_TEMP for explicit-path tools:
          cp ~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8 $RUNNER_TEMP/AuthKey.p8

      - name: Set CURRENT_PROJECT_VERSION = run_number
        run: |
          # Bump build number so each TestFlight upload is unique. App Store
          # Connect rejects duplicate (version, build) tuples.
          BUILD_NUM=$((${{ github.run_number }} + 100))
          echo "Setting CURRENT_PROJECT_VERSION=$BUILD_NUM"
          # XcodeGen wrote the value into the project; override via xcodebuild
          # arg at archive time (next step). Persist for later steps via env.
          echo "BUILD_NUM=$BUILD_NUM" >> $GITHUB_ENV

      - name: Archive
        env:
          ASC_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
        run: |
          set -o pipefail
          xcodebuild \
            -project whatsub-mobile.xcodeproj \
            -scheme whatsub-mobile \
            -configuration Release \
            -destination "generic/platform=iOS" \
            -archivePath ./build/whatsub-mobile.xcarchive \
            -allowProvisioningUpdates \
            -authenticationKeyID "$ASC_KEY_ID" \
            -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
            -authenticationKeyPath "$RUNNER_TEMP/AuthKey.p8" \
            CURRENT_PROJECT_VERSION=$BUILD_NUM \
            archive | xcbeautify

      - name: Export IPA
        env:
          ASC_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
        run: |
          set -o pipefail
          xcodebuild \
            -exportArchive \
            -archivePath ./build/whatsub-mobile.xcarchive \
            -exportPath ./build/export \
            -exportOptionsPlist ExportOptions.plist \
            -allowProvisioningUpdates \
            -authenticationKeyID "$ASC_KEY_ID" \
            -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
            -authenticationKeyPath "$RUNNER_TEMP/AuthKey.p8" | xcbeautify
          ls -la ./build/export/

      - name: Upload to TestFlight
        env:
          ASC_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
        run: |
          IPA=$(find ./build/export -name "*.ipa" | head -1)
          echo "Uploading $IPA"
          xcrun altool --upload-app \
            -f "$IPA" \
            -t ios \
            --apiKey "$ASC_KEY_ID" \
            --apiIssuer "$ASC_ISSUER_ID"

      - name: Upload archive artifact (for forensics on failed uploads)
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: xcarchive-${{ github.sha }}
          path: build/whatsub-mobile.xcarchive
          retention-days: 7
```

- [ ] **Step 2: Lint YAML**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
node -e "const yaml=require('yaml');yaml.parse(require('fs').readFileSync('.github/workflows/testflight.yml','utf-8'));console.log('TF yaml OK');" 2>&1 || \
  node -e "const s=require('fs').readFileSync('.github/workflows/testflight.yml','utf-8');if(s.includes('\t')){console.error('tab chars!');process.exit(1);}console.log('no tabs, len',s.length);"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/testflight.yml
git commit -m "feat(ci): TestFlight upload workflow on main push"
```

---

### Task 8: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# whatsub-mobile

iOS consumer client for [whatSub](https://whatsub.eversay.cc). Read public/private corpus and library subtitles (cloud-synced from desktop). Phase 1: scaffold + CI/TestFlight; Phase 2: real features.

## Architecture

SwiftUI native, iOS 16+. Project file generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) — DO NOT edit `.xcodeproj` directly; it's git-ignored.

## Local dev (on Apple Silicon Mac with Xcode)

```bash
brew install xcodegen
xcodegen generate
open whatsub-mobile.xcodeproj
```

## Local dev (on Windows — no Xcode needed)

- Edit `.swift` files / `project.yml` / `.github/workflows/*.yml`
- Push to GitHub → CI builds for iOS Simulator + uploads screenshot artifact
- Push to `main` → TestFlight workflow → ~15 min later your TestFlight app shows the new build

## CI / TestFlight

Two workflows in `.github/workflows/`:
- `ci.yml` — every push: build for Simulator + screenshot. ~5 min.
- `testflight.yml` — `main` branch pushes: archive + sign + upload to TestFlight. ~10-15 min.

### One-time GitHub Secrets setup (DONE = ✅, TODO = ⏳)

| Secret | Value | Status |
|---|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Full content of `AuthKey_<KEY_ID>.p8` from App Store Connect | ⏳ |
| `APP_STORE_CONNECT_KEY_ID` | 10-char key ID (filename without prefix/extension) | ⏳ |
| `APP_STORE_CONNECT_ISSUER_ID` | UUID from App Store Connect Integrations page | ⏳ |

## Project links

- App Store Connect: https://appstoreconnect.apple.com/apps
- Apple Developer Portal: https://developer.apple.com/account/resources/identifiers/list
- Backend: https://whatsub.eversay.cc/api/library/ (see `docs/superpowers/specs/`)

## Layout

- `whatsub-mobile/App/` — `@main` app + state + theme
- `whatsub-mobile/Views/` — SwiftUI views
- `whatsub-mobile/Assets.xcassets/` — icons + colors
- `whatsub-mobile/Info.plist` — bundle config
- `whatsub-mobile/PrivacyInfo.xcprivacy` — privacy manifest
- `project.yml` — XcodeGen spec (single source of truth for .xcodeproj)
- `ExportOptions.plist` — xcodebuild exportArchive config
- `docs/superpowers/` — spec + plans for v1
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with dev/CI/TestFlight setup"
```

---

### Task 9: Create GitHub repo + push

**Files:** none (remote setup)

- [ ] **Step 1: Create the remote repo via gh CLI**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
gh auth status  # verify logged in as rjxznb
gh repo create rjxznb/whatsub-mobile --private --source=. --remote=origin --description="iOS consumer client for whatSub" --disable-issues=false --disable-wiki=true
```

If gh is not installed or login is broken, fall back to creating the repo manually on github.com under user `rjxznb`, name `whatsub-mobile`, private, no README/license (we have those locally), then:

```bash
git remote add origin https://github.com/rjxznb/whatsub-mobile.git
```

- [ ] **Step 2: Push main**

```bash
git push -u origin main
```

Expected: pushes all commits (about 6-7 commits).

- [ ] **Step 3: Verify online**

Visit `https://github.com/rjxznb/whatsub-mobile` — should show README rendered.

---

### Task 10: User adds GitHub Secrets (USER STEP — Claude pauses)

**Files:** none

**This task is performed by the user. Claude STOPS and asks the user to complete it before proceeding to Task 11.**

User must go to https://github.com/rjxznb/whatsub-mobile/settings/secrets/actions and add 3 secrets:

| Name | Value |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Open `C:\Users\renjx\Desktop\AuthKey_6S7NJ74QKC.p8` in Notepad, copy entire contents (including `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----`), paste into secret value |
| `APP_STORE_CONNECT_KEY_ID` | `6S7NJ74QKC` |
| `APP_STORE_CONNECT_ISSUER_ID` | `ade49b8d-41c9-426a-bb41-96a069108140` |

After adding all 3, **user deletes the `.p8` file from Desktop** (or moves to encrypted storage like 1Password).

- [ ] **Step 1: User confirms all 3 secrets added**
- [ ] **Step 2: User confirms `.p8` file safely stored / deleted**

---

### Task 11: First CI run verification

**Files:** none

- [ ] **Step 1: Trigger CI by pushing an empty commit**

```bash
cd /c/Users/renjx/Desktop/whatsub-mobile
git commit --allow-empty -m "ci: trigger first run"
git push origin main
```

This push triggers BOTH `ci.yml` (build + screenshot) AND `testflight.yml` (archive + upload).

- [ ] **Step 2: Watch CI in browser**

Open https://github.com/rjxznb/whatsub-mobile/actions

Expected: 2 workflows running. CI should finish in ~6-8 min; TestFlight in ~10-15 min.

- [ ] **Step 3: If CI fails**

Common first-run failures + fixes:
- **`xcodegen: command not found`**: brew install step failed. Check macOS runner brew tap.
- **`No such device`**: simulator UDID picker didn't match. Edit the `jq` filter in `ci.yml` Pick a stable iOS Simulator step.
- **`Code signing required`**: build step missing `CODE_SIGN_IDENTITY=""` flag. Already in the spec — verify it was applied.
- **`The selected device requires iOS 16.0`**: simulator is missing iOS 16. Bump deployment target or add `simctl runtime add` step.

Iterate until CI succeeds + screenshot artifact uploaded.

- [ ] **Step 4: Download + verify screenshot**

After successful CI run, the workflow page has an artifact `simulator-screenshots-<sha>`. Download it; the PNG should show the 3-tab whatSub app on the 语料库 tab.

---

### Task 12: First TestFlight build verification

**Files:** none

- [ ] **Step 1: Watch testflight.yml succeed**

Same Actions page as Task 11. The `testflight.yml` workflow finishes after `ci.yml`. Final step `Upload to TestFlight` is the moment of truth — `xcrun altool --upload-app` either succeeds or returns an Apple error code.

Common first-run failures:
- **`Error ITMS-90478: Invalid Version`**: build number not incrementing. Verify `BUILD_NUM` env var is being passed to `xcodebuild archive` via `CURRENT_PROJECT_VERSION=`.
- **`Cannot create iOS App Store provisioning profile`**: API key may not have App Manager access. Re-create the key in App Store Connect with App Manager role.
- **`Invalid Bundle ID`**: bundle ID in project.yml doesn't match the registered App ID. Verify both = `cc.eversay.whatsub.mobile`.
- **`App icon set "AppIcon" has an unassigned child`**: AppIcon-1024.png missing or not square. Drop a 1024x1024 PNG in `Assets.xcassets/AppIcon.appiconset/`.

- [ ] **Step 2: Wait ~5-15 min for App Store Connect to process the upload**

App Store Connect → My Apps → whatSub → TestFlight tab → 构建版本 (Builds). Status moves through:
- "Processing" (5-10 min)
- "Missing Compliance" → click "Manage" → answer "No" to export compliance (since `ITSAppUsesNonExemptEncryption=false` in Info.plist) → "Internal Testing only"
- Eventually appears as installable

- [ ] **Step 3: User installs the build**

User opens TestFlight on iPhone (or Mac if Apple Silicon) → whatSub app appears → tap Install → wait 30 sec → launch.

Expected: app opens to 语料库 placeholder tab. Three tabs at bottom work. App icon visible. Version label in 我的 tab shows v0.0.1 (build = run_number + 100).

- [ ] **Step 4: Mark done in TestFlight**

User reports back to Claude: "TestFlight build installed and launches OK on [device]." Plan 2 Phase 1 = DONE.

---

## Done criteria

All boxes checked. After this plan:
- GitHub repo `rjxznb/whatsub-mobile` private, public README
- Local Windows dev loop: edit Swift / yaml → push → CI screenshot, push main → TestFlight build
- User's TestFlight has whatSub v0.0.1 build installable on iPhone/Mac
- 3 GitHub secrets configured; `.p8` file safely deleted from Desktop

Ready for **Plan 3 (desktop sync UI)** and **Plan 2 Phase 2 (auth + corpus + library detail features)**.
