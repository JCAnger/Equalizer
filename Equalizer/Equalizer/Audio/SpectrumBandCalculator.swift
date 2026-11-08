import Accelerate
import Foundation

/// Copie des réglages nécessaires pour transformer des échantillons en niveaux de bandes.
/// Type valeur et `Sendable` : il peut passer sans risque au thread audio.
nonisolated struct SpectrumConfig: Sendable, Equatable {
    var fftSize: Int
    var numberOfBands: Int
    var minFrequency: Double
    var maxFrequency: Double
    var minDecibels: Float
    var maxDecibels: Float
}

/// Transforme un bloc d'échantillons mono en niveaux (dB) répartis sur des bandes
/// à espacement logarithmique.
///
/// Partagé par l'analyseur du microphone (iPhone) et par le tap audio système (Mac),
/// afin que les deux côtés d'une comparaison soient calculés exactement de la même façon.
///
/// `configure(fftSize:)` ne doit pas être appelé pendant l'exécution de `bands(...)` sur un autre thread.
nonisolated final class SpectrumBandCalculator: @unchecked Sendable {
    private var fftSetup: FFTSetup?
    private var configuredFFTSize = 0
    private var window: [Float] = []

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    /// Prépare la FFT et la fenêtre de pondération pour une taille donnée.
    /// Ne fait rien si la taille est déjà configurée, car la création d'un `FFTSetup` est coûteuse.
    /// - Parameter fftSize: puissance de deux.
    func configure(fftSize: Int) {
        guard fftSize != configuredFFTSize else { return }
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
        configuredFFTSize = fftSize
        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        // Fenêtre de Hann : elle atténue les bords du bloc pour limiter les fuites spectrales.
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    /// Calcule les niveaux de bandes d'un bloc d'échantillons.
    /// - Returns: `nil` si moins de `config.fftSize` échantillons sont disponibles, ou si le
    ///   calculateur n'est pas configuré pour cette taille.
    func bands(samples input: UnsafePointer<Float>, count: Int, sampleRate: Float, config: SpectrumConfig) -> [Float]? {
        let size = config.fftSize
        guard count >= size, let fftSetup, window.count == size else { return nil }

        // Copie des `size` premiers échantillons, puis application de la fenêtre.
        var samples = [Float](repeating: 0, count: size)
        samples.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: input, count: size)
        }
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(size))

        var realp = [Float](repeating: 0, count: size / 2)
        var imagp = [Float](repeating: 0, count: size / 2)
        var magnitudes = [Float](repeating: 0, count: size / 2)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBufferPointer { samplesPtr in
                    // La FFT réelle d'Accelerate attend les données au format « complexe séparé » :
                    // `vDSP_ctoz` répartit les échantillons pairs et impairs en parties réelle et imaginaire.
                    samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Float(size))), FFTDirection(FFT_FORWARD))
                // Carré du module de chaque bin : c'est une puissance, pas une amplitude.
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }

        // Normalisation : `vDSP_fft_zrip` ne divise pas par la taille, donc on corrige par 1 / size²
        // pour que le niveau ne dépende pas de la taille de FFT choisie.
        var scale: Float = 1.0 / Float(size * size)
        var normalized = [Float](repeating: 0, count: size / 2)
        vDSP_vsmul(magnitudes, 1, &scale, &normalized, 1, vDSP_Length(size / 2))

        // Conversion en décibels par rapport à une référence de 1. Le dernier argument (1)
        // indique qu'il s'agit de puissances (10 · log10) et non d'amplitudes (20 · log10).
        var referenceLevel: Float = 1.0
        var decibels = [Float](repeating: 0, count: size / 2)
        vDSP_vdbcon(normalized, 1, &referenceLevel, &decibels, 1, vDSP_Length(size / 2), 1)

        return mapToBands(decibels: decibels, sampleRate: sampleRate, config: config)
    }

    /// Regroupe les bins de la FFT (espacés linéairement) en bandes espacées de façon
    /// logarithmique, en gardant le pic de chaque bande.
    private func mapToBands(decibels: [Float], sampleRate: Float, config: SpectrumConfig) -> [Float] {
        let bandCount = max(config.numberOfBands, 1)
        // Fréquence de Nyquist : au-delà de la moitié de la fréquence d'échantillonnage, le spectre est invalide.
        let nyquist = sampleRate / 2
        // Le logarithme n'est pas défini en 0 Hz, d'où le minimum à 1 Hz.
        let minFreq = Float(max(config.minFrequency, 1))
        let maxFreq = Float(min(config.maxFrequency, Double(nyquist)))
        let minDB = config.minDecibels
        let maxDB = config.maxDecibels
        guard maxFreq > minFreq else { return [Float](repeating: minDB, count: bandCount) }

        // Largeur de fréquence d'un bin de la FFT.
        let binHz = sampleRate / Float(config.fftSize)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)

        var bands = [Float](repeating: minDB, count: bandCount)
        for i in 0..<bandCount {
            // Bornes de la bande, régulièrement réparties sur l'échelle logarithmique.
            let lowFrac = Float(i) / Float(bandCount)
            let highFrac = Float(i + 1) / Float(bandCount)
            let lowFreq = pow(10, logMin + (logMax - logMin) * lowFrac)
            let highFreq = pow(10, logMin + (logMax - logMin) * highFrac)

            let lowBin = max(0, min(Int(lowFreq / binHz), decibels.count - 1))
            let highBin = max(lowBin, min(Int(highFreq / binHz), decibels.count - 1))

            // On garde le pic plutôt que la moyenne pour ne pas masquer une résonance étroite.
            var peak: Float = -.infinity
            for bin in lowBin...highBin {
                peak = max(peak, decibels[bin])
            }
            bands[i] = peak.isFinite ? min(max(peak, minDB), maxDB) : minDB
        }
        return bands
    }
}
