import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @State private var importing = false
    @State private var editing: LibraryTrack?

    var body: some View {
        @Bindable var library = appState.library
        VStack(spacing: 12) {
            HStack {
                Picker("Collection", selection: $library.selectedSourceID) {
                    ForEach(library.sourceFilters) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 190)
                TextField("Search library", text: $library.searchText).textFieldStyle(.roundedBorder)
                Button { importing = true } label: { Label("Add Files", systemImage: "plus") }
                Menu {
                    Button("Open Library Folder", action: library.openFolder)
                    Button("Refresh Library", action: library.refresh)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Library options")
            }
            HStack {
                TextField("Paste a video or playlist URL", text: $library.importURLText)
                    .textFieldStyle(.roundedBorder).disabled(library.isDownloading)
                    .onSubmit { library.startDownload() }
                if library.isDownloading {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: library.cancelDownload)
                } else {
                    Button("Download", action: library.startDownload)
                        .disabled(library.importURLText.nilIfBlank == nil)
                }
            }
            if library.isDownloading {
                Text(library.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let progress = library.downloadProgress { ProgressView(value: progress) }
            }

            if library.filteredTracks.isEmpty {
                ContentUnavailableView(library.tracks.isEmpty ? "No music yet" : "No matching tracks", systemImage: "music.note.list", description: Text(library.tracks.isEmpty ? "Add audio files or download a playlist to get started." : "Try another search or collection."))
                    .frame(maxHeight: .infinity)
            } else {
                List(library.filteredTracks) { track in
                    HStack(spacing: 12) {
                        Text(track.emoji).font(.title2).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).lineLimit(1)
                            if let playlist = track.playlistName { Text(playlist).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if library.nowPlayingTrackID == track.id {
                            Image(systemName: library.isPlaying ? "speaker.wave.2.fill" : "pause.fill").foregroundStyle(.tint)
                                .accessibilityLabel(library.isPlaying ? "Playing" : "Paused")
                        }
                        Button { play(track) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Play \(track.title)")
                        Button { editing = track } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).accessibilityLabel("Edit \(track.title)")
                    }
                    .padding(.vertical, 5).contentShape(Rectangle())
                    .onTapGesture(count: 2) { play(track) }
                    .contextMenu {
                        Button("Play") { play(track) }
                        Button("Edit Label…") { editing = track }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
                    }
                }
                .listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let error = library.lastErrorMessage { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
            LibraryTransportView()
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.importFiles(urls)
            case .failure(let error): library.lastErrorMessage = error.localizedDescription
            }
        }
        .sheet(item: $editing) { track in
            AudioLabelEditor(title: "Edit Track", name: track.title, emoji: track.emoji, reset: { library.clearMetadata(for: track) }, save: { library.updateMetadata(for: track, title: $0, emoji: $1) })
        }
    }

    private func play(_ track: LibraryTrack) {
        guard appState.phase != .starting else { return }
        appState.library.play(track, sendToCall: appState.isSharing, virtualMicDeviceID: appState.blackHoleDeviceID)
    }
}

private struct LibraryTransportView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let library = appState.library
        return VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.nowPlayingTitle).font(.headline).lineLimit(1)
                    Text("\(formatPlaybackTime(library.playbackTime)) / \(formatPlaybackTime(library.playbackDuration))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button { library.playPrevious(sendToCall: appState.isSharing, virtualMicDeviceID: appState.blackHoleDeviceID) } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("Previous track")
                Button { library.togglePlayPause(sendToCall: appState.isSharing, virtualMicDeviceID: appState.blackHoleDeviceID) } label: { Image(systemName: library.isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                    .disabled(!library.hasCurrentTrack && library.filteredTracks.isEmpty)
                    .accessibilityLabel(library.isPlaying ? "Pause" : "Play")
                Button { library.playNext(sendToCall: appState.isSharing, virtualMicDeviceID: appState.blackHoleDeviceID) } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("Next track")
                Button(action: library.stop) { Image(systemName: "stop.fill") }
                    .disabled(!library.hasCurrentTrack).accessibilityLabel("Stop playback")
            }
            Slider(value: Binding(get: { library.playbackTime }, set: { library.setScrubTime($0) }), in: 0...max(1, library.playbackDuration), onEditingChanged: { if !$0 { library.finishScrubbing() } })
                .disabled(!library.hasCurrentTrack).accessibilityLabel("Playback position")
                .accessibilityValue(formatPlaybackTime(library.playbackTime))
        }
        .disabled(appState.phase == .starting)
        .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

}

func formatPlaybackTime(_ time: TimeInterval) -> String {
    guard time.isFinite, time > 0 else { return "0:00" }
    let seconds = Int(time)
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
