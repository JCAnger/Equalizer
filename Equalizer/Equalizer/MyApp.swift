import SwiftUI

@main struct MyApp: App {
    #if !os(macOS)
    @State private var isSplashVisible = true
    #endif

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            ContentView()
                .tint(AppTheme.accent)
            #else
            ZStack {
                ContentView()
                if isSplashVisible {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .tint(AppTheme.accent)
            .task {
                // Une annulation (scène fermée) interrompt simplement l'attente.
                try? await Task.sleep(for: SplashView.displayDuration)
                withAnimation(AppTheme.fade) { isSplashVisible = false }
            }
            #endif
        }
    }
}
