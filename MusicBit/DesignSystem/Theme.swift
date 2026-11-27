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
        LinearGradient(
            colors: artworkColors(for: title),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Stable three-colour palette used when a track has no cover art.
    static func artworkColors(for title: String) -> [Color] {
        let palettes: [[Color]] = [
            [graphite, accent.opacity(0.85), Color(red: 0.05, green: 0.06, blue: 0.10)],
            [
                Color(red: 0.16, green: 0.17, blue: 0.22),
                Color(red: 0.35, green: 0.55, blue: 0.95),
                Color(red: 0.10, green: 0.13, blue: 0.28)
            ],
            [
                Color(red: 0.12, green: 0.20, blue: 0.24),
                Color(red: 0.30, green: 0.70, blue: 0.72),
                Color(red: 0.06, green: 0.16, blue: 0.20)
            ],
            [
                Color(red: 0.26, green: 0.12, blue: 0.20),
                Color(red: 0.85, green: 0.35, blue: 0.45),
                Color(red: 0.20, green: 0.06, blue: 0.12)
            ]
        ]
        let index = abs(title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palettes.count
        return palettes[index]
    }
}
