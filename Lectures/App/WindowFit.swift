import SwiftUI
import UIKit

/// iPad launch fix (Colby, 2026-11-10): about half the launches drew the app
/// in only the left half of the screen until it was relaunched. iPadOS 26
/// can show the launch in a partial window first and resize it; the app
/// sometimes stays laid out at that first size. This keeps the window, and
/// the view inside it, the size of the scene: at launch, on every geometry
/// change and each time the app becomes active. On iPhone it never changes
/// anything (the sizes already match).
struct WindowFit: UIViewRepresentable {
    func makeUIView(context: Context) -> FitView { FitView() }
    func updateUIView(_ view: FitView, context: Context) { view.fit() }

    final class FitView: UIView {
        private var geometryWatch: NSKeyValueObservation?
        private var activeWatch: NSObjectProtocol?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            activeWatch = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitSoon() }
            }
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            if let activeWatch { NotificationCenter.default.removeObserver(activeWatch) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            geometryWatch = nil
            guard let scene = window?.windowScene else { return }
            geometryWatch = scene.observe(\.effectiveGeometry, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.fitSoon() }
            }
            fitSoon()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            fit()
        }

        /// Now, and again once the launch animation / resize has settled.
        func fitSoon() {
            fit()
            for delay in [0.15, 0.5, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.fit() }
            }
        }

        func fit() {
            guard let window, let scene = window.windowScene else { return }
            let target = scene.coordinateSpace.bounds
            guard target.width > 0, target.height > 0 else { return }
            if !Self.same(window.frame, target) {
                window.frame = target
            }
            if let root = window.rootViewController?.view, !Self.same(root.frame, window.bounds) {
                root.frame = window.bounds
                root.setNeedsLayout()
                root.layoutIfNeeded()
            }
        }

        private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
                && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
    }
}
