import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCommand = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ready for your next huddle").font(.title2.weight(.semibold))
                Text("Connect Mic Relay to your call once. Your music, voice, and sound clips can then share one microphone.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)

            Form {
                Section {
                    HStack {
                        Label(appState.isBlackHoleInstalled ? "BlackHole 2ch is installed" : "Install BlackHole 2ch", systemImage: appState.isBlackHoleInstalled ? "checkmark.circle.fill" : "1.circle")
                        Spacer()
                        Button("Check Again") { appState.refreshDevices() }
                    }
                    if !appState.isBlackHoleInstalled {
                        Text("BlackHole is the free virtual microphone that your call app listens to.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Link("Download BlackHole", destination: URL(string: "https://existential.audio/blackhole/")!)
                            Spacer()
                            Button(copiedCommand ? "Copied" : "Copy Homebrew Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install blackhole-2ch", forType: .string)
                                copiedCommand = true
                            }
                        }
                        Text("After installation, restart your Mac if BlackHole does not appear. You can use Library and Soundboard locally in the meantime.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } header: { Text("1. Connect to your call") }

                Section {
                    HStack {
                        Label(appState.screenCapturePermissionGranted ? "App audio access is ready" : "Allow app audio", systemImage: appState.screenCapturePermissionGranted ? "checkmark.circle.fill" : "app.badge")
                        Spacer()
                        Button(appState.screenCapturePermissionGranted ? "Refresh Apps" : "Allow Access") {
                            Task { await appState.findMusicApps() }
                        }
                        .disabled(appState.isFindingApps)
                        Button("Open Settings") { appState.openPrivacySettings() }
                    }
                    Text("In Screen & System Audio Recording, allow Mic Relay. If macOS requests a relaunch, quit and reopen the app, then refresh apps. No screen video is saved.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("This access is only needed for another app's audio. Library and Soundboard work without it.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = appState.errorMessage, !appState.screenCapturePermissionGranted {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        Label(microphoneTitle, systemImage: appState.microphonePermissionGranted ? "checkmark.circle.fill" : "mic")
                        Spacer()
                        if appState.microphoneAuthorization == .denied || appState.microphonePermissionGranted {
                            Button("Microphone Settings") { appState.openPrivacySettings(microphone: true) }
                        }
                    }
                    Text(microphoneGuidance)
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Accessibility permission is not required.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("2. Allow only what you need") }

                Section {
                    LabeledContent("Microphone", value: "BlackHole 2ch")
                    LabeledContent("Speaker", value: "Your headphones or speakers")
                    Text("For Slack: open Preferences → Audio & video. Turn off noise suppression and automatic gain control so Slack does not treat music as background noise or keep changing its volume.")
                        .font(.callout)
                    Link("Slack audio settings guide", destination: URL(string: "https://slack.com/help/articles/1500002037922-Adjust-your-huddles-preferences")!)
                    Text("Start sharing in Mic Relay and play some music. Check Slack's microphone meter. Keep the huddle unmuted, and don't select Slack or the browser carrying your call as the music source.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("3. Set up Slack or another call app") }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("You can return here from Setup & Help.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 610, height: 650)
        .onAppear { appState.refreshDevices(); appState.refreshPermissions() }
    }

    private var microphoneTitle: String {
        switch appState.microphoneAuthorization {
        case .authorized: "Microphone access is ready"
        case .denied: "Microphone access is off"
        case .restricted: "Microphone access is restricted"
        default: "Microphone is optional"
        }
    }

    private var microphoneGuidance: String {
        switch appState.microphoneAuthorization {
        case .denied:
            "Allow Mic Relay in Microphone Settings to add your voice, or leave Include microphone off. macOS will not ask again after a denial."
        case .restricted:
            "A system policy restricts microphone access. Contact your administrator, or leave Include microphone off."
        case .authorized:
            "Enable Include microphone in Music to add your voice. Microphone permission is already granted."
        default:
            "Enable Include microphone in Music when you want to add your voice. Mic Relay asks for access when you start sharing with it enabled."
        }
    }
}
