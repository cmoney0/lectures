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

/// Recording timer + Pause / Stop on the Lock Screen and in the Dynamic Island.
struct LectureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LectureActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(LectureColors.bg)
                .activitySystemActionForegroundColor(LectureColors.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(context.state.pausedElapsed == nil ? "REC" : "PAUSED") } icon: { Image(systemName: "waveform") }
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(context.state.pausedElapsed == nil ? LectureColors.red : LectureColors.sub)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: context.state).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.lastLine).font(.system(size: 13)).foregroundStyle(LectureColors.sub).lineLimit(2)
                        Buttons(paused: context.state.pausedElapsed != nil)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.pausedElapsed == nil ? "record.circle" : "pause.circle")
                    .foregroundStyle(context.state.pausedElapsed == nil ? LectureColors.red : LectureColors.sub)
            } compactTrailing: {
                TimerText(state: context.state).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "record.circle").foregroundStyle(LectureColors.red)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: LectureActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.pausedElapsed == nil ? "Recording lecture" : "Paused", systemImage: "waveform")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(state.pausedElapsed == nil ? LectureColors.accent : LectureColors.sub)
                Spacer()
                TimerText(state: state).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(LectureColors.text)
            }
            Text(state.lastLine).font(.system(size: 13)).foregroundStyle(LectureColors.sub).lineLimit(2)
            Buttons(paused: state.pausedElapsed != nil)
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

/// Counts up live while recording; frozen while paused.
private struct TimerText: View {
    let state: LectureActivityAttributes.ContentState

    var body: some View {
        if let paused = state.pausedElapsed {
            Text(Self.format(paused))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
