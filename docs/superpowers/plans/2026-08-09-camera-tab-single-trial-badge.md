# Camera Tab Single Trial Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the duplicate-looking photo AI trial badge while preserving the live-scene badge and camera action.

**Architecture:** Make a presentation-only change in `CameraTabView`. Protect the intended header structure with a source regression test; entitlement and trial lifecycle code remain untouched.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest.

## Global Constraints

- Keep exactly one `FeatureTrialBadge` in `CameraTabView`.
- The remaining badge must use `.liveScene`.
- Preserve the photo-translation button action and accessibility label.

---

### Task 1: Remove the photo AI header badge

**Files:**
- Create: `whatsub-mobileTests/CameraTabTrialBadgeSourceTests.swift`
- Modify: `whatsub-mobile/Camera/CameraTabView.swift`

- [ ] Write a source test requiring one live-scene badge and no photo-AI badge.
- [ ] Run CI to verify the test fails against the current two-badge header.
- [ ] Remove only the badge from the camera button label.
- [ ] Run the complete iOS CI and verify build, tests, install, and screenshot.
