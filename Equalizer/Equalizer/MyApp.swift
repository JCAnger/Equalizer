import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            // The Mac plays the music and acts as the reference source.
            ReferenceSourceView()
                .tint(AppTheme.accent)
            #else
            RootView()
                .tint(AppTheme.accent)
            #endif
        }
    }
}
