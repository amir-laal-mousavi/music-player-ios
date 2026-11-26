import MusicCore
import SwiftUI

/// Seven-band equalizer with presets, applied to the running player.
struct EqualizerView: View {
    @Bindable var store: EqualizerStore
    let onChange: (EqualizerSettings) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Equalizer", isOn: enabledBinding)
                        .accessibilityIdentifier("eq.enabled")

                    Picker("Preset", selection: presetBinding) {
                        ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .disabled(!store.settings.isEnabled)
                    .accessibilityIdentifier("eq.preset")
                } footer: {
                    Text("Bass, mids and treble are shaped on the device, so downloads stay untouched.")
                }

                Section("Bands") {
                    ForEach(0..<EqualizerSettings.bandCount, id: \.self) { index in
                        bandRow(index)
                    }
                }
                .disabled(!store.settings.isEnabled)

                Section {
                    Button("Reset to flat") {
                        store.reset()
                        onChange(store.settings)
                    }
                    .disabled(!store.settings.isEnabled)
                }
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("eq.done")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func bandRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(frequencyLabel(index))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.0f dB", store.settings.gains[index]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: gainBinding(index), in: EqualizerSettings.gainRange, step: 1)
                .accessibilityLabel("\(frequencyLabel(index)) gain")
                .accessibilityIdentifier("eq.band.\(index)")
        }
    }

    private func frequencyLabel(_ index: Int) -> String {
        let hertz = EqualizerSettings.bandFrequencies[index]
        if hertz >= 1_000 {
            return String(format: "%.1f kHz", hertz / 1_000)
        }
        return String(format: "%.0f Hz", hertz)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.isEnabled },
            set: { enabled in
                store.setEnabled(enabled)
                onChange(store.settings)
            }
        )
    }

    private var presetBinding: Binding<EqualizerPreset> {
        Binding(
            get: { store.settings.preset },
            set: { preset in
                store.apply(preset)
                onChange(store.settings)
            }
        )
    }

    private func gainBinding(_ index: Int) -> Binding<Float> {
        Binding(
            get: { store.settings.gains[index] },
            set: { gain in
                store.setGain(gain, at: index)
                onChange(store.settings)
            }
        )
    }
}
