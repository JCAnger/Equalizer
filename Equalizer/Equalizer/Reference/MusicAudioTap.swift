#if os(macOS)
import AppKit
import CoreAudio
import Foundation

/// Capture la sortie audio de l'app Music avec un tap de processus Core Audio et la convertit
/// en niveaux de bandes, avec le même calculateur que l'analyse du microphone.
///
/// Le tap n'est pas muet : Music continue de jouer normalement (vers les enceintes AirPlay).
nonisolated final class MusicAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case musicNotRunning
        case unsupportedFormat
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .musicNotRunning:
                return "Music n'est pas ouvert. Lancez Music puis démarrez la lecture."
            case .unsupportedFormat:
                return "Format audio de la capture non pris en charge."
            case let .coreAudio(step, status):
                return "Capture audio impossible (\(step), code \(status)). Vérifiez l'autorisation « Enregistrement audio du système » dans Réglages Système."
            }
        }
    }

    private static let musicBundleID = "com.apple.Music"

    private let queue = DispatchQueue(label: "MusicAudioTap", qos: .userInitiated)
    private let calculator = SpectrumBandCalculator()

    /// Identifiants Core Audio des objets créés ; `kAudioObjectUnknown` signifie « rien à détruire ».
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // Touché uniquement depuis `queue` une fois la capture lancée. Les valeurs initiales
    // sont remplacées dans `start(config:)` et `startIO()`.
    private var config = SpectrumConfig(
        fftSize: 4096, numberOfBands: 32, minFrequency: 30, maxFrequency: 20_000,
        minDecibels: -190, maxDecibels: 0
    )
    private var sampleRate: Float = 48_000
    private var channelCount = 2
    private var isInterleaved = true
    /// Échantillons mono en attente : un bloc de capture n'a pas forcément la taille de la FFT.
    private var pending: [Float] = []

    /// Appelé sur une file privée à chaque nouveau bloc de niveaux de bandes.
    var onFrame: (@Sendable (ReferenceFrame) -> Void)?

    deinit {
        stop()
    }

    /// Démarre la capture. Relance proprement si elle était déjà active.
    /// - Throws: `TapError` si Music est introuvable ou si Core Audio refuse une étape.
    func start(config: SpectrumConfig) throws {
        stop()
        self.config = config
        calculator.configure(fftSize: config.fftSize)
        pending.removeAll()

        do {
            try createTap()
            try createAggregateDevice()
            try startIO()
        } catch {
            // Libère ce qui a déjà été créé pour ne laisser aucun appareil fantôme dans le système.
            stop()
            throw error
        }
    }

    /// Détruit les ressources dans l'ordre inverse de leur création.
    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Mise en place

    /// Identifiant du tap, repris dans l'appareil agrégé pour l'y rattacher.
    private var tapUUID = UUID()

    /// Crée le tap sur le processus de Music.
    private func createTap() throws {
        guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).first else {
            throw TapError.musicNotRunning
        }

        // Core Audio désigne les processus par un objet audio, à ne pas confondre avec le PID.
        var pid = music.processIdentifier
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject
        )
        // Music n'a pas d'objet audio tant qu'il n'a pas produit de son au moins une fois.
        guard status == noErr, processObject != kAudioObjectUnknown else {
            throw TapError.musicNotRunning
        }

        tapUUID = UUID()
        // Le comportement de sourdine par défaut laisse Music audible, ce qui est voulu.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = tapUUID
        // Privé : le tap n'est pas visible des autres apps.
        description.isPrivate = true

        status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.coreAudio("création du tap", status) }
    }

    /// Crée un appareil agrégé qui regroupe le tap et la sortie par défaut. Core Audio
    /// ne permet de lire un tap qu'à travers un appareil, d'où cet intermédiaire.
    private func createAggregateDevice() throws {
        let outputUID = try Self.defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Equalizer Music Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                // Compense la dérive d'horloge entre le tap et le périphérique de sortie.
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString
            ]]
        ]
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.coreAudio("création de l'appareil agrégé", status) }
    }

    /// Lit le format du tap, puis installe le callback audio et démarre le flux.
    private func startIO() throws {
        var format = AudioStreamBasicDescription()
        var address = Self.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw TapError.coreAudio("lecture du format", status) }
        // `handle(_:)` lit des Float 32 bits : tout autre format serait mal interprété.
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw TapError.unsupportedFormat
        }
        sampleRate = Float(format.mSampleRate)
        channelCount = max(Int(format.mChannelsPerFrame), 1)
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let ioProcID else { throw TapError.coreAudio("création de l'IOProc", status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError.coreAudio("démarrage", status) }
    }

    // MARK: - Traitement (sur `queue`)

    /// Réduit chaque bloc reçu en mono, l'accumule, puis calcule une image par `fftSize` échantillons.
    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, let firstData = first.mData else { return }

        // Mixage en mono : moyenne des canaux. Le format détermine la disposition mémoire.
        if isInterleaved {
            // Canaux entrelacés dans un seul buffer : L R L R…
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = firstData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                pending.append(sum / Float(channels))
            }
        } else {
            // Un buffer par canal : on les additionne échantillon par échantillon.
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            var mono = [Float](repeating: 0, count: frames)
            var usedChannels: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for frame in 0..<count {
                    mono[frame] += samples[frame]
                }
                usedChannels += 1
            }
            if usedChannels > 0 {
                pending.append(contentsOf: mono.map { $0 / usedChannels })
            }
        }

        // Mêmes blocs sans recouvrement que le tap du microphone (une FFT par `fftSize`
        // échantillons), pour que les deux mesures restent comparables.
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

    // MARK: - Utilitaires Core Audio

    /// Adresse de propriété globale pour un sélecteur donné (cas le plus courant).
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Renvoie l'UID de la sortie audio par défaut, requis pour décrire l'appareil agrégé.
    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw TapError.coreAudio("sortie audio par défaut", status) }

        var uid: Unmanaged<CFString>?
        var uidAddress = self.address(kAudioDevicePropertyDeviceUID)
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw TapError.coreAudio("UID de la sortie", status) }
        // Core Audio rend la chaîne avec un compteur +1 : `takeRetainedValue` évite une fuite.
        return uid.takeRetainedValue() as String
    }
}
#endif
