import AVFoundation
import Foundation

/// Plays an audio file (looping) and turns exactly what is sent to the speakers into
/// band levels, using the same calculator as the microphone analysis.
///
/// The levels are taken from the main mixer output, so volume changes made on the
/// device itself don't matter: only the shape of the spectrum is compared.
///
/// Audio callbacks arrive on audio threads, so this type is deliberately not
/// main-actor isolated.
nonisolated final class ReferencePlayer: @unchecked Sendable {
    enum PlayerError: LocalizedError {
        case noFile

        var errorDescription: String? {
            "Aucun morceau choisi."
        }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var noiseNode: AVAudioSourceNode?
    private let calculator = SpectrumBandCalculator()
    private let lock = NSLock()

    private var file: AVAudioFile?
    private var noiseColor: NoiseColor?
    private var isGraphReady = false
    private var isScheduled = false
    private var wantsPlayback = false
    /// True between `play()` and `pause()`/`stop()`; guarded by `lock`.
    private var isActive = false

    // Used from the audio tap thread only while the engine runs.
    private var config = SpectrumConfig(
        fftSize: 4096, numberOfBands: 32, minFrequency: 30, maxFrequency: 20_000,
        minDecibels: -190, maxDecibels: 0
    )
    private var pending: [Float] = []

    /// Called on an audio thread with each new block of band levels.
    var onFrame: (@Sendable (ReferenceFrame) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        // The engine stops by itself when the output route changes (AirPlay, Bluetooth,
        // headphones) or after an interruption; restart it so playback doesn't go silent.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartIfNeeded()
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if rawType == AVAudioSession.InterruptionType.ended.rawValue {
                self?.restartIfNeeded()
            }
        })
        #endif
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        stop()
    }

    /// Name of the current output (e.g. "Haut-parleur"), to show where the sound goes.
    var outputName: String? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first?.portName ?? "aucune"
        let volume = Int((session.outputVolume * 100).rounded())
        let rate = Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)
        let channels = engine.outputNode.outputFormat(forBus: 0).channelCount
        return "\(port) · volume média \(volume) % · \(rate) Hz · \(channels) can."
        #else
        nil
        #endif
    }

    private func restartIfNeeded() {
        lock.lock()
        let shouldRun = isActive
        lock.unlock()
        guard shouldRun, isGraphReady, !engine.isRunning else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard (try? engine.start()) != nil else { return }
        if noiseColor == nil { node.play() }
    }

    func load(_ url: URL, config: SpectrumConfig) throws {
        stop()
        file = try AVAudioFile(forReading: url)
        noiseColor = nil
        self.config = config
        isGraphReady = false
    }

    /// Uses a generated pink noise (equal energy per octave) instead of a file.
    func loadNoise(_ color: NoiseColor, config: SpectrumConfig) {
        stop()
        file = nil
        noiseColor = color
        self.config = config
        isGraphReady = false
    }

    func play() throws {
        guard noiseColor != nil || file != nil else { throw PlayerError.noFile }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        #endif

        if !isGraphReady {
            try buildGraph()
        }
        if !engine.isRunning {
            try engine.start()
        }

        lock.lock()
        isActive = true
        lock.unlock()

        guard noiseColor == nil else { return }
        setWantsPlayback(true)
        if !isScheduled {
            isScheduled = true
            scheduleFile()
        }
        node.play()
    }

    func pause() {
        lock.lock()
        isActive = false
        lock.unlock()
        if noiseColor != nil {
            engine.pause()
        } else {
            node.pause()
        }
    }

    func stop() {
        lock.lock()
        isActive = false
        lock.unlock()
        setWantsPlayback(false)
        if node.engine != nil {
            node.stop()
        }
        engine.stop()
        isScheduled = false
        pending.removeAll()
    }

    // MARK: - Private

    private func buildGraph() throws {
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        if node.engine != nil {
            engine.detach(node)
        }
        if let noiseNode {
            engine.detach(noiseNode)
            self.noiseNode = nil
        }
        if let color = noiseColor {
            let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw PlayerError.noFile
            }
            let generator = NoiseGenerator(color: color)
            let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0..<Int(frameCount) {
                        data[frame] = generator.next()
                    }
                }
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            noiseNode = source
        } else if let file {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        }

        calculator.configure(fftSize: config.fftSize)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(config.fftSize), format: format) { [weak self] buffer, _ in
            self?.process(buffer, sampleRate: Float(format.sampleRate))
        }
        engine.prepare()
        isGraphReady = true
    }

    /// Plays the file and, when it ends, starts it again until playback is stopped.
    private func scheduleFile() {
        guard let file else { return }
        file.framePosition = 0
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self, self.currentWantsPlayback() else { return }
            self.scheduleFile()
        }
    }

    private func setWantsPlayback(_ value: Bool) {
        lock.lock()
        wantsPlayback = value
        lock.unlock()
    }

    private func currentWantsPlayback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantsPlayback
    }

    // Runs on the audio engine's tap thread.
    private func process(_ buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        // Mix down to mono.
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += channelData[channel][frame]
            }
            pending.append(sum / Float(channels))
        }

        while pending.count >= config.fftSize {
            let bands = pending.withUnsafeBufferPointer { pointer in
                calculator.bands(samples: pointer.baseAddress!, count: config.fftSize, sampleRate: sampleRate, config: config)
            }
            pending.removeFirst(config.fftSize)
            if let bands {
                onFrame?(ReferenceFrame(bands: bands, minFrequency: config.minFrequency, maxFrequency: config.maxFrequency))
            }
        }
    }
}

/// Generated test signals: pink noise has equal energy per octave, white noise per hertz.
nonisolated enum NoiseColor {
    case pink
    case white
}

/// White noise, optionally filtered to pink (-3 dB/octave) with Paul Kellet's filter.
/// Used from a single audio render thread.
private nonisolated final class NoiseGenerator {
    private let color: NoiseColor
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0

    init(color: NoiseColor) {
        self.color = color
    }

    func next() -> Float {
        let white = Float.random(in: -1...1)
        if color == .white { return white * 0.3 }
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        return (b0 + b1 + b2 + white * 0.1848) * 0.25
    }
}
