import SwiftUI

/// A Liquid Glass surface used only for navigation and playback chrome.
///
/// The material is replaced with an opaque surface when Reduce Transparency is on,
/// and the border thickens when Increase Contrast is on.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let prominent: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Theme.surface)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
            }
            .shadow(
                color: Color.black.opacity(prominent ? 0.16 : 0.08),
                radius: prominent ? 18 : 10,
                y: prominent ? 8 : 4
            )
    }
}

extension View {
    func glassSurface<S: InsettableShape>(in shape: S, prominent: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, prominent: prominent))
    }

    func glassCard(prominent: Bool = false) -> some View {
        glassSurface(
            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous),
            prominent: prominent
        )
    }

    /// Keeps bar backgrounds legible over music rows without glass on the rows themselves.
    func musicBarBackground() -> some View {
        toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }
}
