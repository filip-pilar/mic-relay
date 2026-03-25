import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Cycle Mode:", name: .cycleMode)
                Text("Press the hotkey to cycle: Normal → Music + Voice → DJ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
            }

            Section("Audio Devices") {
                LabeledContent("Output") {
                    Text(appState.audioManager.getDeviceName(for: appState.savedOutputDeviceID) ?? "Unknown")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Input") {
                    Text(appState.audioManager.getDeviceName(for: appState.savedInputDeviceID) ?? "Unknown")
                        .foregroundStyle(.secondary)
                }
            }

            Section("BlackHole 2ch") {
                LabeledContent("Status") {
                    if appState.isBlackHoleInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Installed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if !appState.isBlackHoleInstalled {
                    Button("Install BlackHole...") {
                        NSWorkspace.shared.open(BlackHoleDetector.installURL)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                LabeledContent("MacDJ", value: "Routes music into voice calls")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 380)
        .onAppear {
            NSApp.activate()
        }
    }
}
