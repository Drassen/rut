import SwiftUI

@main
struct RutApp: App {
    @StateObject private var core = CoreServices.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(core)
                .environmentObject(core.navStore)
                .environmentObject(core.toastManager)
                .preferredColorScheme(.dark)
        }
    }
}
