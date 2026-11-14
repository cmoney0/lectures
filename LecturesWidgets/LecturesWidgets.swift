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
/// Just a red dot - no timer (Colby). It says "Recording stopped" only when
/// LifeOS pushes that the app went silent (LiveActivityPolicy) - never on its own.
struct LectureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LectureActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(LectureColors.bg)
                .activitySystemActionForegroundColor(LectureColors.text)
        } dynamicIsland: { context in
            let mode = Mode(state: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RecDot(mode: mode, size: 10)
                        Text(mode.label).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(mode.color)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if mode.showsControls { Buttons(state: context.state, paused: mode == .paused) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if mode == .stopped {
                        Text("Open Lectures to continue this lecture.").font(.system(size: 13)).foregroundStyle(LectureColors.sub)
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
    /// Only LifeOS's push (lost) can say stopped - never the system's stale flag.
    init(state: LectureActivityAttributes.ContentState) {
        self.init(paused: state.pausedElapsed != nil, lost: state.lost == true,
                  stopping: state.stopping == true, saved: state.saved == true)
    }

    var color: Color {
        switch self {
        case .recording: LectureColors.red
        case .paused, .stopped, .saving: LectureColors.sub
        case .saved: LectureColors.accent
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
        } else if mode == .saved {
            Image(systemName: "checkmark.circle.fill").font(.system(size: size + 2, weight: .bold))
                .foregroundStyle(LectureColors.accent)
        } else {
            Circle().fill(mode.color).frame(width: size, height: size)
        }
    }
}

private struct LockScreenView: View {
    let state: LectureActivityAttributes.ContentState

    var body: some View {
        let mode = Mode(state: state)
        // No transcript - just the dot, the state and icon-only controls (Colby).
        HStack(spacing: 10) {
            RecDot(mode: mode, size: 12)
            Text(mode.lockScreenText)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(mode == .recording ? LectureColors.text : LectureColors.sub)
                .lineLimit(1)
            Spacer()
            if mode.showsControls { Buttons(state: state, paused: mode == .paused) }
        }
        .padding(16)
    }
}

private struct Buttons: View {
    let state: LectureActivityAttributes.ContentState
    let paused: Bool
    /// The bordered circle button's size (22 pt icon frame + padding).
    private let size: CGFloat = 40

    var body: some View {
        // icons only: pause / play, and stop (stop sends with your default review).
        // Each tap pulses at once (bloom, then a ring draws round and away) while
        // the app does the work - same feel as the LifeOS habit logger.
        HStack(spacing: 10) {
            Button(intent: PauseLectureIntent()) {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 16, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
                    .invalidatableContent()
            }
            .tint(LectureColors.sub)
            .background {
                LectureTapRing(shape: Circle(), step: state.tap.step("pause"), color: LectureColors.text)
                    .frame(width: size, height: size)
            }
            Button(intent: StopLectureIntent()) {
                Image(systemName: "stop.fill").font(.system(size: 16, weight: .bold))
                    .frame(width: 22, height: 22)
                    .invalidatableContent()
            }
            .tint(LectureColors.red)
            .background {
                LectureTapRing(shape: Circle(), step: state.tap.step("stop"), color: LectureColors.red)
                    .frame(width: size, height: size)
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
    }
}
