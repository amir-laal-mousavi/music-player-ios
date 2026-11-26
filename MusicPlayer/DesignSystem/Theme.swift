import SwiftUI

/// System monochrome, soft white, and Apple system blue.
enum Theme {
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let graphite = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let softWhite = Color(red: 0.98, green: 0.98, blue: 0.99)

    static let cornerRadius: CGFloat = 22
    static let compactCornerRadius: CGFloat = 16

    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let card = Color(.tertiarySystemBackground)

    static let heroGradient = LinearGradient(
        colors: [graphite, accent.opacity(0.75)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func artworkGradient(for title: String) -> LinearGradient {
        let palette: [(Color, Color)] = [
            (graphite, accent.opacity(0.8)),
            (Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.35, green: 0.55, blue: 0.95)),
            (Color(red: 0.12, green: 0.20, blue: 0.24), Color(red: 0.30, green: 0.70, blue: 0.72))
        ]
        let index = abs(title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        let pair = palette[index]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
