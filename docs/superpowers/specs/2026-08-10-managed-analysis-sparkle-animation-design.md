# Managed Analysis Sparkle Animation Design

## Goal

Make the left-hand sparkle in the Library detail analysis banner communicate that the server is still actively processing, without moving the banner layout or distracting from subtitles.

## Behavior

- While `managedProgress.isPolling` is true, the existing `sparkles` symbol runs a repeating breathing animation.
- The symbol eases between scale `0.92` and `1.10` and opacity `0.55` and `1.0` over 0.9 seconds, then reverses.
- Queued and running server-analysis states both animate because both are represented by the existing polling state.
- Completed, failed, quota-paused, user-stopped, and resumable states do not animate. Their existing icon and text behavior remains unchanged.
- The animation changes only scale and opacity, so the icon keeps the same layout footprint and the banner text does not shift.
- If iOS Reduce Motion is enabled, the sparkle remains static at scale `1.0` and opacity `1.0`.
- When the view disappears or polling stops, the repeating animation stops with the view/state rather than leaving an independent timer running.

## Implementation shape

Extract the icon into a small Library-local SwiftUI view that accepts `isActive`. It owns only the transient animation state and reads `accessibilityReduceMotion`; analysis state remains owned by `LibraryDetailViewModel`.

Use the same 0.9-second scale-and-opacity visual language already present in `ImportView.PulsingIcon`, but do not refactor the unrelated import screen in this release.

## Testing

- A pure presentation model maps active polling plus Reduce Motion state to animated versus static presentation.
- Tests cover polling, non-polling, and Reduce Motion behavior.
- GitHub macOS CI verifies Swift compilation and simulator tests after the feature branch is merged into `main`.

## Rollout

Ship this animation in the same TestFlight build as the already completed highlighted-word pronunciation and one-tap collection changes. No backend change is required.
