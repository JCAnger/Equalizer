import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            // Le Mac joue la musique et sert de source de référence.
            ReferenceSourceView()
                .tint(AppTheme.accent)
            #else
            RootView()
                .tint(AppTheme.accent)
            #endif
        }
    }
}
