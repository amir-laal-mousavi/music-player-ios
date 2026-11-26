import Foundation
import MusicCore
import Observation

/// Persists the equalizer curve between launches.
@MainActor
@Observable
final class EqualizerStore {
    private enum Key {
        static let enabled = "equalizer.enabled"
        static let preset = "equalizer.preset"
        static let gains = "equalizer.gains"
    }

    private let defaults: UserDefaults

    var settings: EqualizerSettings {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Key.enabled)
        let preset = EqualizerPreset(rawValue: defaults.string(forKey: Key.preset) ?? "") ?? .flat
        let storedGains = (defaults.array(forKey: Key.gains) as? [Double])?.map(Float.init)
        self.settings = EqualizerSettings(
            isEnabled: enabled,
            preset: preset,
            gains: storedGains ?? preset.gains
        )
    }

    func apply(_ preset: EqualizerPreset) {
        settings = settings.setting(preset)
    }

    func setEnabled(_ enabled: Bool) {
        settings = settings.settingEnabled(enabled)
    }

    func setGain(_ gain: Float, at index: Int) {
        settings = settings.settingGain(gain, at: index)
    }

    func reset() {
        settings = EqualizerSettings(isEnabled: settings.isEnabled)
    }

    private func save() {
        defaults.set(settings.isEnabled, forKey: Key.enabled)
        defaults.set(settings.preset.rawValue, forKey: Key.preset)
        defaults.set(settings.gains.map(Double.init), forKey: Key.gains)
    }
}
