import SwiftUI
import UIKit

/// Claude's notes: summary, exam flags, sections, key terms, follow-ups.
struct ReviewNotesView: View {
    let review: LectureReview
    var seek: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = review.summary, !summary.isEmpty {
                Card { Text(summary).font(.m(15)).foregroundStyle(Theme.text) }
            }
            if let flags = review.examFlags, !flags.isEmpty {
                Card {
                    Label("Likely on the exam", systemImage: "exclamationmark.circle.fill").font(.m(13, .heavy)).foregroundStyle(Theme.accent)
                    ForEach(flags, id: \.self) { flag in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let at = flag.at, !at.isEmpty {
                                Button(at) { seek(at) }.font(.m(11, .semibold)).monospacedDigit().foregroundStyle(Theme.accent).buttonStyle(.plain)
                            }
                            Text(flag.text ?? "").font(.m(14)).foregroundStyle(Theme.text)
                        }
                    }
                }
            }
            ForEach(review.sections ?? [], id: \.self) { section in
                Card {
                    Text(section.heading ?? "").font(.m(16, .bold)).foregroundStyle(Theme.text)
                    ForEach(section.points ?? [], id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: -2)
                            Text(point).font(.m(14)).foregroundStyle(Theme.text).textSelection(.enabled)
                        }
                    }
                }
            }
            if let terms = review.keyTerms, !terms.isEmpty {
                Card {
                    Text("Key terms").font(.m(13, .heavy)).foregroundStyle(Theme.sub)
                    ForEach(terms, id: \.self) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.term ?? "").font(.m(14, .bold)).foregroundStyle(Theme.text)
                            Text(t.definition ?? "").font(.m(13)).foregroundStyle(Theme.sub)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if let follow = review.followUps, !follow.isEmpty {
                Card {
                    Text("Follow up").font(.m(13, .heavy)).foregroundStyle(Theme.sub)
                    ForEach(follow, id: \.self) { Text("- \($0)").font(.m(14)).foregroundStyle(Theme.text) }
                }
            }
        }
    }
}

/// Tap to flip, swipe for the next card.
struct FlashcardsView: View {
    let cards: [LectureReview.Card]
    @State private var flipped: Set<Int> = []
    @State private var index = 0

    var body: some View {
        if cards.isEmpty {
            Card { Text("No flashcards in this review.").font(.m(14)).foregroundStyle(Theme.sub) }
        } else {
            VStack(spacing: 10) {
                TabView(selection: $index) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { i, card in
                        let isFlipped = flipped.contains(i)
                        VStack(spacing: 12) {
                            Text(isFlipped ? "ANSWER" : "QUESTION").font(.m(11, .heavy)).foregroundStyle(isFlipped ? Theme.accent : Theme.sub)
                            Text(isFlipped ? (card.back ?? "") : (card.front ?? ""))
                                .font(.m(isFlipped ? 17 : 20, isFlipped ? .medium : .bold))
                                .foregroundStyle(Theme.text).multilineTextAlignment(.center)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .rotation3DEffect(.degrees(isFlipped ? 360 : 0), axis: (x: 0, y: 1, z: 0))
                        .animation(.spring(duration: 0.4), value: isFlipped)
                        .padding(.horizontal, 2)
                        .onTapGesture { if isFlipped { flipped.remove(i) } else { flipped.insert(i) } }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 320)
                Text("\(index + 1) of \(cards.count) · tap to flip").font(.m(12, .semibold)).foregroundStyle(Theme.sub)
            }
        }
    }
}

/// Multiple choice: pick, see right/wrong + why, running score.
struct QuizView: View {
    let questions: [LectureReview.Question]
    @State private var picked: [Int: Int] = [:]

    private var score: Int { picked.filter { questions[$0.key].answer == $0.value }.count }

    var body: some View {
        if questions.isEmpty {
            Card { Text("No quiz in this review.").font(.m(14)).foregroundStyle(Theme.sub) }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(score) / \(picked.count) right").font(.m(14, .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    if !picked.isEmpty { Button("Reset") { picked = [:] }.font(.m(13, .bold)) }
                }
                ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in
                    Card {
                        Text("\(qi + 1). \(q.question ?? "")").font(.m(15, .bold)).foregroundStyle(Theme.text)
                        ForEach(Array((q.choices ?? []).enumerated()), id: \.offset) { ci, choice in
                            Button { if picked[qi] == nil { picked[qi] = ci } } label: {
                                HStack {
                                    Text(choice).font(.m(14)).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                                    Spacer()
                                    if let p = picked[qi] {
                                        if ci == q.answer { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
                                        else if ci == p { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red) }
                                    }
                                }
                                .padding(10)
                                .background(background(qi: qi, ci: ci, answer: q.answer), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        if picked[qi] != nil, let why = q.explanation, !why.isEmpty {
                            Text(why).font(.m(13)).foregroundStyle(Theme.sub)
                        }
                    }
                }
            }
        }
    }

    private func background(qi: Int, ci: Int, answer: Int?) -> Color {
        guard let p = picked[qi] else { return Theme.bg }
        if ci == answer { return Theme.green.opacity(0.18) }
        if ci == p { return Theme.red.opacity(0.18) }
        return Theme.bg
    }
}

/// The review as a printable PDF (notes, terms, flashcards, quiz + answer key).
enum ReviewPDF {
    @MainActor
    static func file(for lecture: Lecture, review: LectureReview) -> URL {
        let safe = lecture.displayTitle.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).pdf")
        try? pdf(html: html(lecture: lecture, review: review)).write(to: url)
        return url
    }

    private static func esc(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    @MainActor
    static func html(lecture: Lecture, review: LectureReview) -> String {
        var h = """
        <html><head><style>
        body { font-family: -apple-system, Helvetica; font-size: 11pt; color: #141413; }
        h1 { font-size: 20pt; margin: 0 0 2pt 0; } h2 { font-size: 13pt; color: #C96442; margin: 14pt 0 4pt 0; }
        .meta { color: #6B6A64; font-size: 9.5pt; } .flag { background: #FBEFE9; padding: 6pt; border-radius: 4pt; }
        li { margin-bottom: 3pt; } .term { font-weight: bold; } td { vertical-align: top; padding: 4pt; border-bottom: 1px solid #E4E1D7; }
        </style></head><body>
        <div class="meta">\(esc(lecture.displayCourse)) · \(lecture.recordedAt.formatted(date: .abbreviated, time: .shortened)) · \(Clock.string(lecture.durationSec))</div>
        <h1>\(esc(lecture.displayTitle))</h1>
        <p>\(esc(review.summary))</p>
        """
        if let flags = review.examFlags, !flags.isEmpty {
            h += "<h2>Likely on the exam</h2><div class=\"flag\"><ul>" + flags.map { "<li>\(esc($0.text))\($0.at.map { " <span class=\"meta\">(\(esc($0)))</span>" } ?? "")</li>" }.joined() + "</ul></div>"
        }
        for s in review.sections ?? [] {
            h += "<h2>\(esc(s.heading))</h2><ul>" + (s.points ?? []).map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        }
        if let terms = review.keyTerms, !terms.isEmpty {
            h += "<h2>Key terms</h2><table>" + terms.map { "<tr><td class=\"term\">\(esc($0.term))</td><td>\(esc($0.definition))</td></tr>" }.joined() + "</table>"
        }
        if let cards = review.flashcards, !cards.isEmpty {
            h += "<h2>Flashcards</h2><table>" + cards.map { "<tr><td class=\"term\">\(esc($0.front))</td><td>\(esc($0.back))</td></tr>" }.joined() + "</table>"
        }
        if let quiz = review.quiz, !quiz.isEmpty {
            h += "<h2>Practice quiz</h2><ol>"
            for q in quiz {
                h += "<li>\(esc(q.question))<ol type=\"A\">" + (q.choices ?? []).map { "<li>\(esc($0))</li>" }.joined() + "</ol></li>"
            }
            h += "</ol><h2>Answer key</h2><ol>"
            for q in quiz {
                let letter = q.answer.map { String(UnicodeScalar(65 + $0).map(Character.init) ?? "?") } ?? "?"
                h += "<li><b>\(letter)</b> - \(esc(q.explanation))</li>"
            }
            h += "</ol>"
        }
        if let f = review.followUps, !f.isEmpty {
            h += "<h2>Follow up</h2><ul>" + f.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        }
        return h + "</body></html>"
    }

    @MainActor
    static func pdf(html: String) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page.insetBy(dx: 42, dy: 48)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}
