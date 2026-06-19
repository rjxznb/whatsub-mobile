import SwiftUI
import WidgetKit
import ActivityKit

/// Live Activity for desktop import queue progress. Drives three surfaces:
///   • Lock-screen card (all iOS 16.1+ devices)
///   • Dynamic Island compact / minimal (iPhone 14 Pro+ only)
///   • Dynamic Island expanded (long-press / pull-down on iPhone 14 Pro+)
///
/// Tap routing (`widgetURL`): the Activity opens
///   `whatsub://import-queue` while items are still in flight
///   `whatsub://library` once everything reached a terminal state
/// — handled by WhatsubMobileApp's `.onOpenURL` (Phase 5.4).
struct ImportActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ImportActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color.whatsubBgElev)
                .activitySystemActionForegroundColor(Color.whatsubInk)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundStyle(.whatsubAccent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.completed)/\(totalCount(context.state))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.whatsubInk)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        ProgressView(value: progressFraction(context.state))
                            .tint(.whatsubAccent)
                        if let title = context.state.recentTitle, !title.isEmpty {
                            Text(title)
                                .font(.caption2)
                                .foregroundStyle(.whatsubInkMuted)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(bottomHint(context.state))
                        .font(.caption2)
                        .foregroundStyle(.whatsubInkMuted)
                }
            } compactLeading: {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(.whatsubAccent)
            } compactTrailing: {
                Text("\(context.state.inProgress)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.whatsubInk)
            } minimal: {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(.whatsubAccent)
            }
            .widgetURL(URL(string: tapDestination(context.state)))
        }
    }

    private func totalCount(_ s: ImportActivityAttributes.ContentState) -> Int {
        s.inProgress + s.completed + s.failed
    }

    private func progressFraction(_ s: ImportActivityAttributes.ContentState) -> Double {
        let total = totalCount(s)
        return total == 0 ? 0 : Double(s.completed + s.failed) / Double(total)
    }

    private func bottomHint(_ s: ImportActivityAttributes.ContentState) -> String {
        if s.inProgress > 0 { return "点击查看队列详情 →" }
        if s.failed > 0 { return "有 \(s.failed) 个失败 — 点击查看 →" }
        return "点击打开 Library →"
    }

    private func tapDestination(_ s: ImportActivityAttributes.ContentState) -> String {
        s.inProgress > 0 ? "whatsub://import-queue" : "whatsub://library"
    }
}
