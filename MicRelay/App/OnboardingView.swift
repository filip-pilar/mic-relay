import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var copiedBrew = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "speaker.wave.2.bubble.left")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Mic Relay needs BlackHole 2ch")
                .font(.title2)
                .fontWeight(.semibold)

            Text("BlackHole is a free, open-source virtual audio driver. Mic Relay writes the mixed music and microphone signal to BlackHole, and your call app reads it as a microphone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()

            VStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BlackHoleDetector.brewCommand, forType: .string)
                    copiedBrew = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedBrew = false
                    }
                } label: {
                    Label(
                        copiedBrew ? "Copied to clipboard!" : "Copy Homebrew Command",
                        systemImage: copiedBrew ? "checkmark" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Text("`\(BlackHoleDetector.brewCommand)`")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    NSWorkspace.shared.open(BlackHoleDetector.installURL)
                } label: {
                    Label("Download from Website", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            Divider()

            Text("After installing, restart your Mac or run:\n`sudo killall -9 coreaudiod`\nThen select BlackHole 2ch as the microphone in your call app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("I've Installed It — Rescan") {
                appState.rescanAudioDevices()
                if appState.isBlackHoleInstalled {
                    dismiss()
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(width: 420)
    }
}
