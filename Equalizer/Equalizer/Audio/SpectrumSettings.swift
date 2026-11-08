import Foundation
import Observation

/// Paramètres modifiables qui contrôlent le calcul et l'affichage de la courbe du spectre.
///
/// Les propriétés sont lues par le thread temps réel du tap audio et écrites depuis le
/// main actor par l'interface. Ces accès à des valeurs scalaires sont des courses de
/// données tolérées : au pire, une image d'analyse est calculée avec l'ancienne valeur.
/// C'est la pratique courante pour des paramètres audio en direct, et cela évite de poser
/// un verrou sur le thread audio, qui doit rester non bloquant.
@Observable
nonisolated final class SpectrumSettings {
    /// Façon de dessiner les niveaux des bandes dans `SpectrumView`.
    enum DisplayStyle: String, CaseIterable, Identifiable {
        case bars
        case curve

        var id: Self { self }

        /// Libellé affiché dans le sélecteur de style.
        var label: String {
            switch self {
            case .bars: return "Barres"
            case .curve: return "Courbe"
            }
        }
    }

    /// Borne basse de la plage de fréquences analysée, en hertz.
    var minFrequency: Double = 30
    /// Borne haute de la plage de fréquences analysée, en hertz.
    var maxFrequency: Double = 20_000

    /// Style visuel utilisé pour afficher les niveaux des bandes.
    var displayStyle: DisplayStyle = .bars

    /// Nombre de barres dessinées sur la plage de fréquences (espacées de façon logarithmique,
    /// comme la perception de l'oreille).
    var numberOfBands: Int = 32

    /// Les niveaux inférieurs ou égaux à cette valeur sont dessinés en bas du vumètre.
    var minDecibels: Float = -220
    /// Les niveaux supérieurs ou égaux à cette valeur sont dessinés en haut du vumètre.
    var maxDecibels: Float = 0

    /// Vitesse de montée d'une barre quand le niveau augmente (0 = figée, 1 = instantanée).
    var attack: Float = 0.6
    /// Vitesse de descente d'une barre quand le niveau baisse (0 = figée, 1 = instantanée).
    /// Plus lente que l'attaque par défaut, pour que les pics restent lisibles.
    var release: Float = 0.15

    /// Taille de la fenêtre FFT. Doit être une puissance de deux : une valeur plus grande
    /// donne une résolution fréquentielle plus fine mais une réponse plus lente dans le temps.
    var fftSize: Int = 4096

    /// Tailles de FFT proposées à l'utilisateur (toutes des puissances de deux).
    static let availableFFTSizes = [1024, 2048, 4096, 8192, 16384]

    /// Copie en valeurs simples, utilisée par le code d'analyse audio (hors main actor).
    /// Une copie évite de partager l'objet observable avec le thread audio.
    var analysisConfig: SpectrumConfig {
        SpectrumConfig(
            fftSize: fftSize,
            numberOfBands: numberOfBands,
            minFrequency: minFrequency,
            maxFrequency: maxFrequency,
            minDecibels: minDecibels,
            maxDecibels: maxDecibels
        )
    }

    /// Rétablit tous les paramètres à leurs valeurs par défaut.
    func reset() {
        minFrequency = 30
        maxFrequency = 20_000
        displayStyle = .bars
        numberOfBands = 32
        minDecibels = -160
        maxDecibels = 0
        attack = 0.6
        release = 0.15
        fftSize = 4096
    }
}
