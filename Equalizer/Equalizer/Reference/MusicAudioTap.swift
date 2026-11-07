#if os(macOS)
import AppKit
import CoreAudio
import Foundation

/// Captures the audio output of the Music app with a Core Audio process tap and turns it
/// into band levels, using the same calculator as the microphone analysis.
///
/// The tap is unmuted, so Music keeps playing normally (to the AirPlay speakers).
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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // Touched only from `queue` once running.
    private var config = SpectrumConfig(
        fftSize: 4096, numberOfBands: 32, minFrequency: 30, maxFrequency: 20_000,
        minDecibels: -190, maxDecibels: 0
    )
    private var sampleRate: Float = 48_000
    private var channelCount = 2
    private var isInterleaved = true
    private var pending: [Float] = []

    /// Called on a private queue with each new block of band levels.
    var onFrame: (@Sendable (ReferenceFrame) -> Void)?

    deinit {
        stop()
    }

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
            stop()
            throw error
        }
    }

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

    // MARK: - Setup

    private var tapUUID = UUID()

    private func createTap() throws {
        guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).first else {
            throw TapError.musicNotRunning
        }

        var pid = music.processIdentifier
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject
        )
        // Music has no audio process object until it has produced sound at least once.
        guard status == noErr, processObject != kAudioObjectUnknown else {
            throw TapError.musicNotRunning
        }

        tapUUID = UUID()
        // The default mute behavior leaves Music audible, which is what we want.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = tapUUID
        description.isPrivate = true

        status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.coreAudio("création du tap", status) }
    }

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
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString
            ]]
        ]
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.coreAudio("création de l'appareil agrégé", status) }
    }

    private func startIO() throws {
        var format = AudioStreamBasicDescription()
        var address = Self.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw TapError.coreAudio("lecture du format", status) }
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

    // MARK: - Processing (on `queue`)

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, let firstData = first.mData else { return }

        // Mix down to mono.
        if isInterleaved {
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

        // Same non-overlapping blocks as the microphone tap (one FFT per `fftSize` samples).
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

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

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
        return uid.takeRetainedValue() as String
    }
}
#endif
