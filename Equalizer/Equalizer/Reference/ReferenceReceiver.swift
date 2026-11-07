import Foundation
import Observation

/// Main-actor side of the reference link: keeps the connection state and, while a
/// measurement is running, the long-term average of what the source sends to the speakers.
@Observable
final class ReferenceReceiver {
    private(set) var sourceName: String?
    private(set) var isMeasuring = false
    /// Long-term average (dB) of the reference, on the same band layout as the settings.
    private(set) var averageLevels: [Float] = []
    private(set) var frameCount = 0
    /// Smoothed live levels (dB) of what the source is playing right now, on the same band
    /// layout as the settings. Empty when no source is connected.
    private(set) var liveLevels: [Float] = []

    var isConnected: Bool { sourceName != nil }

    private let settings: SpectrumSettings
    private let client = ReferenceClient()
    private var powerSums: [Double] = []

    /// Frames whose loudest band is below this level (dB) are treated as silence.
    private let silenceThreshold: Float = -80

    init(settings: SpectrumSettings) {
        self.settings = settings
        client.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.receive(frame)
            }
        }
        client.onConnectionChange = { [weak self] name in
            Task { @MainActor [weak self] in
                self?.sourceName = name
                if name == nil {
                    self?.liveLevels = []
                }
            }
        }
    }

    func startBrowsing() {
        client.start()
    }

    func stopBrowsing() {
        client.stop()
        isMeasuring = false
    }

    func startMeasurement() {
        resetMeasurement()
        isMeasuring = true
    }

    func stopMeasurement() {
        isMeasuring = false
    }

    func resetMeasurement() {
        powerSums = []
        averageLevels = []
        frameCount = 0
    }

    private func receive(_ frame: ReferenceFrame) {
        let bands = frame.resampled(
            bandCount: settings.numberOfBands,
            minFrequency: settings.minFrequency,
            maxFrequency: settings.maxFrequency
        )
        updateLiveLevels(bands)

        guard isMeasuring, let loudest = frame.bands.max(), loudest > silenceThreshold else { return }

        if powerSums.count != bands.count {
            powerSums = [Double](repeating: 0, count: bands.count)
            frameCount = 0
        }
        for i in bands.indices {
            powerSums[i] += pow(10, Double(bands[i]) / 10)
        }
        frameCount += 1
        let frames = Double(frameCount)
        averageLevels = powerSums.map { Float(10 * log10($0 / frames)) }
    }

    /// Same attack/release smoothing as the microphone curve, so both move alike.
    private func updateLiveLevels(_ bands: [Float]) {
        guard liveLevels.count == bands.count else {
            liveLevels = bands
            return
        }
        for i in bands.indices {
            let coefficient = bands[i] > liveLevels[i] ? settings.attack : settings.release
            liveLevels[i] += (bands[i] - liveLevels[i]) * coefficient
        }
    }
}
