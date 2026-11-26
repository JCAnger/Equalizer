import AVFoundation
import Foundation
import os

/// Ce dont le générateur de bruit a besoin pour produire un signal et en publier le spectre.
/// Sert de point d'injection : les tests peuvent le remplacer par une doublure sans audio.
nonisolated protocol SignalPlaying: AnyObject, Sendable {
    /// Appelé sur un thread audio à chaque nouveau bloc de niveaux de bandes.
    var onFrame: (@Sendable (ReferenceFrame) -> Void)? { get set }
    /// Description de la sortie actuelle, `nil` si elle n'est pas connue.
    var outputName: String? { get }

    func loadSignal(_ signal: GeneratedSignal, config: SpectrumConfig)
    func play() throws
    func pause()
    func stop()
}

/// Joue un signal de test généré (bruit, balayage…) et convertit exactement ce qui est envoyé
/// aux enceintes en niveaux de bandes, avec le même calculateur que l'analyse du microphone.
///
/// Les niveaux sont pris à la sortie du mélangeur principal : les changements de volume faits
/// sur l'appareil lui-même n'ont donc pas d'importance, seule la forme du spectre est comparée.
///
/// Les rappels audio arrivent sur des threads audio : ce type n'est donc volontairement
/// pas isolé au main actor.
nonisolated final class ReferencePlayer: SignalPlaying, @unchecked Sendable {
    enum PlayerError: LocalizedError {
        case noSignal

        var errorDescription: String? {
            String(localized: "Aucun signal choisi.")
        }
    }

    private static let logger = Logger(subsystem: "Equalizer", category: "Audio")

    private let shared: SharedAudioEngine
    private var engine: AVAudioEngine { shared.engine }
    private var noiseNode: AVAudioSourceNode?
    private let calculator = SpectrumBandCalculator()
    /// Protège `isActive`, lu depuis des threads audio.
    private let lock = NSLock()

    /// Signal à jouer (bruit, balayage…), `nil` tant qu'aucun n'est chargé.
    private var signal: GeneratedSignal?
    /// Faux tant que le graphe audio n'a pas été (re)construit après un chargement.
    private var isGraphReady = false
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

    /// - Parameter audio: moteur partagé avec le micro. Le système arrête et relance ce moteur
    ///   quand la sortie change (AirPlay, Bluetooth, casque) : le graphe est alors reconstruit.
    init(audio: SharedAudioEngine) {
        shared = audio
        audio.setReconfigureHandler(for: .generator) { [weak self] in
            self?.rebuildAfterConfigurationChange()
        }
    }

    deinit {
        stop()
    }

    /// Description de la sortie actuelle (ex. « Haut-parleur · volume média 50 % … »),
    /// affichée pour aider à comprendre où part le son. `nil` sur Mac.
    var outputName: String? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first?.portName ?? String(localized: "aucune")
        // Le pourcentage est formaté ici, et non écrit « % » dans la chaîne localisée : chaque langue
        // place différemment le signe (« 50 % » en français, « 50% » en anglais).
        let volume = Double(session.outputVolume).formatted(.percent.precision(.fractionLength(0)))
        let rate = Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)
        let channels = engine.outputNode.outputFormat(forBus: 0).channelCount
        return String(localized: "\(port) · volume média \(volume) · \(rate) Hz · \(channels) can.")
        #else
        nil
        #endif
    }

    /// Appelé par le moteur partagé quand le système l'a arrêté : les formats audio ont pu changer.
    /// Si le bruit jouait, le graphe est reconstruit avant la relance ; sinon, au prochain `play()`.
    private func rebuildAfterConfigurationChange() {
        lock.lock()
        let wasActive = isActive
        lock.unlock()
        isGraphReady = false
        guard signal != nil, wasActive else { return }
        do {
            try buildGraph()
            noiseNode?.volume = 1
        } catch {
            Self.logger.error("Reconstruction du générateur impossible : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Utilise un signal de test généré (bruit, balayage, bruit par bande).
    /// Le graphe est reconstruit au prochain `play()`.
    func loadSignal(_ signal: GeneratedSignal, config: SpectrumConfig) {
        // Le bruit est seulement coupé : la sortie reste ouverte pour que le suivant démarre aussitôt.
        pause()
        self.signal = signal
        lock.lock()
        self.config = config
        pending.removeAll()
        lock.unlock()
        isGraphReady = false
    }

    /// Démarre (ou reprend) la lecture.
    /// - Throws: `PlayerError.noSignal` si rien n'est chargé, ou l'erreur de la session / du moteur.
    func play() throws {
        guard signal != nil else { throw PlayerError.noSignal }

        #if os(iOS)
        try MeasurementAudioSession.activate()
        Self.logger.info("Session activée — \(MeasurementAudioSession.routeDescription(), privacy: .public)")
        #endif
        // La sortie est ouverte d'abord, puis la liaison AirPlay renouvelée avec le moteur en marche :
        // c'est le geste manuel qui débloquait l'enceinte (choisir « iPhone » puis revenir à
        // l'enceinte). Aucun nœud n'est encore connecté, donc rien ne sort sur l'appareil pendant la
        // bascule. Si la sortie est déjà ouverte (bruit arrêté depuis peu), rien de tout cela n'est
        // nécessaire : le bruit reprend aussitôt.
        //
        // Quand la sortie est déjà ouverte, on n'y touche surtout pas : la bascule automatique
        // coupait une liaison qui fonctionnait, et seul un vrai choix de l'enceinte par
        // l'utilisateur la rétablissait.
        let wasOutputOpen = shared.isOutputOpen
        try shared.start(for: .generator)
        #if os(iOS)
        if !wasOutputOpen {
            Self.logger.info("Liaison AirPlay renouvelée (sortie ouverte au lancement du bruit)")
            MeasurementAudioSession.renewAirPlayRoute()
            waitForEngineToSettle()
        }
        #endif

        // Le changement de sortie a pu invalider le graphe : il est (re)construit sur le moteur relancé.
        try shared.withExclusiveAccess {
            if !isGraphReady {
                try buildGraph()
            }
        }
        lock.lock()
        isActive = true
        lock.unlock()
        noiseNode?.volume = 1
        Self.logger.info("Moteur du générateur : en marche = \(self.shared.isRunning), graphe prêt = \(self.isGraphReady)")
    }

    func pause() {
        lock.lock()
        isActive = false
        lock.unlock()
        // Le moteur reste en marche, sortie comprise : on coupe seulement le son du bruit. Refermer la
        // sortie ici rendait le lancement suivant muet sur une enceinte AirPlay.
        noiseNode?.volume = 0
        shared.stop(for: .generator, keepOutputOpen: true)
    }

    /// Arrêt complet : la sortie est refermée aussitôt, contrairement à `pause()`.
    func stop() {
        lock.lock()
        isActive = false
        pending.removeAll()
        lock.unlock()
        noiseNode?.volume = 0
        shared.stop(for: .generator)
    }

    #if os(iOS)
    /// Laisse le moteur partagé se relancer après les changements de sortie : le système le stoppe
    /// et il est relancé depuis un autre thread. Le délai final laisse la liaison AirPlay s'établir.
    private func waitForEngineToSettle() {
        let deadline = Date().addingTimeInterval(2)
        while !shared.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    #endif

    // MARK: - Privé

    /// Reconstruit le graphe audio (source -> mélangeur principal) et installe le tap d'analyse.
    /// Le moteur peut déjà tourner (pour le micro) : le nœud est donc ajouté à chaud, ce qu'`AVAudioEngine` permet.
    private func buildGraph() throws {
        engine.mainMixerNode.removeTap(onBus: 0)
        // On détache l'ancien nœud : le signal a pu changer.
        if let noiseNode {
            engine.detach(noiseNode)
            self.noiseNode = nil
        }
        guard let signal else { throw PlayerError.noSignal }

        let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw PlayerError.noSignal
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
        // Muet jusqu'à `play()`.
        source.volume = 0
        noiseNode = source

        lock.lock()
        let fftSize = config.fftSize
        lock.unlock()
        calculator.configure(fftSize: fftSize)
        // Format `nil` : le tap suit toujours le format actuel du mélangeur, même après un changement de sortie.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { [weak self] buffer, _ in
            self?.process(buffer, sampleRate: Float(buffer.format.sampleRate))
        }
        isGraphReady = true
    }

    /// Mixe en mono et calcule une image par `fftSize` échantillons. S'exécute sur le thread du tap audio.
    /// Le moteur tournant aussi pour le micro, le tap reçoit des buffers même quand le bruit est
    /// coupé : ils sont alors ignorés, pour ne pas publier de niveaux ni gaspiller de calcul.
    private func process(_ buffer: AVAudioPCMBuffer, sampleRate: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else {
            pending.removeAll(keepingCapacity: true)
            return
        }
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

/// Signaux de test que le générateur sait produire.
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
