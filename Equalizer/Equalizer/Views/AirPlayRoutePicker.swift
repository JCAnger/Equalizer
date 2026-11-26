#if os(iOS)
import SwiftUI
import AVKit

/// Bouton système qui permet de choisir la sortie AirPlay / Bluetooth.
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        // Blanc dans les deux états : le sélecteur est posé sur un bouton rond coloré.
        picker.tintColor = .white
        picker.activeTintColor = .white
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
