import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LecturesWidgets: WidgetBundle {
    var body: some Widget {
        LectureLiveActivity()
        RecordLectureControl()
    }
}

/// Lock Screen / Control Center / Action Button control: one tap starts recording.
struct RecordLectureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.cmoney0.lectures.record") {
            ControlWidgetButton(action: StartLectureIntent()) {
                Label("Record lecture", systemImage: "record.circle")
            }
        }
        .displayName("Record lecture")
        .description("Start recording and transcribing a class.")
    }
}

/// Recording indicator + Pause / Stop on the Lock Screen and in the Dynamic Island.
/// Just a red dot - no timer (Colby). Only after a long silence (15 min, see
/// LiveActivityPolicy) does it say "no signal"; crashes alert by notification.
struct LectureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LectureActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(LectureColors.bg)
                .activitySystemActionForegroundColor(LectureColors.text)
        } dynamicIsland: { context in
            let mode = Mode(state: context.state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RecDot(mode: mode, size: 10)
                        Text(mode.label).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(mode.color)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if mode.showsControls { Buttons(paused: mode == .paused) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if mode == .noSignal {
                        Text("Open Lectures to check the recording.").font(.system(size: 13)).foregroundStyle(LectureColors.sub)
                    }
                }
            } compactLeading: {
                RecDot(mode: mode, size: 10)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                RecDot(mode: mode, size: 10)
            }
        }
    }
}

// Mode = LiveActivityMode (Lectures/Shared/LiveActivityPolicy.swift, unit-tested).
private typealias Mode = LiveActivityMode

private extension LiveActivityMode {
    init(state: LectureActivityAttributes.ContentState, stale: Bool) {
        self.init(paused: state.pausedElapsed != nil, stale: stale)
    }

    var color: Color {
        switch self {
        case .recording: LectureColors.red
        case .paused, .noSignal: LectureColors.sub
        }
    }
}

/// The red recording dot (gray when paused, hollow when stopped).
private struct RecDot: View {
    let mode: Mode
    let size: CGFloat

    var body: some View {
        if mode == .noSignal {
            Circle().stroke(LectureColors.sub, lineWidth: 2).frame(width: size, height: size)
        } else {
            Circle().fill(mode.color).frame(width: size, height: size)
        }
    }
}

private struct LockScreenView: View {
    let state: LectureActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let mode = Mode(state: state, stale: stale)
        // No transcript - just the dot, the state and icon-only controls (Colby).
        HStack(spacing: 10) {
            RecDot(mode: mode, size: 12)
            Text(mode.lockScreenText)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(mode == .recording ? LectureColors.text : LectureColors.sub)
                .lineLimit(1)
            Spacer()
            if mode.showsControls { Buttons(paused: mode == .paused) }
        }
        .padding(16)
    }
}

private struct Buttons: View {
    let paused: Bool

    var body: some View {
        // icons only: pause / play, and stop (stop sends with your default review)
        HStack(spacing: 10) {
            Button(intent: PauseLectureIntent()) {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 16, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .tint(LectureColors.sub)
            Button(intent: StopLectureIntent()) {
                Image(systemName: "stop.fill").font(.system(size: 16, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .tint(LectureColors.red)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
    }
}
