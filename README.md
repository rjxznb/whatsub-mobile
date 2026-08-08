# whatsub-mobile

iOS consumer client for [whatSub](https://whatsub.eversay.cc). Read public/private corpus and library subtitles (cloud-synced from desktop). Phase 1: scaffold + CI/TestFlight; Phase 2: real features.

## Architecture

SwiftUI native, iOS 16+. Project file generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) — DO NOT edit `.xcodeproj` directly; it's git-ignored.

## Background AI analysis (staged rollout)

The import flow now has two deliberately different execution modes:

- **whatSub managed AI** submits a durable backend job. The user may switch apps or terminate whatSub while analysis continues. Free accounts may analyze videos up to 20 minutes and share the existing 200K lifetime trial-token budget; Pro uses the existing 5M monthly budget and has no product-level duration cap in this analysis path.
- **BYOK** continues to call the user's configured provider directly from iOS. Video length is not capped by whatSub, but iOS only starts requests while the app is in the foreground. Completed 50-cue batches are checkpointed in protected Application Support storage, so returning to the app resumes from the next unfinished batch instead of restarting the whole video.

Managed jobs appear under `我的 -> 导入队列 -> 手机后台解析`, including exact batch progress, cancellation, quota-paused retry, failures, and completion. Live Activity updates use the combined desktop/mobile queue aggregate; a completed notification can deep-link directly to the new Library entry.

Backend capacity is bounded independently of HTTP traffic: workers default to disabled for deployment, then roll out from one worker to two; defaults reserve at most two background LLM connections within four global LLM connections, allow at most three unfinished jobs per account, and cap the global unfinished queue at 100. See the implementation plan and design under `docs/superpowers/` before changing these limits or enabling workers in production.

## Local dev (on Apple Silicon Mac with Xcode)

```bash
brew install xcodegen
./scripts/setup-frameworks.sh   # one-time: download sherpa-onnx + onnxruntime XCFrameworks (~200MB)
xcodegen generate
open whatsub-mobile.xcodeproj
```

The setup script is idempotent — re-run after `rm -rf frameworks/` to force a fresh download. The two XCFrameworks are git-ignored (>100MB each, above GitHub's per-file limit); CI downloads them on every build via the same logic inlined in `.github/workflows/{ci,testflight}.yml`.

## Local dev (on Windows — no Xcode needed)

- Edit `.swift` files / `project.yml` / `.github/workflows/*.yml`
- Push to GitHub → CI builds for iOS Simulator + uploads screenshot artifact
- Push to `main` → TestFlight workflow → ~15 min later your TestFlight app shows the new build

## CI / TestFlight

Two workflows in `.github/workflows/`:
- `ci.yml` — every push: build for Simulator + screenshot. ~5 min.
- `testflight.yml` — `main` branch pushes: archive + sign + upload to TestFlight. ~10-15 min.

### One-time GitHub Secrets setup

| Secret | Value |
|---|---|
| `APP_STORE_CONNECT_API_KEY_P8` | Full content of `AuthKey_<KEY_ID>.p8` from App Store Connect |
| `APP_STORE_CONNECT_KEY_ID` | 10-char key ID (filename without prefix/extension) |
| `APP_STORE_CONNECT_ISSUER_ID` | UUID from App Store Connect Integrations page |

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
