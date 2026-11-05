import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// The in-depth study guide (made for the iPad): read each section with the
/// professor's slide figures, then fill in the blanks; finish by working the
/// problems step by step on a Pencil scratchpad.
struct GuideView: View {
    let guide: LectureReview.Guide

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let intro = guide.intro, !intro.isEmpty {
                Text(intro).font(.m(17)).foregroundStyle(Theme.text).lineSpacing(4)
            }
            ForEach(Array((guide.sections ?? []).enumerated()), id: \.offset) { i, section in
                GuideSectionView(number: i + 1, section: section)
            }
            if let problems = guide.problems, !problems.isEmpty {
                Text("Do the work").font(.m(22, .heavy)).foregroundStyle(Theme.text).padding(.top, 8)
                ForEach(Array(problems.enumerated()), id: \.offset) { i, problem in
                    ProblemView(number: i + 1, problem: problem)
                }
            }
            if let sources = guide.sources, !sources.isEmpty {
                Text("Slides: " + sources.compactMap(\.name).joined(separator: ", "))
                    .font(.m(12)).foregroundStyle(Theme.sub)
            }
        }
        .frame(maxWidth: 820, alignment: .leading) // readable line length on iPad
        .frame(maxWidth: .infinity)
    }
}

private struct GuideSectionView: View {
    let number: Int
    let section: LectureReview.Guide.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(number). \(section.heading ?? "")").font(.m(22, .heavy)).foregroundStyle(Theme.text)
            ForEach(Array((section.read ?? []).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).font(.m(16)).foregroundStyle(Theme.text).lineSpacing(5).textSelection(.enabled)
            }
            ForEach(Array((section.figures ?? []).enumerated()), id: \.offset) { _, figure in
                SlideFigure(figure: figure)
            }
            if let blanks = section.fillIns, !blanks.isEmpty {
                FillInBlock(sentences: blanks)
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: figures

/// One slide page, rendered on the device from the Canvas PDF. Tap to zoom.
struct SlideFigure: View {
    let figure: LectureReview.Guide.Figure
    @State private var image: UIImage?
    @State private var failed = false
    @State private var zoomed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { zoomed = true }
                } else if failed {
                    Label("Slide \(figure.page ?? 0) couldn't load", systemImage: "photo").font(.m(12)).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            if let caption = figure.caption, !caption.isEmpty {
                Text(caption).font(.m(13, .semibold)).foregroundStyle(Theme.sub)
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $zoomed) {
            ZoomedImage(image: image) { zoomed = false }
        }
    }

    private func load() async {
        guard image == nil, let id = figure.fileId, let page = figure.page else { failed = true; return }
        if let img = await SlideRenderer.image(fileId: id, page: page) { image = img } else { failed = true }
    }
}

enum SlideRenderer {
    /// Renders a 1-based page of a cached Canvas PDF; downloads it first if needed.
    @MainActor
    static func image(fileId: String, page: Int, width: CGFloat = 1600) async -> UIImage? {
        guard let url = try? await LifeOSClient.shared.slideDeck(fileId) else { return nil }
        return render(url: url, page: page, width: width)
    }

    /// Only from the local cache (PDF export).
    static func cachedImage(fileId: String, page: Int, width: CGFloat = 1200) -> UIImage? {
        let url = URL.cachesDirectory.appendingPathComponent("Slides/\(fileId.filter(\.isNumber)).pdf")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return render(url: url, page: page, width: width)
    }

    private static func render(url: URL, page: Int, width: CGFloat) -> UIImage? {
        guard let doc = PDFDocument(url: url), page >= 1, let p = doc.page(at: page - 1) else { return nil }
        let box = p.bounds(for: .mediaBox)
        guard box.width > 0 else { return nil }
        let size = CGSize(width: width, height: width * box.height / box.width)
        return p.thumbnail(of: size, for: .mediaBox)
    }
}

private struct ZoomedImage: View {
    let image: UIImage?
    var close: () -> Void
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in withAnimation { scale = 1 } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(20)
        }
    }
}

// MARK: fill in the blanks

/// "The {{Reynolds number}} compares ..." -> words with typeable blanks.
struct FillInBlock: View {
    let sentences: [String]
    @State private var answers: [String: String] = [:]
    @State private var checked = false
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Check yourself", systemImage: "pencil.and.list.clipboard").font(.m(13, .heavy)).foregroundStyle(Theme.accent)
            ForEach(Array(sentences.enumerated()), id: \.offset) { si, sentence in
                FlowLayout(spacing: 4, lineSpacing: 8) {
                    ForEach(Array(Cloze.parse(sentence).enumerated()), id: \.offset) { pi, piece in
                        switch piece {
                        case .text(let word):
                            Text(word).font(.m(16)).foregroundStyle(Theme.text)
                        case .blank(let answer):
                            BlankField(answer: answer, text: binding("\(si)-\(pi)"), checked: checked, revealed: revealed)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button(checked ? "Checked" : "Check") { checked = true }
                    .font(.m(14, .bold)).buttonStyle(.borderedProminent).tint(Theme.accent)
                Button(revealed ? "Hide answers" : "Show answers") { revealed.toggle() }
                    .font(.m(14, .bold)).buttonStyle(.bordered)
                if checked {
                    Text("\(score.0) / \(score.1)").font(.m(14, .bold)).foregroundStyle(Theme.sub)
                    Button("Reset") { answers = [:]; checked = false; revealed = false }.font(.m(13, .semibold))
                }
            }
        }
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0; checked = false })
    }

    private var score: (Int, Int) {
        var right = 0, total = 0
        for (si, sentence) in sentences.enumerated() {
            for (pi, piece) in Cloze.parse(sentence).enumerated() {
                guard case .blank(let answer) = piece else { continue }
                total += 1
                if Cloze.matches(answers["\(si)-\(pi)"] ?? "", answer) { right += 1 }
            }
        }
        return (right, total)
    }
}

private struct BlankField: View {
    let answer: String
    @Binding var text: String
    let checked: Bool
    let revealed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: $text)
                .font(.m(16, .semibold))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: max(70, CGFloat(answer.count) * 10 + 24))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.accent).frame(height: 1.5) }
            if revealed || (checked && !Cloze.matches(text, answer)) {
                Text(answer).font(.m(11, .bold)).foregroundStyle(Theme.green)
            }
        }
    }

    private var fill: Color {
        guard checked else { return Theme.card }
        return Cloze.matches(text, answer) ? Theme.green.opacity(0.2) : Theme.red.opacity(0.15)
    }
}

enum Cloze {
    enum Piece { case text(String), blank(String) }

    /// Splits into single words (so lines wrap naturally) and {{blanks}}.
    static func parse(_ sentence: String) -> [Piece] {
        var out: [Piece] = []
        var rest = Substring(sentence)
        while let open = rest.range(of: "{{") {
            out += words(rest[..<open.lowerBound])
            guard let close = rest[open.upperBound...].range(of: "}}") else { out += words(rest[open.lowerBound...]); return out }
            out.append(.blank(String(rest[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)))
            rest = rest[close.upperBound...]
        }
        return out + words(rest)
    }

    private static func words(_ s: Substring) -> [Piece] {
        s.split(separator: " ").map { .text(String($0)) }
    }

    static func matches(_ typed: String, _ answer: String) -> Bool {
        let norm: (String) -> String = {
            $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        }
        let a = norm(typed), b = norm(answer)
        return !a.isEmpty && (a == b || (b.count > 5 && b.hasPrefix(a) && a.count >= b.count - 2))
    }
}

/// Wraps views onto lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: problems

/// Work it on the scratchpad, then reveal the solution one step at a time.
struct ProblemView: View {
    let number: Int
    let problem: LectureReview.Guide.Problem
    @State private var shownSteps = 0
    @State private var showAnswer = false
    @State private var showPad = UIDevice.current.userInterfaceIdiom == .pad

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Problem \(number)").font(.m(12, .heavy)).foregroundStyle(Theme.accent)
            Text(problem.prompt ?? "").font(.m(16, .semibold)).foregroundStyle(Theme.text).textSelection(.enabled)

            Button { showPad.toggle() } label: {
                Label(showPad ? "Hide scratchpad" : "Work it out", systemImage: "applepencil.and.scribble").font(.m(13, .bold))
            }
            if showPad { ScratchPad().frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12)) }

            let steps = problem.steps ?? []
            ForEach(0..<min(shownSteps, steps.count), id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").font(.m(12, .heavy)).foregroundStyle(.white).frame(width: 20, height: 20)
                        .background(Theme.accent, in: Circle())
                    Text(steps[i]).font(.m(15)).foregroundStyle(Theme.text)
                }
            }
            if showAnswer, let answer = problem.answer {
                Text("Answer: \(answer)").font(.m(15, .bold)).foregroundStyle(Theme.green)
            }
            HStack(spacing: 10) {
                if shownSteps < steps.count {
                    Button(shownSteps == 0 ? "Show first step" : "Next step") { withAnimation { shownSteps += 1 } }
                        .font(.m(14, .bold)).buttonStyle(.bordered)
                }
                if !showAnswer {
                    Button("Show answer") { withAnimation { showAnswer = true } }
                        .font(.m(14, .bold)).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                if shownSteps > 0 || showAnswer {
                    Button("Hide") { shownSteps = 0; showAnswer = false }.font(.m(13, .semibold))
                }
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A plain PencilKit canvas (finger or Apple Pencil); not saved.
struct ScratchPad: UIViewRepresentable {
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
        canvas.backgroundColor = UIColor.secondarySystemBackground
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}
}
