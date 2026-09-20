import SwiftUI
import UniformTypeIdentifiers

struct SoundboardView: View {
    @Environment(AppState.self) private var appState
    @State private var importing = false
    @State private var editing: SoundboardItem?

    var body: some View {
        @Bindable var board = appState.soundboard
        VStack(spacing: 12) {
            HStack {
                TextField("Search sounds", text: $board.searchText).textFieldStyle(.roundedBorder)
                Button { importing = true } label: { Label("Add Files", systemImage: "plus") }
                Button("Stop All", systemImage: "stop.fill", action: board.stopAll).disabled(!board.isPlaying)
                Menu {
                    Button("Open Soundboard Folder", action: board.openFolder)
                    Button("Refresh Sounds", action: board.refresh)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Soundboard options")
            }
            if board.filteredSounds.isEmpty {
                ContentUnavailableView(board.sounds.isEmpty ? "No sounds yet" : "No matching sounds", systemImage: "square.grid.2x2", description: Text(board.sounds.isEmpty ? "Add clips, then click to play. Sounds can overlap." : "Try a different search."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(board.filteredSounds) { sound in
                            VStack(spacing: 8) {
                                Button {
                                    board.play(sound, sendToCall: appState.isSharing, virtualMicDeviceID: appState.blackHoleDeviceID)
                                } label: {
                                    VStack(spacing: 10) {
                                        Text(sound.emoji).font(.system(size: 30)).accessibilityHidden(true)
                                        Text(sound.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 100)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(appState.phase == .starting)
                                .accessibilityLabel("Play \(sound.name)")
                                HStack {
                                    Label(board.playingSoundIDs.contains(sound.id) ? "Playing" : "Play clip", systemImage: board.playingSoundIDs.contains(sound.id) ? "speaker.wave.2.fill" : "play.fill")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { editing = sound } label: { Image(systemName: "pencil") }
                                        .buttonStyle(.borderless).accessibilityLabel("Edit \(sound.name)")
                                }
                            }
                            .padding(12)
                            .background(board.playingSoundIDs.contains(sound.id) ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .contextMenu {
                                Button("Edit Label…") { editing = sound }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sound.url]) }
                            }
                        }
                    }
                    .padding(1)
                }
            }
            HStack {
                if let error = board.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                } else { Text(board.statusMessage).foregroundStyle(.secondary) }
                Spacer()
            }
            .font(.callout)
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): board.importFiles(urls)
            case .failure(let error): board.lastErrorMessage = error.localizedDescription
            }
        }
        .sheet(item: $editing) { sound in
            AudioLabelEditor(title: "Edit Sound", name: sound.name, emoji: sound.emoji, reset: { board.clearMetadata(for: sound) }, save: { board.updateMetadata(for: sound, name: $0, emoji: $1) })
        }
    }
}

struct AudioLabelEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var name: String
    @State var emoji: String
    let reset: () -> Void
    let save: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Emoji", text: $emoji)
            }
            Text("Labels change here; your audio file keeps its original name.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reset Label") { reset(); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(name, emoji); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 410)
    }
}
