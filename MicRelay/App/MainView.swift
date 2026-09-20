import SwiftUI

private enum RelayTab: String, CaseIterable {
    case music = "Music", library = "Library", soundboard = "Soundboard"
}

struct MainView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("hasSeenSetup") private var hasSeenSetup = false
    @State private var showingSetup = false
    @State private var tab = RelayTab.music

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(appState.statusText, systemImage: appState.isSharing ? "dot.radiowaves.left.and.right" : "speaker.wave.2")
                        .font(.title3.weight(.semibold))
                    Text(appState.isSharing ? "New playback goes to your speakers and the call." : "Library and Soundboard play on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: share) {
                    Label(buttonTitle, systemImage: appState.phase == .starting ? "xmark" : appState.isSharing ? "stop.fill" : "play.fill")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(20)

            if let error = appState.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Setup") { showingSetup = true }
                    Button { appState.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
                .padding(12).background(.orange.opacity(0.08)).padding(.horizontal, 20).padding(.bottom, 12)
            }

            Picker("Content", selection: $tab) {
                ForEach(RelayTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 12)

            Group {
                switch tab {
                case .music: MusicView()
                case .library: LibraryView()
                case .soundboard: SoundboardView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Label(appState.isBlackHoleInstalled ? "BlackHole 2ch ready" : "BlackHole 2ch needed for calls", systemImage: appState.isBlackHoleInstalled ? "checkmark.circle" : "exclamationmark.circle")
                Spacer()
                Button("Setup & Slack Help") { showingSetup = true }
                    .buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(minWidth: 620, minHeight: 560)
        .toolbar {
            Button { showingSetup = true } label: { Label("Setup & Help", systemImage: "gearshape") }
                .help("Permissions, BlackHole, and Slack setup")
        }
        .sheet(isPresented: $showingSetup, onDismiss: { hasSeenSetup = true }) {
            OnboardingView()
        }
        .onAppear { showingSetup = !hasSeenSetup }
        .task {
            if appState.screenCapturePermissionGranted { await appState.findMusicApps() }
        }
    }

    private var buttonTitle: String {
        if appState.phase == .starting { return "Cancel" }
        if appState.isSharing { return "Stop Sharing" }
        return appState.isBlackHoleInstalled ? "Start Sharing" : "Set Up Audio"
    }

    private func share() {
        if appState.isBlackHoleInstalled { appState.toggleSharing() }
        else { showingSetup = true }
    }
}

private struct MusicView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section {
                HStack {
                    Picker("Music app", selection: $state.selectedMusicBundleID) {
                        Text("None — share files only").tag("")
                        if !appState.selectedMusicBundleID.isEmpty && appState.selectedMusicSource == nil {
                            Text("Selected app unavailable").tag(appState.selectedMusicBundleID)
                        }
                        ForEach(appState.musicSources) { source in Text(source.name).tag(source.bundleIdentifier) }
                    }
                    Button { Task { await appState.findMusicApps() } } label: {
                        Label(appState.screenCapturePermissionGranted ? "Refresh" : "Find Apps", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isFindingApps)
                }
                if !appState.screenCapturePermissionGranted {
                    Text("Find Apps asks macOS for Screen & System Audio Recording access. Only your selected app's audio is captured.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                volume("Music volume", value: $state.musicVolume)
                    .disabled(appState.selectedMusicBundleID.isEmpty)
            } header: { Text("Music") } footer: {
                Text("Keep your music app playing. Starting sharing leaves the call's speaker output unchanged.")
            }

            Section("Your voice") {
                Toggle("Include microphone", isOn: $state.includeMicrophone)
                if appState.includeMicrophone {
                    Picker("Microphone", selection: $state.selectedMicrophoneID) {
                        if appState.microphoneSources.isEmpty { Text("No microphone available").tag("") }
                        ForEach(appState.microphoneSources) { mic in Text(mic.name).tag(mic.id) }
                    }
                    volume("Microphone volume", value: $state.microphoneVolume)
                }
            }

            Section {
                HStack(spacing: 20) {
                    SignalMeter(title: "Music", value: appState.levels.music)
                    SignalMeter(title: "Microphone", value: appState.levels.microphone)
                    SignalMeter(title: "To BlackHole", value: appState.levels.output)
                }
                Label("Mix is clipping. Lower the music or microphone volume.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .opacity(appState.levels.output > 1 ? 1 : 0)
                    .accessibilityHidden(appState.levels.output <= 1)
            } header: { Text("Live app + microphone signal") } footer: {
                Text("If To BlackHole moves but Slack fades or cuts the music, turn off Slack's noise suppression and automatic gain control. See Setup & Slack Help.")
            }
        }
        .formStyle(.grouped)
    }

    private func volume(_ title: String, value: Binding<Float>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Slider(value: value, in: 0...1).frame(maxWidth: 230).accessibilityLabel(title)
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }
}

private struct SignalMeter: View {
    let title: String
    let value: Float
    private var decibels: Float { 20 * log10(max(value, 0.000001)) }
    private var reading: String { value > 0.000001 ? "\(Int(decibels)) dB" : "Silent" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(reading).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(max(0, min(1, (decibels + 60) / 60))))
                .tint(value > 1 ? .orange : .accentColor)
                .accessibilityLabel(title)
                .accessibilityValue(reading)
        }
    }
}
