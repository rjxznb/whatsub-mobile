# Share Extension (Phase 2) — Design

**Date:** 2026-05-23
**Status:** design — pending user review before plan

## Goal

Add an iOS **Share Extension** so the user can share a YouTube URL from the YouTube app / Safari → pick **whatSub** → the main app opens straight into the import flow (Phase 1's ImportView) with that URL prefilled. The "点分享导入" the user wanted.

## Decision (agreed)

**Hand-off = Option A (auto-open).** The extension saves the URL to a shared App Group and opens the main app via a `whatsub://import` deep link using the responder-chain `openURL` technique (common but non-official — minor App Store risk, accepted). The main app reads the pending URL from the App Group and pushes ImportView.

The extension does **NO heavy work** (caption extraction + LLM + sync stay in the main app — extensions are memory/time-limited).

## Architecture

```
YouTube app → Share sheet → "whatSub" (Share Extension)
  ShareViewController:
    - read the shared URL from extensionContext.inputItems (public.url / public.plain-text)
    - write it to App Group  group.cc.eversay.whatsub.mobile  (UserDefaults suite, key "pendingImportURL")
    - open  whatsub://import  via responder-chain openURL hack
    - extensionContext.completeRequest

Main app (WhatsubMobileApp):
  - registers URL scheme  whatsub://  (Info.plist CFBundleURLTypes)
  - .onOpenURL { url in if url.host == "import" → read App Group pendingImportURL → route to ImportView }
  - ImportView opens with the URL prefilled + auto-runs (or one-tap run)
```

## Components

| Unit | Responsibility |
|---|---|
| **Share Extension target** (`whatsub-share/`) | New Xcode target. `Info.plist` NSExtension (`NSExtensionPointIdentifier = com.apple.share-services`, activation rule `NSExtensionActivationSupportsWebURLWithMaxCount = 1` + plain-text 1). Bundle id `cc.eversay.whatsub.mobile.share`. App Group entitlement. |
| `ShareViewController.swift` (extension) | Extract URL → App Group save → openURL(`whatsub://import`) → complete. Minimal/no UI (auto-complete). |
| **App Group helper** (shared) | `AppGroup.swift` (added to BOTH targets): suite name + `pendingImportURL` get/set/clear. |
| Main app `Info.plist` | + `CFBundleURLTypes` with scheme `whatsub`. |
| Main app entitlements | + App Group `group.cc.eversay.whatsub.mobile`. |
| `WhatsubMobileApp` | `.onOpenURL` → read App Group → set a `@State pendingImport` → present ImportView (sheet or deep nav). |
| `ImportView` / `ImportViewModel` | accept an initial URL (prefill the field + optionally auto-run). |
| `project.yml` | declare the extension target + its Info.plist/entitlements + add it to the app target's "embed app extensions" + both targets' App Group entitlement + the URL scheme. |

## What the user must do (Apple Developer portal — only the user can; secrets/identifiers)

1. **App Group**: Certificates, Identifiers & Profiles → Identifiers → App Groups → `+` → `group.cc.eversay.whatsub.mobile`.
2. **Extension App ID**: register `cc.eversay.whatsub.mobile.share` (or let automatic signing create it) + enable the **App Groups** capability on it AND on the main app id `cc.eversay.whatsub.mobile`, both assigned to the group from step 1.
3. (Automatic cloud signing then provisions both targets.)

## Risks
1. **CI cloud-signing for a 2-target app** (app + extension), automatic signing + ASC API key: must mint/fetch profiles for BOTH bundle ids with the App Group capability. Historically finicky + compounds the **cert-limit** issue (each Archive mints a cert; ~2-3 cap). Expect CI signing iteration; the cert-revoke dance may recur. **Mitigation:** a minimal extension target first (Task: just an empty extension that builds+signs in CI) before adding the full code — validate signing early.
2. **responder-chain openURL** (Option A): non-official; if Apple changes it or rejects, fall back to Option B (App Group save + manual app open) — the App-Group read path is identical, only the auto-open differs, so the fallback is cheap.
3. **App Group entitlement must match** on both targets + the portal group id exactly, or the shared UserDefaults silently returns nil.

## Out of scope (v1 of Phase 2)
- A rich extension UI (we auto-complete + hand off).
- Bilibili share (Phase 3).
- Sharing anything other than a URL.

## Testing
- Extension URL parsing: unit-test the "extract URL from a plain-text/url string" helper.
- App Group round-trip: unit-test set/get/clear.
- End-to-end (device): YouTube app → Share → whatSub → app opens ImportView with the URL → import works (Phase 1).

## Phasing within Phase 2
- **2a:** minimal extension target (empty, just builds+signs in CI) + the App Group + URL scheme + main-app deep-link plumbing (manual: paste `whatsub://import` to test the route). Validates the signing + plumbing — the riskiest infra.
- **2b:** the real ShareViewController (URL extract → App Group → openURL) + ImportView prefill/auto-run + end-to-end.
