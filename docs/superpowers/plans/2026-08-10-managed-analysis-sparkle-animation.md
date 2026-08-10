# Managed Analysis Sparkle Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Animate the Library detail server-analysis sparkle only while polling, while preserving a static icon for stopped states and Reduce Motion users.

**Architecture:** Add a tiny pure presentation policy and a Library-local SwiftUI icon view. `LibraryDetailView` continues to own analysis state and passes only `progress.isPolling`; the icon owns transient pulse state and no timers or backend logic.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, iOS 16+

## Global Constraints

- Use scale `0.92...1.10` and opacity `0.55...1.0` with a 0.9-second autoreversing ease-in-out animation.
- Animate only while `managedProgress.isPolling == true`.
- Keep the icon static when Reduce Motion is enabled.
- Do not change banner layout, text, progress, cancellation, resume, or backend behavior.
- Do not use iOS 17-only symbol effects; the project minimum remains iOS 16.

---

### Task 1: Define and test sparkle animation policy

**Files:**
- Create: `whatsub-mobile/Library/ManagedAnalysisSparkleIcon.swift`
- Create: `whatsub-mobileTests/ManagedAnalysisSparkleIconTests.swift`

**Interfaces:**
- Produces: `ManagedAnalysisSparklePresentation.init(isPolling:reduceMotion:)`
- Produces: `shouldAnimate`, `restingScale`, `expandedScale`, `restingOpacity`, `expandedOpacity`
- Produces: `ManagedAnalysisSparkleIcon.init(isActive:)`

- [ ] **Step 1: Write the failing policy tests**

```swift
import XCTest
@testable import whatsub_mobile

final class ManagedAnalysisSparkleIconTests: XCTestCase {
    func testPollingAnimatesWithSpecifiedEndpoints() {
        let value = ManagedAnalysisSparklePresentation(
            isPolling: true,
            reduceMotion: false
        )

        XCTAssertTrue(value.shouldAnimate)
        XCTAssertEqual(value.restingScale, 0.92, accuracy: 0.001)
        XCTAssertEqual(value.expandedScale, 1.10, accuracy: 0.001)
        XCTAssertEqual(value.restingOpacity, 0.55, accuracy: 0.001)
        XCTAssertEqual(value.expandedOpacity, 1.0, accuracy: 0.001)
    }

    func testNonPollingIsStatic() {
        let value = ManagedAnalysisSparklePresentation(
            isPolling: false,
            reduceMotion: false
        )
        XCTAssertFalse(value.shouldAnimate)
        XCTAssertEqual(value.restingScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(value.restingOpacity, 1.0, accuracy: 0.001)
    }

    func testReduceMotionOverridesPolling() {
        let value = ManagedAnalysisSparklePresentation(
            isPolling: true,
            reduceMotion: true
        )
        XCTAssertFalse(value.shouldAnimate)
        XCTAssertEqual(value.restingScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(value.restingOpacity, 1.0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Push the failing test commit and verify CI fails for the missing type**

Run:

```powershell
git add whatsub-mobileTests/ManagedAnalysisSparkleIconTests.swift
git commit -m "test: define managed analysis sparkle behavior"
git push origin codex/highlight-word-actions
gh run watch --exit-status
```

Expected: the macOS test build fails because `ManagedAnalysisSparklePresentation` does not exist.

- [ ] **Step 3: Implement the pure policy and SwiftUI icon**

```swift
import SwiftUI

struct ManagedAnalysisSparklePresentation: Equatable {
    let shouldAnimate: Bool
    let restingScale: CGFloat
    let expandedScale: CGFloat
    let restingOpacity: Double
    let expandedOpacity: Double

    init(isPolling: Bool, reduceMotion: Bool) {
        shouldAnimate = isPolling && !reduceMotion
        if shouldAnimate {
            restingScale = 0.92
            expandedScale = 1.10
            restingOpacity = 0.55
            expandedOpacity = 1.0
        } else {
            restingScale = 1.0
            expandedScale = 1.0
            restingOpacity = 1.0
            expandedOpacity = 1.0
        }
    }
}

struct ManagedAnalysisSparkleIcon: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var presentation: ManagedAnalysisSparklePresentation {
        .init(isPolling: isActive, reduceMotion: reduceMotion)
    }

    var body: some View {
        Image(systemName: "sparkles")
            .scaleEffect(expanded ? presentation.expandedScale : presentation.restingScale)
            .opacity(expanded ? presentation.expandedOpacity : presentation.restingOpacity)
            .animation(
                presentation.shouldAnimate
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: expanded
            )
            .onAppear(perform: updateAnimation)
            .onChange(of: isActive) { _ in updateAnimation() }
            .onChange(of: reduceMotion) { _ in updateAnimation() }
    }

    private func updateAnimation() {
        expanded = presentation.shouldAnimate
    }
}
```

- [ ] **Step 4: Commit the implementation**

```powershell
git add whatsub-mobile/Library/ManagedAnalysisSparkleIcon.swift
git commit -m "feat: animate managed analysis sparkle"
```

### Task 2: Integrate the icon and verify the release branch

**Files:**
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift:429-438`

**Interfaces:**
- Consumes: `ManagedAnalysisSparkleIcon(isActive:)` from Task 1
- Preserves: the existing non-polling `exclamationmark.circle` icon

- [ ] **Step 1: Replace only the polling icon branch**

```swift
if progress.isPolling {
    ManagedAnalysisSparkleIcon(isActive: true)
} else {
    Image(systemName: "exclamationmark.circle")
}
```

- [ ] **Step 2: Commit integration**

```powershell
git add whatsub-mobile/Library/LibraryDetailView.swift
git commit -m "feat: show activity in analysis banner"
```

- [ ] **Step 3: Push and verify feature-branch macOS CI**

```powershell
git push origin codex/highlight-word-actions
gh run watch --exit-status
```

Expected: simulator build and all tests pass, including `ManagedAnalysisSparkleIconTests`.

- [ ] **Step 4: Merge into `main` without touching the untracked root `AGENTS.md`**

```powershell
git -C "C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-mobile" merge --no-ff codex/highlight-word-actions
git -C "C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-mobile" push origin main
```

- [ ] **Step 5: Verify main CI and TestFlight**

Use `gh run list` to identify the two runs whose `headSha` equals the new merge commit, then watch both with `gh run watch <id> --exit-status`.

Expected: `ci.yml` succeeds and `testflight.yml` succeeds through App Store upload.
