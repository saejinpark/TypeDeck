import AppKit
import SwiftUI

/// Same tokens as the web app's CSS variables.
enum Palette {
    static let background = dynamic(light: 0xF3F1EC, dark: 0x131211)
    static let panel = dynamic(light: 0xFAF9F6, dark: 0x1A1917)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x22201E)
    static let ink = dynamic(light: 0x1C1A17, dark: 0xF1EEE8)
    static let muted = dynamic(light: 0x858077, dark: 0x918B81)
    static let ghost = dynamic(light: 0xC9C4BA, dark: 0x4D4943)
    static let line = dynamic(light: 0xE4E0D7, dark: 0x2F2C29)
    static let accent = dynamic(light: 0xFF5B1F, dark: 0xFF7A45)
    static let bad = dynamic(light: 0xE5484D, dark: 0xFF6B6F)
    static let good = dynamic(light: 0x2F9E5B, dark: 0x4CC27C)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// A key cap label like the web app's <kbd>.
struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line))
    }
}

struct Pill: View {
    let text: String
    var highlighted = false
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(highlighted ? Palette.accent : Palette.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(highlighted ? Palette.accent.opacity(0.13) : Palette.panel))
            .overlay(Capsule().strokeBorder(highlighted ? Palette.accent : Palette.line))
    }
}

/// Wraps children onto new lines, for the missed-card chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
