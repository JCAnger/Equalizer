import AVFoundation
import Accelerate
import Observation

/// Captures audio from the microphone and produces a log-frequency spectrum,
/// mapped into bands according to the modifiable `SpectrumSettings`.
@Observable
final class AudioSpectrumAnalyzer {
    private(set) var bandLevels: [Float] = []
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    /// Long-term average of the band levels (dB) collected while `isMeasuring` is true.
    private(set) var averageBandLevels: [Float] = []
    private(set) var isMeasuring = false
    /// Number of analysis frames included in `averageBandLevels`.
    private(set) var measuredFrameCount = 0

    /// Frames whose loudest band is below this level (dB) are treated as silence
    /// and left out of the average.
    private let silenceThreshold: Float = -80

    private var powerSums: [Double] = []

    // Read from the audio tap thread; see the note on `SpectrumSettings` about benign races.
    nonisolated(unsafe) private let settings: SpectrumSettings
    private let engine = AVAudioEngine()

    // Configured on the main actor only while the tap is not installed (before start /
    // after stop), and used from the real-time audio tap thread while running.
    private let calculator = SpectrumBandCalculator()

    init(settings: SpectrumSettings) {
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil

        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                await MainActor.run {
                    self.errorMessage = "L'accès au microphone a été refusé. Autorisez-le dans Réglages."
                }
                return
            }
            #if os(iOS)
            do {
                // Activating the audio session can block, so keep it off the main thread.
                try await Task.detached { try Self.activateSession() }.value
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
                return
            }
            #endif
            await MainActor.run {
                self.startEngine()
            }
        }
    }

    #if os(iOS)
    nonisolated private static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
    }
    #endif

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        isMeasuring = false
    }

    /// Starts a new measurement: averages the music captured from now on.
    func startMeasurement() {
        resetMeasurement()
        isMeasuring = true
    }

    func stopMeasurement() {
        isMeasuring = false
    }

    func resetMeasurement() {
        powerSums = []
        averageBandLevels = []
        measuredFrameCount = 0
    }

    /// Accumulates the band levels in the power domain so loud passages weigh correctly.
    @MainActor
    private func accumulate(_ newBands: [Float]) {
        guard isMeasuring, let loudest = newBands.max(), loudest > silenceThreshold else { return }
        if powerSums.count != newBands.count {
            powerSums = [Double](repeating: 0, count: newBands.count)
            measuredFrameCount = 0
        }
        for i in newBands.indices {
            powerSums[i] += pow(10, Double(newBands[i]) / 10)
        }
        measuredFrameCount += 1
        let frames = Double(measuredFrameCount)
        averageBandLevels = powerSums.map { Float(10 * log10($0 / frames)) }
    }

    private func startEngine() {
        #if os(iOS)
        // The session is configured and activated in `start()`, off the main thread.
        let session = AVAudioSession.sharedInstance()
        guard !session.currentRoute.inputs.isEmpty, session.isInputAvailable else {
            errorMessage = "Aucun périphérique d'entrée audio disponible."
            return
        }
        #endif

        // AVAudioEngine.prepare()/.start() throw an uncaught NSException (not a
        // Swift error) if no input or output device is available, so every check
        // above and below must happen first to avoid crashing the process.
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "Aucun périphérique d'entrée audio disponible."
            return
        }

        engine.prepare()

        calculator.configure(fftSize: settings.fftSize)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: UInt32(settings.fftSize), format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer, sampleRate: Float(format.sampleRate))
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Runs on the audio engine's internal tap thread.
    nonisolated private func process(buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let channelData = buffer.floatChannelData else { return }

        let config = settings.analysisConfig
        guard let bands = calculator.bands(
            samples: channelData[0],
            count: Int(buffer.frameLength),
            sampleRate: sampleRate,
            config: config
        ) else { return }

        Task { @MainActor [weak self] in
            self?.updateBandLevels(bands)
        }
    }

    @MainActor
    private func updateBandLevels(_ newBands: [Float]) {
        accumulate(newBands)
        guard bandLevels.count == newBands.count else {
            bandLevels = newBands
            return
        }
        let attack = settings.attack
        let release = settings.release
        for i in newBands.indices {
            let coeff = newBands[i] > bandLevels[i] ? attack : release
            bandLevels[i] += (newBands[i] - bandLevels[i]) * coeff
        }
    }
}
