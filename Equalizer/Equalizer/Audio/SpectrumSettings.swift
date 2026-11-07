import Foundation
import Observation

/// Modifiable parameters that control how the spectrum curve is computed and displayed.
// Properties are read from the real-time audio tap thread as well as written from the
// main actor by UI controls. Reads/writes of these scalar values are benignly racy
// (worst case: one stale frame of analysis), which is standard practice for live audio
// parameters and avoids locking the audio thread.
@Observable
nonisolated final class SpectrumSettings {
    /// How the band levels are rendered in `SpectrumView`.
    enum DisplayStyle: String, CaseIterable, Identifiable {
        case bars
        case curve

        var id: Self { self }

        var label: String {
            switch self {
            case .bars: return "Barres"
            case .curve: return "Courbe"
            }
        }
    }

    /// Lower bound of the analyzed frequency range, in hertz.
    var minFrequency: Double = 30
    /// Upper bound of the analyzed frequency range, in hertz.
    var maxFrequency: Double = 20_000

    /// Visual style used to render the band levels.
    var displayStyle: DisplayStyle = .bars

    /// Number of bars drawn across the frequency range (log-spaced).
    var numberOfBands: Int = 32

    /// Levels at or below this value are drawn at the bottom of the meter.
    var minDecibels: Float = -190
    /// Levels at or above this value are drawn at the top of the meter.
    var maxDecibels: Float = 0

    /// How quickly a bar rises when the level increases (0 = frozen, 1 = instantaneous).
    var attack: Float = 0.6
    /// How quickly a bar falls when the level decreases (0 = frozen, 1 = instantaneous).
    var release: Float = 0.15

    /// FFT window size. Must be a power of two; larger values give finer frequency resolution
    /// but slower time response.
    var fftSize: Int = 4096

    static let availableFFTSizes = [1024, 2048, 4096, 8192, 16384]

    /// Plain-value snapshot used by the (non main actor) audio analysis code.
    var analysisConfig: SpectrumConfig {
        SpectrumConfig(
            fftSize: fftSize,
            numberOfBands: numberOfBands,
            minFrequency: minFrequency,
            maxFrequency: maxFrequency,
            minDecibels: minDecibels,
            maxDecibels: maxDecibels
        )
    }

    func reset() {
        minFrequency = 30
        maxFrequency = 20_000
        displayStyle = .bars
        numberOfBands = 32
        minDecibels = -160
        maxDecibels = 0
        attack = 0.6
        release = 0.15
        fftSize = 4096
    }
}
