import SwiftUI

/// Écran principal : le spectre capté par le micro (ouvert dès le lancement) avec, derrière,
/// le bruit généré. Les commandes sont regroupées dans un panneau en bas, à portée du pouce.
struct ContentView: View {
    @State private var settings = SpectrumSettings()
    // Créée dans `onAppear` : elle dépend de `settings`, qui n'existe pas encore à l'initialisation des propriétés.
    @State private var session: MeasurementSession?
    @State private var showingSettings = false
    @State private var showingAnalysis = false

    var body: some View {
        VStack(spacing: 0) {
            SpectrumView(
                levels: session?.analyzer.bandLevels ?? [],
                referenceLevels: session?.generator.liveLevels ?? [],
                settings: settings
            )
            .ignoresSafeArea(edges: .top)

            if let session {
                MeasurementControls(
                    session: session,
                    onShowAnalysis: { showingAnalysis = true },
                    onShowSettings: { showingSettings = true }
                )
                .padding(.horizontal, 16)
                // Descend les touches de 8 pt dans la zone sûre, près de l'indicateur d'accueil.
                .padding(.bottom, -8)
            }
        }
        // Posée sur le conteneur et non sur le graphe, qui déborde sous la barre d'état :
        // la ligne reste ainsi dans la zone sûre, sous l'îlot dynamique.
        .overlay(alignment: .top) { infoBanners }
        .animation(AppTheme.fade, value: session?.generator.isPlaying)
        // Même fond sombre que le graphe, y compris derrière les commandes.
        .background { AppBackground().environment(\.colorScheme, .dark) }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: settings)
                .tallSheetSizing()
        }
        .sheet(isPresented: $showingAnalysis) {
            if let session {
                ResponseAnalysisView(session: session, settings: settings)
                    .tallSheetSizing()
            }
        }
        .onAppear {
            // Ne crée la session et n'ouvre le micro qu'une fois : `onAppear` peut être rappelé
            // (retour d'une feuille, etc.).
            if session == nil {
                let newSession = MeasurementSession(settings: settings)
                session = newSession
                newSession.startListening()
            }
        }
        .onDisappear {
            session?.shutDown()
        }
    }

    /// Pastilles posées sur le graphe : la sortie audio utilisée (tant que le bruit joue, pour
    /// repérer un silence dû à une mauvaise sortie), puis le bruit choisi.
    @ViewBuilder
    private var infoBanners: some View {
        if let generator = session?.generator {
            VStack(spacing: 8) {
                #if os(iOS)
                if generator.isPlaying {
                    let outputName = generator.outputName ?? String(localized: "aucune")
                    banner(String(localized: "Sortie : \(outputName)"), color: .orange)
                        .transition(.opacity)
                }
                #endif
                banner(generator.signal?.title ?? String(localized: "Aucun bruit"), color: .white)
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassSurface(in: .capsule)
            // Le verre est posé sur le graphe, toujours sombre : on garde l'apparence sombre en mode clair.
            .environment(\.colorScheme, .dark)
    }
}

#Preview("Clair") {
    ContentView()
}

#Preview("Sombre") {
    ContentView()
        .preferredColorScheme(.dark)
}
