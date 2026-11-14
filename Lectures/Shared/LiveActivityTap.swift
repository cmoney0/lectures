import SwiftUI

// Tap feedback on the Live Activity buttons (Colby, 2026-11-14: "there needs to
// be some animations right away as you click the buttons ... pulsing and
// loading ... exactly how the habit logger animations are"). Same look as
// LifeOS's LOSTap / LOSTapAnim / LOSTapRing (lifeos PR #768), copied here
// because the two apps don't share code. Compiled into the app, the widget
// extension and the unit tests.
//
// A Live Activity can't animate on its own, so the app drives it: the button's
// intent puts step 0 (a bloom) into the content state at once, then steps 1
// (a ring draws round), 2 (the ring sweeps away) and nil (idle).

struct LectureTap: Codable, Hashable {
    var key: String     // which button: "pause" or "stop"
    var step: Int
    var id: Int = Int.random(in: 1...Int.max)
}

enum LectureTapAnim {
    /// Delay before each step after the step-0 update (ms): ring on, ring away, idle.
    static let plan: [(step: Int?, ms: UInt64)] = [(1, 260), (2, 800), (nil, 760)]

    /// Runs steps 1, 2, idle. `set` returns false once a newer tap (or another
    /// change) has replaced this one, which stops the animation.
    static func play(_ set: (Int?) async -> Bool) async {
        for (step, ms) in plan {
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            guard await set(step) else { return }
        }
    }

    /// The whole animation, so a stop can hold the activity until it has played.
    static var totalMs: UInt64 { plan.reduce(0) { $0 + $1.ms } }
}

extension Optional where Wrapped == LectureTap {
    /// This button's step, nil when it isn't the one tapped.
    func step(_ key: String) -> Int? {
        guard let t = self, t.key == key else { return nil }
        return t.step
    }
}

/// The bloom + ring drawn BEHIND a Live Activity button (never inside its
/// label, so the button itself stays plain and keeps working in place).
struct LectureTapRing<S: Shape>: View {
    let shape: S
    let step: Int?
    let color: Color

    var body: some View {
        let s = step ?? -1
        ZStack {
            shape.fill(color)
                .scaleEffect(s == 0 ? 1.4 : 1)
                .opacity(s == 0 ? 0.3 : 0)
                .animation(.easeOut(duration: 0.26), value: s)
            shape.trim(from: s >= 2 ? 1 : 0, to: s >= 1 ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(-3.5)
                .opacity(s >= 1 ? 1 : 0)
                .animation(.easeInOut(duration: 0.75), value: s)
        }
        .allowsHitTesting(false)
    }
}
