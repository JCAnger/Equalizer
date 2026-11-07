import SwiftUI

/// Lets the user tweak every parameter that shapes the spectrum curve.
struct SettingsView: View {
    @Bindable var settings: SpectrumSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Apparence") {
                    Picker("Style d'affichage", selection: $settings.displayStyle) {
                        ForEach(SpectrumSettings.DisplayStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Plage de fréquences") {
                    LabeledContent("Min : \(Int(settings.minFrequency)) Hz") {
                        Slider(value: logBinding(\.minFrequency), in: 0...1)
                    }
                    LabeledContent("Max : \(Int(settings.maxFrequency)) Hz") {
                        Slider(value: logBinding(\.maxFrequency), in: 0...1)
                    }
                }

                Section("Résolution") {
                    Stepper("Nombre de bandes : \(settings.numberOfBands)",
                            value: $settings.numberOfBands, in: 8...128, step: 8)

                    Picker("Taille FFT", selection: $settings.fftSize) {
                        ForEach(SpectrumSettings.availableFFTSizes, id: \.self) { size in
                            Text("\(size)").tag(size)
                        }
                    }
                }

                Section("Niveaux (dB)") {
                    LabeledContent("Min : \(Int(settings.minDecibels)) dB") {
                        Slider(value: $settings.minDecibels, in: -120...(-20))
                    }
                    LabeledContent("Max : \(Int(settings.maxDecibels)) dB") {
                        Slider(value: $settings.maxDecibels, in: -40...12)
                    }
                }

                Section("Réactivité") {
                    LabeledContent("Attaque : \(String(format: "%.2f", settings.attack))") {
                        Slider(value: $settings.attack, in: 0.05...1)
                    }
                    LabeledContent("Relâchement : \(String(format: "%.2f", settings.release))") {
                        Slider(value: $settings.release, in: 0.02...1)
                    }
                }

                Section {
                    Button("Réinitialiser les réglages par défaut", role: .destructive) {
                        settings.reset()
                    }
                }
            }
            .navigationTitle("Paramètres de la courbe")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    /// Maps a 30–20000 Hz frequency to/from a 0...1 slider using a logarithmic scale,
    /// so the whole audible range is comfortably reachable with one slider.
    private func logBinding(_ keyPath: ReferenceWritableKeyPath<SpectrumSettings, Double>) -> Binding<Double> {
        let logLow = log10(20.0)
        let logHigh = log10(20_000.0)
        return Binding(
            get: {
                let value = settings[keyPath: keyPath]
                let clamped = min(max(value, 20), 20_000)
                return (log10(clamped) - logLow) / (logHigh - logLow)
            },
            set: { fraction in
                let value = pow(10, logLow + fraction * (logHigh - logLow))
                settings[keyPath: keyPath] = value
            }
        )
    }
}

#Preview {
    SettingsView(settings: SpectrumSettings())
}
