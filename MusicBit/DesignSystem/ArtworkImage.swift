import SwiftUI
import UIKit

/// Loads cover art from disk once per file and keeps it in memory for list scrolling.
@MainActor
final class ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 120
    }

    func image(for url: URL?) async -> UIImage? {
        guard let url, url.isFileURL else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
        let image = data.flatMap(UIImage.init(data:))
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    func insert(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

/// Cover art with the generated gradient as its fallback.
struct ArtworkImage: View {
    let url: URL?
    let title: String
    var size: CGFloat
    var cornerRadius: CGFloat?

    @State private var image: UIImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.28, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Theme.artworkGradient(for: title))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .clipShape(shape)
            .task(id: url) {
                image = await ArtworkImageCache.shared.image(for: url)
            }
            .accessibilityHidden(true)
    }
}

/// Colours sampled from cover art, used by the animated now-playing backdrop.
enum ArtworkPalette {
    static func colors(for image: UIImage?, fallbackTitle: String) -> [Color] {
        guard let image, let sampled = sample(image) else {
            return Theme.artworkColors(for: fallbackTitle)
        }
        return sampled
    }

    private static func sample(_ image: UIImage) -> [Color]? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var colors: [Color] = []
        for row in 0..<side {
            for column in 0..<side {
                let offset = (row * side + column) * 4
                let red = Double(pixels[offset]) / 255
                let green = Double(pixels[offset + 1]) / 255
                let blue = Double(pixels[offset + 2]) / 255
                let alpha = Double(pixels[offset + 3]) / 255
                guard alpha > 0.1 else { continue }
                colors.append(Color(red: red, green: green, blue: blue))
            }
        }
        guard !colors.isEmpty else { return nil }

        // Pick three well-separated samples so the gradient has some range.
        let picks = [0, colors.count / 2, colors.count - 1]
        return picks.map { colors[$0] }
    }
}
