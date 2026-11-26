import Foundation

/// Preset tone curves for the equalizer, in dB per band.
public enum EqualizerPreset: String, Sendable, CaseIterable, Equatable {
    case flat
    case bassBoost
    case vocal
    case treble
    case rock
    case pop
    case electronic

    public var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .bassBoost: return "Bass Boost"
        case .vocal: return "Vocal"
        case .treble: return "Treble"
        case .rock: return "Rock"
        case .pop: return "Pop"
        case .electronic: return "Electronic"
        }
    }

    /// Seven bands: 60, 150, 400, 1k, 2.4k, 6k, 12k Hz.
    public var gains: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: return [9, 7, 4, 0, -1, -1, 0]
        case .vocal: return [-4, -2, 2, 6, 6, 3, -1]
        case .treble: return [-2, -2, -1, 0, 3, 7, 9]
        case .rock: return [6, 4, 2, -1, 2, 5, 6]
        case .pop: return [-2, 0, 3, 5, 3, 0, -2]
        case .electronic: return [7, 5, 0, -2, 2, 5, 8]
        }
    }
}

/// User-tunable equalizer configuration.
public struct EqualizerSettings: Sendable, Equatable {
    public static let bandFrequencies: [Float] = [60, 150, 400, 1_000, 2_400, 6_000, 12_000]
    public static let bandCount = bandFrequencies.count
    public static let gainRange: ClosedRange<Float> = -12...12

    public var isEnabled: Bool
    public var preset: EqualizerPreset
    /// Per-band gain in dB, in the same order as `bandFrequencies`.
    public var gains: [Float]

    public init(
        isEnabled: Bool = false,
        preset: EqualizerPreset = .flat,
        gains: [Float]? = nil
    ) {
        self.isEnabled = isEnabled
        self.preset = preset
        self.gains = Self.validated(gains ?? preset.gains)
    }

    public static var flat: EqualizerSettings { EqualizerSettings() }

    public func setting(_ preset: EqualizerPreset) -> EqualizerSettings {
        EqualizerSettings(isEnabled: isEnabled, preset: preset, gains: preset.gains)
    }

    public func settingGain(_ gain: Float, at index: Int) -> EqualizerSettings {
        guard gains.indices.contains(index) else { return self }
        var next = gains
        next[index] = Self.clamp(gain)
        return EqualizerSettings(isEnabled: isEnabled, preset: preset, gains: next)
    }

    public mutating func setGain(_ gain: Float, at index: Int) {
        guard gains.indices.contains(index) else { return }
        gains[index] = Self.clamp(gain)
    }

    public func settingEnabled(_ enabled: Bool) -> EqualizerSettings {
        EqualizerSettings(isEnabled: enabled, preset: preset, gains: gains)
    }

    private static func validated(_ gains: [Float]) -> [Float] {
        (0..<bandCount).map { index in
            index < gains.count ? clamp(gains[index]) : 0
        }
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, gainRange.lowerBound), gainRange.upperBound)
    }
}
