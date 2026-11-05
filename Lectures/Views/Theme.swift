import SwiftUI
import UIKit

/// LifeOS's Claude theme: warm gray surfaces, Claude-orange accent, Manrope.
enum Theme {
    static let accent = Color(rgb: 0xC96442)
    static let bg = Color(light: 0xF5F3EC, dark: 0x262624)
    static let card = Color(light: 0xFFFFFF, dark: 0x30302E)
    static let text = Color(light: 0x141413, dark: 0xF0EFE9)
    static let sub = Color(light: 0x6B6A64, dark: 0xA6A49B)
    static let line = Color(light: 0xE4E1D7, dark: 0x3D3D3A)
    static let red = Color(rgb: 0xD9534F)
    static let green = Color(rgb: 0x5A9E6F)
}

extension Font {
    /// Manrope at a fixed size; weight picks the bundled face.
    static func m(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let face: String
        switch weight {
        case .heavy, .black: face = "Manrope-ExtraBold"
        case .bold: face = "Manrope-Bold"
        case .semibold: face = "Manrope-SemiBold"
        default: face = "Manrope-Medium"
        }
        return .custom(face, size: size, relativeTo: .body)
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The rounded card every section sits on.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct Chip: View {
    var label: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.m(13, .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Theme.text)
                .background(selected ? Theme.accent : Theme.card, in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
