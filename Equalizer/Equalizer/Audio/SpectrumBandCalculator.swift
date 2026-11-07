import Accelerate
import Foundation

/// Snapshot of the settings needed to turn samples into band levels.
nonisolated struct SpectrumConfig: Sendable, Equatable {
    var fftSize: Int
    var numberOfBands: Int
    var minFrequency: Double
    var maxFrequency: Double
    var minDecibels: Float
    var maxDecibels: Float
}

/// Turns a block of mono samples into log-spaced band levels in dB.
///
/// Shared by the microphone analyzer (iPhone) and the system audio tap (Mac) so both
/// sides of a comparison are computed exactly the same way.
///
/// `configure(fftSize:)` must not be called while `bands(...)` runs on another thread.
nonisolated final class SpectrumBandCalculator: @unchecked Sendable {
    private var fftSetup: FFTSetup?
    private var configuredFFTSize = 0
    private var window: [Float] = []

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func configure(fftSize: Int) {
        guard fftSize != configuredFFTSize else { return }
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
        configuredFFTSize = fftSize
        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    /// Returns `nil` when fewer than `config.fftSize` samples are available or the
    /// calculator is not configured for that size.
    func bands(samples input: UnsafePointer<Float>, count: Int, sampleRate: Float, config: SpectrumConfig) -> [Float]? {
        let size = config.fftSize
        guard count >= size, let fftSetup, window.count == size else { return nil }

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
                    samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Float(size))), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }

        var scale: Float = 1.0 / Float(size * size)
        var normalized = [Float](repeating: 0, count: size / 2)
        vDSP_vsmul(magnitudes, 1, &scale, &normalized, 1, vDSP_Length(size / 2))

        var referenceLevel: Float = 1.0
        var decibels = [Float](repeating: 0, count: size / 2)
        vDSP_vdbcon(normalized, 1, &referenceLevel, &decibels, 1, vDSP_Length(size / 2), 1)

        return mapToBands(decibels: decibels, sampleRate: sampleRate, config: config)
    }

    private func mapToBands(decibels: [Float], sampleRate: Float, config: SpectrumConfig) -> [Float] {
        let bandCount = max(config.numberOfBands, 1)
        let nyquist = sampleRate / 2
        let minFreq = Float(max(config.minFrequency, 1))
        let maxFreq = Float(min(config.maxFrequency, Double(nyquist)))
        let minDB = config.minDecibels
        let maxDB = config.maxDecibels
        guard maxFreq > minFreq else { return [Float](repeating: minDB, count: bandCount) }

        let binHz = sampleRate / Float(config.fftSize)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)

        var bands = [Float](repeating: minDB, count: bandCount)
        for i in 0..<bandCount {
            let lowFrac = Float(i) / Float(bandCount)
            let highFrac = Float(i + 1) / Float(bandCount)
            let lowFreq = pow(10, logMin + (logMax - logMin) * lowFrac)
            let highFreq = pow(10, logMin + (logMax - logMin) * highFrac)

            let lowBin = max(0, min(Int(lowFreq / binHz), decibels.count - 1))
            let highBin = max(lowBin, min(Int(highFreq / binHz), decibels.count - 1))

            var peak: Float = -.infinity
            for bin in lowBin...highBin {
                peak = max(peak, decibels[bin])
            }
            bands[i] = peak.isFinite ? min(max(peak, minDB), maxDB) : minDB
        }
        return bands
    }
}
