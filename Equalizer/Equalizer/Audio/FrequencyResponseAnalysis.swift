import Foundation

/// Verdict for a frequency zone, based on its deviation from the target curve.
enum ResponseVerdict {
    case lacking
    case balanced
    case excess

    var label: String {
        switch self {
        case .lacking: return "Manque"
        case .balanced: return "Équilibré"
        case .excess: return "Excès"
        }
    }
}

/// Deviation (in dB) of one analysis band from the target curve.
struct BandDeviation: Identifiable {
    let id: Int
    let centerFrequency: Double
    let deviation: Float
}

/// Average deviation of a named range of frequencies (sub-bass, bass, mids…).
struct ZoneDeviation: Identifiable {
    let name: String
    let range: Range<Double>
    let deviation: Float
    let verdict: ResponseVerdict

    var id: String { name }
}

struct FrequencyResponseReport {
    let bands: [BandDeviation]
    let zones: [ZoneDeviation]
    /// Expected level (dB) per band: what the source sends, or the typical music spectrum.
    let expected: [Float]
    /// Level (dB) per band heard by the microphone, shifted so it matches `expected`
    /// on the mid range. The gap between the two curves is the deviation.
    let restituted: [Float]
}

/// Compares the long-term average spectrum of the music captured by the microphone
/// with a typical music spectrum (a straight line of `targetSlope` dB per octave).
///
/// Absolute levels are unknown (volume, mic gain), so the target is aligned on the mean
/// level of the mid range. Deviations are therefore relative to the mids: a zone at
/// -6 dB means "6 dB quieter than it should be compared to the mids".
enum FrequencyResponseAnalysis {
    /// Typical slope of the average spectrum of music, in dB per octave.
    static let targetSlope: Float = -3
    /// Deviations within ± this value are considered balanced, in dB.
    static let tolerance: Float = 3

    private static let referenceRange = 250.0..<2_000.0

    private static let zoneDefinitions: [(name: String, range: Range<Double>)] = [
        ("Sub-graves", 0..<60),
        ("Graves", 60..<250),
        ("Bas-médiums", 250..<500),
        ("Médiums", 500..<2_000),
        ("Haut-médiums", 2_000..<4_000),
        ("Présence", 4_000..<6_000),
        ("Aigus", 6_000..<Double.infinity)
    ]

    /// - Parameter referenceLevels: average levels of what the source sends to the speakers
    ///   (same band layout as `averageLevels`). When `nil` or mismatched, the typical music
    ///   spectrum (`targetSlope`) is used as the target instead.
    static func report(
        averageLevels: [Float],
        referenceLevels: [Float]? = nil,
        settings: SpectrumSettings
    ) -> FrequencyResponseReport? {
        let count = averageLevels.count
        guard count > 1 else { return nil }
        let reference = referenceLevels.flatMap { $0.count == count ? $0 : nil }

        let minFreq = max(settings.minFrequency, 1)
        let maxFreq = max(settings.maxFrequency, minFreq + 1)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)

        // Raw deviation = measured level - target slope (referenced to 1 kHz).
        var centers: [Double] = []
        var targets: [Float] = []
        var raw: [Float] = []
        for i in 0..<count {
            let fraction = (Double(i) + 0.5) / Double(count)
            let center = pow(10, logMin + (logMax - logMin) * fraction)
            let octavesFromReference = Float(log2(center / 1_000))
            centers.append(center)
            let target = reference?[i] ?? targetSlope * octavesFromReference
            targets.append(target)
            raw.append(averageLevels[i] - target)
        }

        let referenceValues = zip(centers, raw)
            .filter { referenceRange.contains($0.0) }
            .map(\.1)
        let offsetSource = referenceValues.isEmpty ? raw : referenceValues
        let offset = offsetSource.reduce(0, +) / Float(offsetSource.count)

        let bands = raw.indices.map {
            BandDeviation(id: $0, centerFrequency: centers[$0], deviation: raw[$0] - offset)
        }

        let zones: [ZoneDeviation] = zoneDefinitions.compactMap { definition in
            let members = bands.filter { definition.range.contains($0.centerFrequency) }
            guard !members.isEmpty else { return nil }
            let mean = members.map(\.deviation).reduce(0, +) / Float(members.count)
            let verdict: ResponseVerdict = mean < -tolerance ? .lacking : (mean > tolerance ? .excess : .balanced)
            return ZoneDeviation(name: definition.name, range: definition.range, deviation: mean, verdict: verdict)
        }

        let restituted = zip(targets, bands).map { $0 + $1.deviation }
        return FrequencyResponseReport(bands: bands, zones: zones, expected: targets, restituted: restituted)
    }
}
