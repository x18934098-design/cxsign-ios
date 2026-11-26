import SwiftUI

@main
@MainActor
struct ChaoxingSignerApp: App {
    @StateObject private var state = AppState()

    /// BGTaskScheduler 要求在 didFinishLaunching 之前完成注册
    init() {
        BackgroundSigning.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.store)
                .environmentObject(state.coordinator)
                .environmentObject(state.location)
                .onAppear {
                    state.location.refresh()
                    BackgroundSigning.shared.register()
                }
        }
    }
}