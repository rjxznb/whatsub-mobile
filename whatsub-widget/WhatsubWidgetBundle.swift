import SwiftUI
import WidgetKit

/// Bundle entry point for the whatSub Widget Extension. Hosts the iOS
/// Live Activity for desktop import queue progress — see
/// `docs/superpowers/plans/2026-06-18-ios-live-activity-import-queue.md`.
///
/// New WidgetConfiguration instances added later (lock-screen widgets,
/// home-screen widgets) get added to the `body` builder below.
@main
struct WhatsubWidgetBundle: WidgetBundle {
    var body: some Widget {
        ImportActivityWidget()
    }
}
