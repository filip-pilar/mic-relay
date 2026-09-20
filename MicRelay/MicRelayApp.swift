import SwiftUI

@main
struct MicRelayApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("Mic Relay", id: "main") {
            MainView().environment(appState)
        }
        .defaultSize(width: 700, height: 600)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView().environment(appState)
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .accessibilityLabel(appState.statusText)
        }
        .menuBarExtraStyle(.menu)
    }
}
