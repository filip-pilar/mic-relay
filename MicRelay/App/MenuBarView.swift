import CoreAudio
import SwiftUI

private enum MicRelayTab: String, CaseIterable, Identifiable {
    case stream = "Stream"
    case library = "Library"
    case soundboard = "Soundboard"
    case config = "Config"

    var id: Self { self }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: MicRelayTab = .stream
    @State private var includeMicrophone = true
    @State private var editingSound: SoundboardItem?
    @State private var draftSoundName = ""
    @State private var draftSoundEmoji = ""
    @State private var editingLibraryTrack: LibraryTrack?
    @State private var draftTrackTitle = ""
    @State private var draftTrackEmoji = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tabPicker

            Group {
                switch selectedTab {
                case .stream:
                    streamTab
                case .soundboard:
                    soundboardTab
                case .library:
                    libraryTab
                case .config:
                    configTab
                }
            }
            .frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)

            footer
        }
        .padding(16)
        .frame(width: 410, height: 540, alignment: .top)
    }

    private var soundboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RowHeader(title: "Soundboard", systemImage: "square.grid.2x2")
                Spacer()
                StatusBadge(
                    text: appState.soundboard.isPlaying ? "Playing" : (appState.sendToCall ? "Call" : "Preview"),
                    systemImage: appState.soundboard.isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2",
                    color: appState.soundboard.isPlaying || appState.sendToCall ? .green : .secondary
                )
            }

            HStack(spacing: 8) {
                Button {
                    appState.soundboard.openFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open Soundboard folder")

                Button {
                    appState.soundboard.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh sounds")

                Button {
                    appState.soundboard.stopAll()
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .disabled(!appState.soundboard.isPlaying)
                .help("Stop all sounds")
            }
            .controlSize(.small)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Search", text: Binding(
                    get: { appState.soundboard.searchText },
                    set: { appState.soundboard.searchText = $0 }
                ))
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            soundboardContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 222, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.soundboard.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let error = appState.soundboard.lastErrorMessage {
                    StatusNote(text: error, color: .red)
                } else {
                    Text(appState.sendToCall ? "Clips also go to the call." : "Clips preview locally only.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(height: 34, alignment: .topLeading)
        }
    }

    private var libraryTab: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                RowHeader(title: "Library", systemImage: "music.note.list")
                Spacer()
                StatusBadge(
                    text: appState.library.isDownloading ? "Downloading" : (appState.library.isPlaying ? "Playing" : (appState.sendToCall ? "Call" : "Preview")),
                    systemImage: appState.library.isDownloading ? "arrow.down.circle.fill" : (appState.library.isPlaying ? "play.circle.fill" : "music.note"),
                    color: appState.library.isDownloading ? .blue : (appState.library.isPlaying || appState.sendToCall ? .green : .secondary)
                )
            }

            HStack(spacing: 8) {
                TextField("YouTube URL", text: Binding(
                    get: { appState.library.importURLText },
                    set: { appState.library.importURLText = $0 }
                ))
                .textFieldStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(appState.library.isDownloading)

                Button {
                    appState.library.startDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(appState.library.isDownloading || appState.library.importURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Download user-supplied audio")
            }
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(appState.library.statusMessage)
                        .font(.caption)
                        .foregroundStyle(appState.library.lastErrorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .lineLimit(1)
                    Spacer()
                    if appState.library.isDownloading {
                        Button {
                            appState.library.cancelDownload()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Cancel download")
                    }
                }

                if appState.library.isDownloading {
                    if let progress = appState.library.downloadProgress {
                        ProgressView(value: progress, total: 1)
                    } else {
                        ProgressView()
                    }
                } else {
                    ProgressView(value: 0, total: 1)
                        .opacity(0)
                }
            }
            .frame(height: 28, alignment: .topLeading)

            HStack(spacing: 8) {
                Picker("Source", selection: Binding(
                    get: { appState.library.selectedSourceID },
                    set: { appState.library.selectedSourceID = $0 }
                )) {
                    ForEach(appState.library.sourceFilters) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    TextField("Search", text: Binding(
                        get: { appState.library.searchText },
                        set: { appState.library.searchText = $0 }
                    ))
                    .textFieldStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    appState.library.openFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open Library folder")

                Button {
                    appState.library.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh library")
            }
            .controlSize(.small)

            libraryContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 152, alignment: .topLeading)

            libraryTransport
                .frame(height: 84, alignment: .bottomLeading)
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        let tracks = appState.library.filteredTracks
        if tracks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: appState.library.tracks.isEmpty ? "folder.badge.plus" : "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(appState.library.tracks.isEmpty ? "No tracks yet." : "No matches.")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(appState.library.tracks.isEmpty ? "Add audio files or paste a YouTube URL." : "Try a shorter search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(tracks) { track in
                        libraryTrackRow(for: track)
                        .popover(
                            isPresented: libraryPopoverBinding(for: track),
                            arrowEdge: .trailing
                        ) {
                            libraryTrackEditor(for: track)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func libraryTrackRow(for track: LibraryTrack) -> some View {
        LibraryTrackRow(
            track: track,
            isSelected: appState.library.nowPlayingTrackID == track.id,
            playAction: {
                appState.refreshAudioDevices()
                appState.library.play(
                    track,
                    sendToCall: appState.sendToCall,
                    virtualMicDeviceID: virtualMicDeviceID
                )
            },
            editAction: {
                beginEditing(track)
            }
        )
    }

    private func libraryPopoverBinding(for track: LibraryTrack) -> Binding<Bool> {
        Binding(
            get: { editingLibraryTrack?.id == track.id },
            set: { isPresented in
                if !isPresented {
                    editingLibraryTrack = nil
                }
            }
        )
    }

    private var libraryTransport: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(appState.library.nowPlayingTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text("\(formatTime(appState.library.playbackTime)) / \(formatTime(appState.library.playbackDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { appState.library.playbackTime },
                    set: { appState.library.setScrubTime($0) }
                ),
                in: 0...max(appState.library.playbackDuration, 1),
                onEditingChanged: { editing in
                    if !editing {
                        appState.library.finishScrubbing()
                    }
                }
            )
            .disabled(!appState.library.hasCurrentTrack)

            HStack(spacing: 10) {
                transportButton(systemImage: "backward.fill", help: "Previous") {
                    appState.refreshAudioDevices()
                    appState.library.playPrevious(
                        sendToCall: appState.sendToCall,
                        virtualMicDeviceID: virtualMicDeviceID
                    )
                }

                transportButton(systemImage: appState.library.isPlaying ? "pause.fill" : "play.fill", help: "Play/Pause") {
                    appState.refreshAudioDevices()
                    appState.library.togglePlayPause(
                        sendToCall: appState.sendToCall,
                        virtualMicDeviceID: virtualMicDeviceID
                    )
                }

                transportButton(systemImage: "stop.fill", help: "Stop") {
                    appState.library.stop()
                }
                .disabled(!appState.library.hasCurrentTrack)

                transportButton(systemImage: "forward.fill", help: "Next") {
                    appState.refreshAudioDevices()
                    appState.library.playNext(
                        sendToCall: appState.sendToCall,
                        virtualMicDeviceID: virtualMicDeviceID
                    )
                }

                Spacer()

                if let error = appState.library.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text(appState.sendToCall ? "Playback also goes to the call." : "Previewing locally only.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func transportButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .help(help)
    }

    @ViewBuilder
    private var soundboardContent: some View {
        let sounds = appState.soundboard.filteredSounds
        if sounds.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: appState.soundboard.sounds.isEmpty ? "folder.badge.plus" : "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(appState.soundboard.sounds.isEmpty ? "No sounds yet." : "No matches.")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(appState.soundboard.sounds.isEmpty ? "Open the folder and add MP3, M4A, WAV, AIFF, or CAF files." : "Try a shorter search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(sounds) { sound in
                        SoundButton(
                            sound: sound,
                            isPlaying: appState.soundboard.playingSoundIDs.contains(sound.id),
                            canPlay: true,
                            playAction: {
                                appState.refreshAudioDevices()
                                appState.soundboard.play(
                                    sound,
                                    sendToCall: appState.sendToCall,
                                    virtualMicDeviceID: virtualMicDeviceID
                                )
                            },
                            editAction: {
                                beginEditing(sound)
                            }
                        )
                        .popover(
                            isPresented: Binding(
                                get: { editingSound?.id == sound.id },
                                set: { isPresented in
                                    if !isPresented {
                                        editingSound = nil
                                    }
                                }
                            ),
                            arrowEdge: .trailing
                        ) {
                            soundEditor(for: sound)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func beginEditing(_ sound: SoundboardItem) {
        editingSound = sound
        draftSoundName = sound.name
        draftSoundEmoji = sound.emoji
    }

    private func soundEditor(for sound: SoundboardItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sound")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("🙂", text: $draftSoundEmoji)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .frame(width: 44)

                TextField("Name", text: $draftSoundName)
                    .frame(width: 180)
            }

            HStack {
                Button("Reset") {
                    appState.soundboard.clearMetadata(for: sound)
                    editingSound = nil
                }
                .controlSize(.small)

                Spacer()

                Button("Save") {
                    appState.soundboard.updateMetadata(
                        for: sound,
                        name: draftSoundName,
                        emoji: draftSoundEmoji
                    )
                    editingSound = nil
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func beginEditing(_ track: LibraryTrack) {
        editingLibraryTrack = track
        draftTrackTitle = track.title
        draftTrackEmoji = track.emoji
    }

    private func libraryTrackEditor(for track: LibraryTrack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Track")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("🎵", text: $draftTrackEmoji)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .frame(width: 44)

                TextField("Title", text: $draftTrackTitle)
                    .frame(width: 210)
            }

            HStack {
                Button("Reset") {
                    appState.library.clearMetadata(for: track)
                    editingLibraryTrack = nil
                }
                .controlSize(.small)

                Spacer()

                Button("Save") {
                    appState.library.updateMetadata(
                        for: track,
                        title: draftTrackTitle,
                        emoji: draftTrackEmoji
                    )
                    editingLibraryTrack = nil
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 310)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
        }
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Mic Relay")
                    .font(.headline)
                Text(appState.sendToCall ? "Call output armed" : "Local preview only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Send to Call", isOn: Binding(
                get: { appState.sendToCall },
                set: { appState.setSendToCall($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!appState.isBlackHoleInstalled)
            .help("Allow Mic Relay to send audio to BlackHole")
        }
    }

    private var virtualMicDeviceID: AudioDeviceID? {
        guard appState.sendToCall else { return nil }
        return appState.audioManager.findDevice(byUID: MicRelayConstants.blackHoleUID)
    }

    private var tabPicker: some View {
        Picker("Mode", selection: $selectedTab) {
            ForEach(MicRelayTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    private var streamTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sendSection
            sourceSection
            streamStatusSection
            Spacer(minLength: 0)
        }
    }

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Stream")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(appState.isRouting ? "Sending selected app audio to call." : "Off unless you start it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("App Stream", isOn: Binding(
                    get: { appState.isRouting },
                    set: { appState.setRouting($0, includeMicrophone: includeMicrophone) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!appState.sendToCall || !appState.isBlackHoleInstalled)
            }

            if let error = appState.errorMessage {
                StatusNote(text: error, color: .red)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            RowHeader(title: "Audio Source", systemImage: "app.connected.to.app.below.fill")

            HStack(spacing: 8) {
                Picker("Audio Source", selection: Binding(
                    get: { appState.selectedMusicSource },
                    set: { appState.selectedMusicSource = $0 }
                )) {
                    if appState.musicSources.isEmpty {
                        Text("No app selected").tag(nil as MusicSource?)
                    }
                    ForEach(appState.musicSources) { source in
                        Text(source.isSpotify ? "\(source.name) (Spotify)" : source.name)
                            .tag(Optional(source))
                    }
                }
                .labelsHidden()

                Button {
                    appState.refreshMusicSources()
                } label: {
                    Label(appState.musicSources.isEmpty ? "Find Apps" : "Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh apps")
            }

            HStack {
                Text(sourceStatusText)
                    .font(.caption)
                    .foregroundStyle(sourceStatusColor)
                    .lineLimit(1)

                Spacer()

                if !appState.screenCapturePermissionGranted {
                    Button("Permissions") {
                        appState.openScreenCaptureSettings()
                    }
                    .controlSize(.small)
                }
            }
            .frame(height: 22, alignment: .leading)
        }
    }

    private var streamStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusBadge(
                    text: appState.sendToCall ? "Call armed" : "Preview only",
                    systemImage: appState.isRouting ? "dot.radiowaves.left.and.right" : "circle",
                    color: appState.sendToCall ? .green : .secondary
                )

                StatusBadge(
                    text: appState.isRouting ? (includeMicrophone ? "Mic included" : "Music only") : "Stream off",
                    systemImage: includeMicrophone ? "mic.fill" : "music.note",
                    color: .secondary
                )
            }

            Text(appState.sendToCall ? "Library and Soundboard also send to the call." : "Library and Soundboard play locally while Send to Call is off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var sourceStatusText: String {
        if let source = appState.selectedMusicSource {
            return "Capturing \(source.name)."
        }
        if appState.musicSources.isEmpty {
            return "Open Spotify or another app, then find apps."
        }
        return "Choose an app to stream."
    }

    private var sourceStatusColor: Color {
        appState.selectedMusicSource == nil ? .orange : .secondary
    }

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            RowHeader(title: "Microphone", systemImage: "mic")

            Picker("Microphone", selection: Binding(
                get: { appState.selectedMicrophoneID },
                set: { appState.selectedMicrophoneID = $0 }
            )) {
                if appState.microphoneSources.isEmpty {
                    Text("No microphone found").tag(nil as String?)
                }
                ForEach(appState.microphoneSources) { microphone in
                    Text(microphone.isDefault ? "\(microphone.name) (Default)" : microphone.name)
                        .tag(Optional(microphone.id))
                }
            }
            .labelsHidden()

            Toggle("Include microphone", isOn: Binding(
                get: { includeMicrophone },
                set: { newValue in
                    includeMicrophone = newValue
                    appState.setMicrophoneIncluded(newValue)
                }
            ))
            .toggleStyle(.checkbox)
        }
    }

    private var configTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                RowHeader(title: "Config", systemImage: "slider.horizontal.3")
                Spacer()
                StatusBadge(
                    text: appState.isBlackHoleInstalled ? "Ready" : "Setup",
                    systemImage: appState.isBlackHoleInstalled ? "checkmark.circle.fill" : "xmark.circle.fill",
                    color: appState.isBlackHoleInstalled ? .green : .red
                )
            }

            sendToCallSection
            statusSection
            microphoneSection
            signalSection

            VStack(alignment: .leading, spacing: 6) {
                RowHeader(title: "Routing", systemImage: "point.3.connected.trianglepath.dotted")
                Text("Mic Relay sends audio to BlackHole 2ch. Keep call output on headphones or speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var sendToCallSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    RowHeader(title: "Send to Call", systemImage: "antenna.radiowaves.left.and.right")
                    Text(appState.sendToCall ? "Library, Soundboard, and Stream can reach BlackHole." : "Library and Soundboard preview locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Send to Call", isOn: Binding(
                    get: { appState.sendToCall },
                    set: { appState.setSendToCall($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!appState.isBlackHoleInstalled)
            }

            if !appState.isBlackHoleInstalled {
                StatusNote(text: "Install BlackHole 2ch to send audio into calls.", color: .orange)
            }
        }
    }

    private var signalSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                RowHeader(title: "Stream Signal", systemImage: "waveform")
                Spacer()
                StatusBadge(
                    text: appState.isRouting ? "Live" : "Stream off",
                    systemImage: appState.isRouting ? "circle.fill" : "circle",
                    color: appState.isRouting ? .green : .secondary
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                LevelMeter(label: "App", value: appState.isRouting ? appState.levels.music : 0)
                LevelMeter(label: "Mic", value: appState.isRouting && includeMicrophone ? appState.levels.microphone : 0)
                LevelMeter(label: "Out", value: appState.isRouting ? appState.levels.output : 0)
            }
            .opacity(appState.isRouting ? 1 : 0.45)

            Text(appState.isRouting ? "Selected app stream level." : "Meters appear while App Stream is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 16, alignment: .leading)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusBadge(
                    text: appState.isBlackHoleInstalled ? "BlackHole installed" : "BlackHole missing",
                    systemImage: appState.isBlackHoleInstalled ? "checkmark.circle.fill" : "xmark.circle.fill",
                    color: appState.isBlackHoleInstalled ? .green : .red
                )

                Button {
                    appState.rescanAudioDevices()
                } label: {
                    Label("Rescan", systemImage: "dot.radiowaves.left.and.right")
                }
                .controlSize(.small)

                if !appState.isBlackHoleInstalled {
                    Button("Setup") {
                        openWindow(id: "onboarding")
                        NSApp.activate()
                    }
                    .controlSize(.small)
                }
            }

            Text(appState.audioStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                appState.teardown()
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Mic Relay")
        }
    }

    private var footerText: String {
        switch selectedTab {
        case .stream:
            appState.sendToCall ? (appState.isRouting ? "App audio is going to the call." : "Start App Stream to send selected app audio.") : "Send to Call is off. App audio stays private."
        case .soundboard:
            appState.sendToCall ? "Clips play locally and to the call." : "Clips preview locally only."
        case .library:
            appState.sendToCall ? "Tracks play locally and to the call." : "Tracks preview locally only."
        case .config:
            appState.sendToCall ? "Call output is armed." : "Call output is off."
        }
    }
}

private struct RowHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .fontWeight(.semibold)
    }
}

private struct StatusBadge: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct StatusNote: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SoundButton: View {
    let sound: SoundboardItem
    let isPlaying: Bool
    let canPlay: Bool
    let playAction: () -> Void
    let editAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: playAction) {
                HStack(spacing: 8) {
                    Text(sound.emoji)
                        .font(.title3)
                        .frame(width: 24)

                    Text(sound.name)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help(sound.filename)

            Button(action: editAction) {
                EditGlyph()
            }
            .buttonStyle(.plain)
            .help("Name sound")
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(isPlaying ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct LibraryTrackRow: View {
    let track: LibraryTrack
    let isSelected: Bool
    let playAction: () -> Void
    let editAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: playAction) {
                HStack(spacing: 8) {
                    Text(track.emoji)
                        .font(.title3)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.callout)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let playlistName = track.playlistName {
                            Text(playlistName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .help(track.filename)

            Button(action: editAction) {
                EditGlyph()
            }
            .buttonStyle(.plain)
            .help("Name track")
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(isSelected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct EditGlyph: View {
    var body: some View {
        Image(systemName: "square.and.pencil")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct LevelMeter: View {
    let label: String
    let value: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.16))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(value > 0.85 ? Color.red : Color.accentColor)
                        .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 7)
        }
        .frame(height: 12)
    }
}
