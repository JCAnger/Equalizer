import SwiftUI

struct ContentView: View {
    @State private var settings = SpectrumSettings()
    @State private var analyzer: AudioSpectrumAnalyzer?
    @State private var reference: ReferenceReceiver?
    @State private var showingSettings = false
    @State private var showingAnalysis = false

    var body: some View {
        SpectrumView(
            levels: analyzer?.bandLevels ?? [],
            referenceLevels: reference?.liveLevels ?? [],
            settings: settings
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button(analyzer?.isRunning == true ? "Arrêter" : "Démarrer") {
                    toggleCapture()
                }
                .glassProminentButtonStyle()
                .controlSize(.large)
                .padding(.leading, 44)
                .padding(.top, 8)
            }
            .overlay(alignment: .topTrailing) {
                HStack {
                    Button {
                        showingAnalysis = true
                    } label: {
                        Image(systemName: "waveform.badge.magnifyingglass")
                    }
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                .glassButtonStyle()
                .controlSize(.large)
                .padding(.trailing, 8)
                .padding(.top, 8)
            }
            .overlay(alignment: .bottom) {
                if let message = analyzer?.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassSurface(in: .capsule)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 8)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(settings: settings)
            }
            .sheet(isPresented: $showingAnalysis) {
                if let analyzer, let reference {
                    ResponseAnalysisView(analyzer: analyzer, reference: reference, settings: settings)
                }
            }
            .onAppear {
                if analyzer == nil {
                    analyzer = AudioSpectrumAnalyzer(settings: settings)
                    reference = ReferenceReceiver(settings: settings)
                }
                reference?.startBrowsing()
            }
            .onDisappear {
                analyzer?.stop()
                reference?.stopBrowsing()
            }
    }

    private func toggleCapture() {
        guard let analyzer else { return }
        if analyzer.isRunning {
            analyzer.stop()
        } else {
            analyzer.start()
        }
    }
}

#Preview {
    ContentView()
}
