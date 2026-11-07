import Foundation

/// One block of band levels describing what the source device is sending to the speakers.
///
/// Frames travel from the source (Mac) to the measuring device (iPhone) as
/// newline-delimited JSON over a TCP connection discovered with Bonjour.
nonisolated struct ReferenceFrame: Codable, Sendable {
    /// Band levels in dB, log-spaced between `minFrequency` and `maxFrequency`.
    var bands: [Float]
    var minFrequency: Double
    var maxFrequency: Double

    /// Re-maps the bands onto another log-frequency layout by linear interpolation,
    /// so the source and the measuring device don't need identical settings.
    func resampled(bandCount: Int, minFrequency targetMin: Double, maxFrequency targetMax: Double) -> [Float] {
        guard bands.count > 1, bandCount > 0 else { return [Float](repeating: -.infinity, count: max(bandCount, 0)) }

        let sourceLogMin = log10(max(minFrequency, 1))
        let sourceLogMax = log10(max(maxFrequency, minFrequency + 1))
        let targetLogMin = log10(max(targetMin, 1))
        let targetLogMax = log10(max(targetMax, targetMin + 1))

        return (0..<bandCount).map { index in
            let fraction = (Double(index) + 0.5) / Double(bandCount)
            let logFrequency = targetLogMin + (targetLogMax - targetLogMin) * fraction
            let sourceFraction = (logFrequency - sourceLogMin) / (sourceLogMax - sourceLogMin)
            // Band i of the source is centered on (i + 0.5) / count.
            let position = min(max(sourceFraction * Double(bands.count) - 0.5, 0), Double(bands.count - 1))
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, bands.count - 1)
            let weight = Float(position - Double(lower))
            return bands[lower] * (1 - weight) + bands[upper] * weight
        }
    }
}

nonisolated enum ReferenceProtocol {
    /// Bonjour service type advertised by the source and browsed by the measuring device.
    static let serviceType = "_equalizerref._tcp"
}
