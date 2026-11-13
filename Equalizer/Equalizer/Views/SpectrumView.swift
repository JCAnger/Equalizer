import SwiftUI

/// Dessine les niveaux des bandes sous forme de vumètre à barres ou de courbe lissée,
/// sur un axe de fréquences logarithmique allant de `settings.minFrequency` à `settings.maxFrequency`.
struct SpectrumView: View {
    /// Niveaux (dB) du microphone, une valeur par bande.
    let levels: [Float]
    /// Niveaux en direct de la source musicale, dessinés en pointillés par-dessus ceux du microphone.
    var referenceLevels: [Float] = []
    let settings: SpectrumSettings

    /// Fréquences (Hz) repérées sous le graphique.
    private let axisLabels: [Double] = [30, 100, 200, 1_000,2000, 10_000, 20_000]
    /// Positions des lignes de la grille et des repères en dB, de 1 (haut) à 0 (bas).
    private let gridFractions: [Double] = [1, 0.75, 0.5, 0.25, 0]
    /// Retrait des graduations dB depuis le bord gauche, pour échapper à l'arrondi des coins (rayon 24).
    private let decibelLabelInset: CGFloat = 16

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                // Ordre de dessin : grille au fond, niveaux, référence, puis graduations
                // par-dessus pour qu'elles restent visibles.
                drawGrid(context: context, size: size)
                switch settings.displayStyle {
                case .bars:
                    drawBars(context: context, size: size)
                case .curve:
                    drawCurve(context: context, size: size)
                }
                drawReference(context: context, size: size)
                drawDecibelLabels(context: context, size: size)
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

            frequencyAxis
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground() }
        // Le spectre reste sur fond sombre même en mode clair : un fond pastel lumineux autour
        // du graphique sombre crée un contraste trop fort. Forcer le mode sombre donne aussi
        // des textes d'axes clairs, lisibles sur ce fond.
        .environment(\.colorScheme, .dark)
    }

    /// Graduations en dB dessinées dans le graphique, juste au-dessus de chaque ligne de grille
    /// (en dessous pour la ligne du haut, qui n'a pas de place au-dessus).
    /// Chaque valeur est posée sur une pastille sombre translucide : sans elle, le texte blanc
    /// serait illisible sur les barres pastel qu'il recouvre.
    private func drawDecibelLabels(context: GraphicsContext, size: CGSize) {
        let padding = CGSize(width: 4, height: 1)
        for fraction in gridFractions {
            let db = settings.minDecibels + Float(fraction) * (settings.maxDecibels - settings.minDecibels)
            // L'unité n'est indiquée que sur la graduation du haut, pour ne pas surcharger.
            let text = fraction == 1 ? "\(Int(db)) dB" : "\(Int(db))"
            let resolved = context.resolve(Text(text).font(.caption2).foregroundStyle(.white.opacity(0.9)))
            let textSize = resolved.measure(in: size)

            let lineY = size.height * (1 - fraction)
            let isTop = fraction == 1
            let badgeHeight = textSize.height + padding.height * 2
            let badge = CGRect(
                x: decibelLabelInset,
                y: isTop ? lineY + 2 : lineY - 2 - badgeHeight,
                width: textSize.width + padding.width * 2,
                height: badgeHeight
            )
            context.fill(Path(roundedRect: badge, cornerRadius: badgeHeight / 2), with: .color(AppTheme.deepBlue.opacity(0.7)))
            context.draw(resolved, at: CGPoint(x: badge.midX, y: badge.midY), anchor: .center)
        }
    }

    /// Repères de fréquence sous le graphique, placés sur l'échelle logarithmique.
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

    /// Position horizontale d'une fréquence : proportionnelle à son logarithme, comme les bandes.
    private func xPosition(for freq: Double, width: CGFloat) -> CGFloat {
        let minFreq = max(settings.minFrequency, 1)
        let maxFreq = max(settings.maxFrequency, minFreq + 1)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let clamped = min(max(freq, minFreq), maxFreq)
        let fraction = (log10(clamped) - logMin) / (logMax - logMin)
        return CGFloat(fraction) * width
    }

    /// Lignes horizontales discrètes, une par repère de l'axe des dB.
    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var path = Path()
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let y = size.height * (1 - fraction)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    /// Dessine une barre par bande, dont la hauteur reflète le niveau entre `minDecibels` et `maxDecibels`.
    private func drawBars(context: GraphicsContext, size: CGSize) {
        guard !levels.isEmpty else { return }
        let minDB = settings.minDecibels
        let maxDB = settings.maxDecibels
        let range = max(maxDB - minDB, 1)
        let spacing: CGFloat = 2
        let barWidth = max((size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count), 1)

        // Un seul dégradé partagé par toutes les barres, ancré sur toute la hauteur de la vue :
        // bleu en bas (faible) vers rose en haut (fort), si bien que la couleur d'une
        // barre révèle son niveau, comme sur un vumètre classique.
        let barGradient = GraphicsContext.Shading.linearGradient(
            // Le violet intermédiaire évite une zone grisâtre entre le bleu et le rose.
            Gradient(colors: [AppTheme.spectrumLow, AppTheme.spectrumMid, AppTheme.spectrumHigh]),
            startPoint: CGPoint(x: 0, y: size.height),
            endPoint: CGPoint(x: 0, y: 0)
        )

        for (index, level) in levels.enumerated() {
            let normalized = min(max((level - minDB) / range, 0), 1)
            let barHeight = CGFloat(normalized) * size.height
            let x = CGFloat(index) * (barWidth + spacing)
            let rect = CGRect(x: x, y: size.height - barHeight, width: barWidth, height: barHeight)
            context.fill(Path(rect), with: barGradient)
        }
    }

    /// Dessine les niveaux des bandes en une seule courbe lissée (spline de Catmull-Rom)
    /// avec un remplissage en dégradé doux dessous, pour un aspect d'égaliseur graphique classique.
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

        // Zone de remplissage : la courbe refermée par le bas du graphique.
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

    /// Dessine ce que joue la source sous forme de ligne en pointillés. Les niveaux de la source
    /// et du microphone ne sont pas comparables en valeur absolue : la référence est donc décalée
    /// pour coïncider avec le microphone sur les médiums (250 Hz–2 kHz), comme dans l'analyse.
    private func drawReference(context: GraphicsContext, size: CGSize) {
        let count = referenceLevels.count
        guard count > 1, levels.count == count else { return }

        let minFreq = max(settings.minFrequency, 1)
        let maxFreq = max(settings.maxFrequency, minFreq + 1)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)

        // Bandes dont le centre tombe dans les médiums ; à défaut (plage réduite), toutes les bandes.
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
            // Même placement horizontal que les barres (centré) pour que les deux vues soient alignées.
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

    /// Construit un tracé lisse passant par les points donnés, avec une spline de Catmull-Rom
    /// convertie en courbes de Bézier cubiques (points de contrôle à 1/6 des tangentes).
    private func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        for i in 0..<(points.count - 1) {
            // Aux extrémités, le point voisin manquant est remplacé par le point lui-même.
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
