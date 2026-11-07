import SwiftUI

/// Draws the band levels either as a bar-style vu-mètre or as a smooth curve,
/// on a logarithmic frequency axis spanning `settings.minFrequency` to `settings.maxFrequency`.
struct SpectrumView: View {
    let levels: [Float]
    /// Live levels of the music source, drawn as a dashed line over the microphone levels.
    var referenceLevels: [Float] = []
    let settings: SpectrumSettings

    private let axisLabels: [Double] = [30, 100, 200, 1_000,2000, 10_000, 20_000]
    private let gridFractions: [Double] = [1, 0.75, 0.5, 0.25, 0]
    private let decibelAxisWidth: CGFloat = 34

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 2) {
                    Text("dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    decibelAxis
                }
                .frame(width: decibelAxisWidth)

                Canvas { context, size in
                    drawGrid(context: context, size: size)
                    switch settings.displayStyle {
                    case .bars:
                        drawBars(context: context, size: size)
                    case .curve:
                        drawCurve(context: context, size: size)
                    }
                    drawReference(context: context, size: size)
                }
                .background(
                    LinearGradient(
                        colors: [AppTheme.deepBlue, AppTheme.deepTeal],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .glassSurface(in: .rect(cornerRadius: 24), isClear: true)
            }

            frequencyAxis
                .padding(.leading, decibelAxisWidth + 6)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground() }
    }

    private var decibelAxis: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                ForEach(gridFractions, id: \.self) { fraction in
                    let db = settings.minDecibels + Float(fraction) * (settings.maxDecibels - settings.minDecibels)
                    Text("\(Int(db))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .position(x: geo.size.width - 18, y: yPosition(for: fraction, height: geo.size.height))
                }
            }
        }
    }

    private func yPosition(for fraction: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(height * (1 - fraction), 6), height - 6)
        return clamped
    }

    private var frequencyAxis: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(axisLabels, id: \.self) { freq in
                    let x = xPosition(for: freq, width: geo.size.width)
                    Text(label(for: freq))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .position(x: x, y: 8)
                }
            }
        }
        .frame(height: 16)
    }

    private func label(for freq: Double) -> String {
        freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"
    }

    private func xPosition(for freq: Double, width: CGFloat) -> CGFloat {
        let minFreq = max(settings.minFrequency, 1)
        let maxFreq = max(settings.maxFrequency, minFreq + 1)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let clamped = min(max(freq, minFreq), maxFreq)
        let fraction = (log10(clamped) - logMin) / (logMax - logMin)
        return CGFloat(fraction) * width
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var path = Path()
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let y = size.height * (1 - fraction)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    private func drawBars(context: GraphicsContext, size: CGSize) {
        guard !levels.isEmpty else { return }
        let minDB = settings.minDecibels
        let maxDB = settings.maxDecibels
        let range = max(maxDB - minDB, 1)
        let spacing: CGFloat = 2
        let barWidth = max((size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count), 1)

        for (index, level) in levels.enumerated() {
            let normalized = min(max((level - minDB) / range, 0), 1)
            let barHeight = CGFloat(normalized) * size.height
            let x = CGFloat(index) * (barWidth + spacing)
            let rect = CGRect(x: x, y: size.height - barHeight, width: barWidth, height: barHeight)

            // Pastel mint (quiet) to sky blue (loud).
            let hue = 0.42 + 0.18 * Double(normalized)
            let color = Color(hue: hue, saturation: 0.45, brightness: 0.97)
            context.fill(Path(rect), with: .color(color))
        }
    }

    /// Draws the band levels as a single smooth curve (Catmull-Rom spline) with a
    /// soft gradient fill underneath, giving a classic graphic-equalizer look.
    private func drawCurve(context: GraphicsContext, size: CGSize) {
        guard !levels.isEmpty else { return }
        let minDB = settings.minDecibels
        let maxDB = settings.maxDecibels
        let range = max(maxDB - minDB, 1)

        let points: [CGPoint] = levels.enumerated().map { index, level in
            let normalized = min(max((level - minDB) / range, 0), 1)
            let x = levels.count > 1
                ? CGFloat(index) / CGFloat(levels.count - 1) * size.width
                : size.width / 2
            let y = size.height - CGFloat(normalized) * size.height
            return CGPoint(x: x, y: y)
        }

        let line = smoothPath(through: points)

        var fillArea = line
        fillArea.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
        fillArea.addLine(to: CGPoint(x: points[0].x, y: size.height))
        fillArea.closeSubpath()

        let accentHue = 0.5
        let fillGradient = Gradient(colors: [
            Color(hue: accentHue, saturation: 0.75, brightness: 0.95).opacity(0.4),
            Color(hue: accentHue, saturation: 0.75, brightness: 0.95).opacity(0.0)
        ])
        context.fill(
            fillArea,
            with: .linearGradient(
                fillGradient,
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        let strokeGradient = Gradient(colors: [
            Color(hue: 0.40, saturation: 0.45, brightness: 0.97),
            Color(hue: 0.50, saturation: 0.45, brightness: 1.0),
            Color(hue: 0.60, saturation: 0.50, brightness: 0.98)
        ])
        context.stroke(
            line,
            with: .linearGradient(
                strokeGradient,
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: size.width, y: 0)
            ),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
        )
    }

    /// Draws what the source is playing as a dashed line. The source level and the microphone
    /// level are not comparable in absolute terms, so the reference is shifted to match the
    /// microphone on the mid range (250 Hz–2 kHz), like in the analysis.
    private func drawReference(context: GraphicsContext, size: CGSize) {
        let count = referenceLevels.count
        guard count > 1, levels.count == count else { return }

        let minFreq = max(settings.minFrequency, 1)
        let maxFreq = max(settings.maxFrequency, minFreq + 1)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)

        var midIndices = (0..<count).filter { index in
            let fraction = (Double(index) + 0.5) / Double(count)
            let frequency = pow(10, logMin + (logMax - logMin) * fraction)
            return frequency >= 250 && frequency < 2_000
        }
        if midIndices.isEmpty {
            midIndices = Array(0..<count)
        }
        let micMean = midIndices.map { levels[$0] }.reduce(0, +) / Float(midIndices.count)
        let referenceMean = midIndices.map { referenceLevels[$0] }.reduce(0, +) / Float(midIndices.count)
        let offset = micMean - referenceMean

        let minDB = settings.minDecibels
        let range = max(settings.maxDecibels - minDB, 1)

        var path = Path()
        for (index, level) in referenceLevels.enumerated() {
            let normalized = min(max((level + offset - minDB) / range, 0), 1)
            // Same horizontal placement as the bars (centered) so both views line up.
            let barSpacing: CGFloat = 2
            let barWidth = max((size.width - barSpacing * CGFloat(count - 1)) / CGFloat(count), 1)
            let x = settings.displayStyle == .bars
                ? CGFloat(index) * (barWidth + barSpacing) + barWidth / 2
                : CGFloat(index) / CGFloat(count - 1) * size.width
            let y = size.height - CGFloat(normalized) * size.height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(
            path,
            with: .color(.white),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 4])
        )
        context.draw(
            Text("- - Référence").font(.caption2).foregroundStyle(.white),
            at: CGPoint(x: size.width - 50, y: 10)
        )
    }

    /// Builds a smooth path through the given points using a Catmull-Rom spline.
    private func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]

            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}

#Preview {
    let settings = SpectrumSettings()
    SpectrumView(
        levels: (0..<settings.numberOfBands).map { _ in Float.random(in: -80...0) },
        settings: settings
    )
    .frame(height: 220)
    .padding()
}
