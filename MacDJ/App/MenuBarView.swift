import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Mode") {
            ForEach(AudioMode.allCases, id: \.self) { mode in
                Toggle(mode.label, isOn: Binding(
                    get: { appState.currentMode == mode },
                    set: { isOn in
                        if isOn { appState.switchMode(to: mode) }
                    }
                ))
            }
        }

        Divider()

        if !appState.isBlackHoleInstalled {
            Button("Setup Guide...") {
                openWindow(id: "onboarding")
                NSApp.activate()
            }
            Button("Rescan Audio Devices") {
                appState.rescanForBlackHole()
            }
            Divider()
        }

        if let error = appState.errorMessage {
            Text(error)
            Divider()
        }

        SettingsLink {
            Text("Settings...")
        }

        Divider()

        Button("Quit MacDJ") {
            appState.teardown()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
