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
/// Just a red dot - no timer (Colby). If the app stops heartbeating (crash),
/// the activity goes stale and says so instead of looking like it's recording.
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
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(mode == .stopped ? "Open Lectures to continue this lecture." : context.state.lastLine)
                            .font(.system(size: 13)).foregroundStyle(LectureColors.sub).lineLimit(2)
                        if mode != .stopped { Buttons(paused: mode == .paused) }
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

private enum Mode: Equatable {
    case recording, paused, stopped

    init(state: LectureActivityAttributes.ContentState, stale: Bool) {
        self = stale ? .stopped : (state.pausedElapsed != nil ? .paused : .recording)
    }

    var label: String {
        switch self {
        case .recording: "Recording lecture"
        case .paused: "Paused"
        case .stopped: "Recording stopped"
        }
    }

    var color: Color {
        switch self {
        case .recording: LectureColors.red
        case .paused, .stopped: LectureColors.sub
        }
    }
}

/// The red recording dot (gray when paused, hollow when stopped).
private struct RecDot: View {
    let mode: Mode
    let size: CGFloat

    var body: some View {
        if mode == .stopped {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecDot(mode: mode, size: 12)
                Text(mode.label).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(mode == .recording ? LectureColors.text : LectureColors.sub)
                Spacer()
            }
            Text(mode == .stopped ? "The app closed. Open Lectures to continue this lecture." : state.lastLine)
                .font(.system(size: 13)).foregroundStyle(LectureColors.sub).lineLimit(2)
            if mode != .stopped { Buttons(paused: mode == .paused) }
        }
        .padding(16)
    }
}

private struct Buttons: View {
    let paused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: PauseLectureIntent()) {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded)).frame(maxWidth: .infinity)
            }
            .tint(LectureColors.sub)
            Button(intent: StopLectureIntent()) {
                Label("Stop & send", systemImage: "stop.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded)).frame(maxWidth: .infinity)
            }
            .tint(LectureColors.red)
        }
        .buttonStyle(.borderedProminent)
    }
}
