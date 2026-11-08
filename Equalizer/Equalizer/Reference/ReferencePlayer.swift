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
    private var noiseColor: NoiseColor?
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
        // Le bruit généré est joué par son propre nœud source : seul le lecteur de fichier a besoin de `play()`.
        if noiseColor == nil { node.play() }
    }

    /// Charge un fichier audio. Le graphe est reconstruit au prochain `play()`.
    /// - Throws: l'erreur d'`AVAudioFile` si le fichier est illisible.
    func load(_ url: URL, config: SpectrumConfig) throws {
        stop()
        file = try AVAudioFile(forReading: url)
        noiseColor = nil
        self.config = config
        isGraphReady = false
    }

    /// Utilise un bruit généré (rose ou blanc) à la place d'un fichier.
    /// Le bruit rose a une énergie égale par octave : c'est un signal de test classique.
    func loadNoise(_ color: NoiseColor, config: SpectrumConfig) {
        stop()
        file = nil
        noiseColor = color
        self.config = config
        isGraphReady = false
    }

    /// Démarre (ou reprend) la lecture.
    /// - Throws: `PlayerError.noFile` si rien n'est chargé, ou l'erreur de la session / du moteur.
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

        // Le bruit est produit en continu par le moteur : pas de fichier à planifier.
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
            // Le générateur de bruit n'a pas de nœud lecteur à mettre en pause : on suspend tout le moteur.
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
        if let color = noiseColor {
            let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw PlayerError.noFile
            }
            let generator = NoiseGenerator(color: color)
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

/// Signaux de test générés : le bruit rose a une énergie égale par octave, le bruit blanc par hertz.
nonisolated enum NoiseColor {
    case pink
    case white
}

/// Bruit blanc, éventuellement filtré en bruit rose (-3 dB/octave) avec le filtre de Paul Kellet.
/// Utilisé depuis un seul thread de rendu audio, d'où l'absence de verrou sur l'état du filtre.
private nonisolated final class NoiseGenerator {
    private let color: NoiseColor
    /// État du filtre rose (trois filtres passe-bas du premier ordre en parallèle).
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0

    init(color: NoiseColor) {
        self.color = color
    }

    /// Produit l'échantillon suivant.
    func next() -> Float {
        let white = Float.random(in: -1...1)
        // Le facteur 0,3 ramène le bruit blanc à un niveau d'écoute raisonnable.
        if color == .white { return white * 0.3 }
        // Coefficients du filtre de Paul Kellet : ils approchent une pente de -3 dB/octave.
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        return (b0 + b1 + b2 + white * 0.1848) * 0.25
    }
}
