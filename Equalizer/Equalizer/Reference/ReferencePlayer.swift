import AVFoundation
import Foundation

/// Lit un fichier audio (en boucle) et convertit exactement ce qui est envoyé aux enceintes
/// en niveaux de bandes, avec le même calculateur que l'analyse du microphone.
///
/// Les niveaux sont pris à la sortie du mélangeur principal : les changements de volume faits
/// sur l'appareil lui-même n'ont donc pas d'importance, seule la forme du spectre est comparée.
///
/// Les rappels audio arrivent sur des threads audio : ce type n'est donc volontairement
/// pas isolé au main actor.
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
    /// Protège `isActive` et `wantsPlayback`, lus depuis des threads audio.
    private let lock = NSLock()

    private var file: AVAudioFile?
    /// Signal généré joué à la place d'un fichier (bruit, balayage…), `nil` pour un fichier.
    private var signal: GeneratedSignal?
    /// Faux tant que le graphe audio n'a pas été (re)construit après un chargement.
    private var isGraphReady = false
    private var isScheduled = false
    private var wantsPlayback = false
    /// Vrai entre `play()` et `pause()`/`stop()` ; protégé par `lock`.
    private var isActive = false

    // Utilisé depuis le thread du tap audio, uniquement pendant que le moteur tourne.
    private var config = SpectrumConfig(
        fftSize: 4096, numberOfBands: 32, minFrequency: 30, maxFrequency: 20_000,
        minDecibels: -190, maxDecibels: 0
    )
    /// Échantillons mono en attente : un buffer de tap n'a pas forcément la taille de la FFT.
    private var pending: [Float] = []

    /// Appelé sur un thread audio à chaque nouveau bloc de niveaux de bandes.
    var onFrame: (@Sendable (ReferenceFrame) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        // Le moteur s'arrête de lui-même quand la sortie change (AirPlay, Bluetooth, casque)
        // ou après une interruption ; on le relance pour que la lecture ne devienne pas muette.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartIfNeeded()
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            // On ne relance qu'à la fin de l'interruption (appel, alarme…), pas à son début.
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

    /// Description de la sortie actuelle (ex. « Haut-parleur · volume média 50 % … »),
    /// affichée pour aider à comprendre où part le son. `nil` sur Mac.
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

    /// Relance le moteur arrêté par le système, si l'utilisateur voulait toujours écouter.
    private func restartIfNeeded() {
        lock.lock()
        let shouldRun = isActive
        lock.unlock()
        guard shouldRun, isGraphReady, !engine.isRunning else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard (try? engine.start()) != nil else { return }
        // Le signal généré est joué par son propre nœud source : seul le lecteur de fichier a besoin de `play()`.
        if signal == nil { node.play() }
    }

    /// Charge un fichier audio. Le graphe est reconstruit au prochain `play()`.
    /// - Throws: l'erreur d'`AVAudioFile` si le fichier est illisible.
    func load(_ url: URL, config: SpectrumConfig) throws {
        stop()
        file = try AVAudioFile(forReading: url)
        signal = nil
        self.config = config
        isGraphReady = false
    }

    /// Utilise un signal de test généré (bruit, balayage, bruit par bande) à la place d'un fichier.
    func loadSignal(_ signal: GeneratedSignal, config: SpectrumConfig) {
        stop()
        file = nil
        self.signal = signal
        self.config = config
        isGraphReady = false
    }

    /// Démarre (ou reprend) la lecture.
    /// - Throws: `PlayerError.noFile` si rien n'est chargé, ou l'erreur de la session / du moteur.
    func play() throws {
        guard signal != nil || file != nil else { throw PlayerError.noFile }

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

        // Le signal est produit en continu par le moteur : pas de fichier à planifier.
        guard signal == nil else { return }
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
        if signal != nil {
            // Le générateur de signal n'a pas de nœud lecteur à mettre en pause : on suspend tout le moteur.
            engine.pause()
        } else {
            node.pause()
        }
    }

    func stop() {
        lock.lock()
        isActive = false
        lock.unlock()
        // Empêche la fin du fichier en cours de relancer une boucle après l'arrêt.
        setWantsPlayback(false)
        if node.engine != nil {
            node.stop()
        }
        engine.stop()
        isScheduled = false
        pending.removeAll()
    }

    // MARK: - Privé

    /// Reconstruit le graphe audio (source -> mélangeur principal) et installe le tap d'analyse.
    private func buildGraph() throws {
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        // On détache les anciens nœuds : le type de source a pu changer (fichier <-> bruit).
        if node.engine != nil {
            engine.detach(node)
        }
        if let noiseNode {
            engine.detach(noiseNode)
            self.noiseNode = nil
        }
        if let signal {
            let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw PlayerError.noFile
            }
            let generator = SignalGenerator(signal: signal, sampleRate: Float(sampleRate))
            // Ce bloc est appelé sur le thread de rendu : il ne doit ni allouer ni bloquer.
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

    /// Joue le fichier et, à sa fin, le relance tant que la lecture n'est pas arrêtée.
    private func scheduleFile() {
        guard let file else { return }
        file.framePosition = 0
        // `.dataPlayedBack` : le rappel n'a lieu qu'une fois le son réellement joué, pas seulement lu.
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

    /// Mixe en mono et calcule une image par `fftSize` échantillons. S'exécute sur le thread du tap audio.
    private func process(_ buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        // Mixage en mono : moyenne des canaux.
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += channelData[channel][frame]
            }
            pending.append(sum / Float(channels))
        }

        // Mêmes blocs sans recouvrement que les autres sources, pour des mesures comparables.
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

/// Couleurs de bruit : le bruit rose a une énergie égale par octave, le bruit blanc par hertz.
nonisolated enum NoiseColor: Equatable, Sendable {
    case pink
    case white
}

/// Signaux de test que le lecteur sait produire lui-même.
nonisolated enum GeneratedSignal: Equatable, Sendable {
    case noise(NoiseColor)
    /// Sinus dont la fréquence monte de façon logarithmique de `startFrequency` à
    /// `endFrequency` en `duration` secondes, puis recommence.
    case sweep(startFrequency: Double, endFrequency: Double, duration: Double)
    /// Bruit rose limité à la plage `lowFrequency`–`highFrequency`, pour tester une seule zone.
    case bandNoise(lowFrequency: Double, highFrequency: Double)
}

/// Produit les échantillons d'un `GeneratedSignal`.
/// Utilisé depuis un seul thread de rendu audio, d'où l'absence de verrou sur son état.
private nonisolated final class SignalGenerator {
    /// Niveau de sortie commun : laisse de la marge avant saturation, à un volume d'écoute raisonnable.
    private static let outputLevel: Float = 0.3

    private let signal: GeneratedSignal
    private let sampleRate: Float

    // État du filtre rose (trois filtres passe-bas du premier ordre en parallèle).
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0

    // État du balayage.
    private var phase: Float = 0
    private var elapsedSamples = 0

    // Filtres et gain du bruit par bande.
    private var bandFilters: [Biquad] = []
    private var bandGain: Float = 1

    init(signal: GeneratedSignal, sampleRate: Float) {
        self.signal = signal
        self.sampleRate = sampleRate
        if case let .bandNoise(low, high) = signal {
            let lowCut = Float(min(low, high))
            let highCut = Float(max(low, high))
            // Deux filtres en cascade de chaque côté (4e ordre) : des flancs assez raides
            // pour que l'énergie reste dans la zone testée.
            bandFilters = [
                .highPass(cutoff: lowCut, sampleRate: sampleRate),
                .highPass(cutoff: lowCut, sampleRate: sampleRate),
                .lowPass(cutoff: highCut, sampleRate: sampleRate),
                .lowPass(cutoff: highCut, sampleRate: sampleRate)
            ]
            // Le bruit rose répartit son énergie sur ~10 octaves : une bande étroite en garde
            // une petite part. On compense pour garder un niveau d'écoute comparable, sans
            // dépasser ×4 pour ne pas saturer.
            let bandOctaves = max(log2(highCut / max(lowCut, 1)), 0.1)
            bandGain = min((10 / bandOctaves).squareRoot(), 4)
        }
    }

    /// Produit l'échantillon suivant.
    func next() -> Float {
        switch signal {
        case .noise(.white):
            return Float.random(in: -1...1) * Self.outputLevel
        case .noise(.pink):
            return nextPink()
        case let .sweep(start, end, duration):
            return nextSweep(start: Float(start), end: Float(end), duration: Float(duration))
        case .bandNoise:
            var sample = nextPink()
            for index in bandFilters.indices {
                sample = bandFilters[index].process(sample)
            }
            return min(max(sample * bandGain, -1), 1)
        }
    }

    private func nextPink() -> Float {
        let white = Float.random(in: -1...1)
        // Coefficients du filtre de Paul Kellet : ils approchent une pente de -3 dB/octave.
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        return (b0 + b1 + b2 + white * 0.1848) * Self.pinkScale
    }

    /// Gain de sortie du filtre rose, mesuré : niveau efficace ≈ 0,15 et crêtes ≈ 0,65.
    /// L'ancienne valeur (0,25) donnait des crêtes à 1,9 et saturait près de 2 % des
    /// échantillons, ce qui déformait le spectre de référence.
    private static let pinkScale: Float = 0.087

    private func nextSweep(start: Float, end: Float, duration: Float) -> Float {
        let totalSamples = max(Int(duration * sampleRate), 1)
        let progress = Float(elapsedSamples) / Float(totalSamples)
        // Progression logarithmique : chaque octave dure le même temps, comme l'oreille la perçoit.
        let frequency = start * pow(end / start, progress)
        // La phase est cumulée échantillon par échantillon pour rester continue
        // quand la fréquence change, sinon on entendrait des clics.
        phase += 2 * .pi * frequency / sampleRate
        if phase > 2 * .pi { phase -= 2 * .pi }
        elapsedSamples = (elapsedSamples + 1) % totalSamples
        return sin(phase) * Self.outputLevel
    }
}

/// Filtre biquadratique (formules du « Audio EQ Cookbook » de Robert Bristow-Johnson).
private nonisolated struct Biquad {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    /// Q de Butterworth : réponse la plus plate possible dans la bande passante.
    private static let butterworthQ: Float = 0.7071

    static func lowPass(cutoff: Float, sampleRate: Float) -> Biquad {
        let (cosW, alpha) = parameters(cutoff: cutoff, sampleRate: sampleRate)
        return Biquad(
            b0: (1 - cosW) / 2, b1: 1 - cosW, b2: (1 - cosW) / 2,
            a0: 1 + alpha, a1: -2 * cosW, a2: 1 - alpha
        )
    }

    static func highPass(cutoff: Float, sampleRate: Float) -> Biquad {
        let (cosW, alpha) = parameters(cutoff: cutoff, sampleRate: sampleRate)
        return Biquad(
            b0: (1 + cosW) / 2, b1: -(1 + cosW), b2: (1 + cosW) / 2,
            a0: 1 + alpha, a1: -2 * cosW, a2: 1 - alpha
        )
    }

    /// Coefficients normalisés par `a0`, pour que `process` n'ait pas à diviser.
    private init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    private static func parameters(cutoff: Float, sampleRate: Float) -> (cosW: Float, alpha: Float) {
        // Une coupure au-delà de Nyquist rendrait le filtre instable : on la borne juste en dessous.
        let safeCutoff = min(max(cutoff, 1), sampleRate * 0.45)
        let omega = 2 * .pi * safeCutoff / sampleRate
        return (cos(omega), sin(omega) / (2 * butterworthQ))
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
