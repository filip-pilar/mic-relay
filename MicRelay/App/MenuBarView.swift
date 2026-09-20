import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appState.statusText)
        Button(appState.phase == .stopped ? "Start Sharing" : "Stop Sharing") {
            if appState.isBlackHoleInstalled { appState.toggleSharing() }
            else { showWindow() }
        }
        Divider()
        Button("Open Mic Relay…", action: showWindow)
            .keyboardShortcut("o")
        Button("Quit Mic Relay") {
            appState.teardown()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
