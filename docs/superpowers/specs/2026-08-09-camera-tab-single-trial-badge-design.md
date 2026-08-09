# Camera Tab Single Trial Badge

## Goal

Show only one “免费体验 1 次” badge in the 实景口语 tab header.

## Design

- Keep the badge below “实景口语练习”; it describes the tab’s primary live-scene feature.
- Remove the badge below the top-right photo-translation camera icon.
- Keep the photo AI entitlement, free-trial state, tap behavior, and subscription gate unchanged.
- Keep the camera button’s icon, hit target, and accessibility label unchanged.

## Verification

Add a source regression test proving the header contains only one
`FeatureTrialBadge` and that it remains bound to `.liveScene`, while the camera
button still opens photo translation and retains its accessibility label.
