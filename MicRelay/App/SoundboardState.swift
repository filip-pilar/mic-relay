import AppKit
import CoreAudio
import Foundation

struct SoundboardItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let filename: String
    let emoji: String
    let modifiedAt: Date
}

@MainActor
@Observable
final class SoundboardState {
    var searchText = ""
    var sounds: [SoundboardItem] = []
    var playingSoundIDs: Set<String> = []
    var statusMessage = "Drop audio files into the folder."
    var lastErrorMessage: String?

    let folderURL: URL

    private let playbackEngine = FilePlaybackEngine()
    private let defaultEmoji = "🙂"
    private var playbackByID: [UUID: String] = [:]
    private var metadata = SoundboardMetadataFile()

    init(folderURL: URL? = nil) {
        self.folderURL = folderURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Mic Relay", isDirectory: true)
            .appendingPathComponent("Soundboard", isDirectory: true)
        refresh()
        playbackEngine.onInterruption = { [weak self] in
            self?.stopAll()
            self?.lastErrorMessage = "Audio output changed. Play a clip again to continue."
        }
    }

    var filteredSounds: [SoundboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sounds }
        return sounds.filter { sound in
            sound.name.localizedCaseInsensitiveContains(query) ||
            sound.filename.localizedCaseInsensitiveContains(query) ||
            sound.emoji.localizedCaseInsensitiveContains(query)
        }
    }

    var isPlaying: Bool {
        !playingSoundIDs.isEmpty
    }

    func importFiles(_ urls: [URL]) {
        do {
            try AudioFileSupport.importFiles(urls, into: folderURL)
            refresh()
        } catch {
            refresh()
            lastErrorMessage = error.localizedDescription
        }
    }

    func openFolder() {
        ensureFolder()
        NSWorkspace.shared.open(folderURL)
        statusMessage = "Folder opened."
    }

    func refresh() {
        lastErrorMessage = nil
        ensureFolder()
        loadMetadata()
        let discoveredSounds = discoverSounds()
        sounds = discoveredSounds
        playingSoundIDs = playingSoundIDs.intersection(Set(discoveredSounds.map(\.id)))
        statusMessage = discoveredSounds.isEmpty
            ? "Drop audio files into the folder."
            : "\(discoveredSounds.count) sound\(discoveredSounds.count == 1 ? "" : "s") ready."
    }

    func play(_ sound: SoundboardItem, sendToCall: Bool, virtualMicDeviceID: AudioDeviceID?) {
        if sendToCall && virtualMicDeviceID == nil {
            lastErrorMessage = "BlackHole 2ch is not available."
            return
        }
        guard sounds.contains(sound) else {
            refresh()
            lastErrorMessage = "That file is no longer available."
            return
        }

        do {
            let playbackID = try playbackEngine.play(
                url: sound.url,
                virtualMicDeviceID: sendToCall ? virtualMicDeviceID : nil
            ) { [weak self] playbackID in
                self?.finishPlayback(playbackID)
            }
            playbackByID[playbackID] = sound.id
            playingSoundIDs.insert(sound.id)
            lastErrorMessage = nil
            statusMessage = sendToCall ? "Playing \(sound.name) to call." : "Previewing \(sound.name)."
        } catch {
            refresh()
            lastErrorMessage = AudioFileSupport.playbackErrorMessage(error)
        }
    }

    func stopAll() {
        playbackEngine.stopAll()
        playbackByID.removeAll()
        playingSoundIDs.removeAll()
        statusMessage = "Stopped."
    }

    func updateMetadata(for sound: SoundboardItem, name: String, emoji: String) {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEmoji = AudioFileSupport.cleanEmoji(emoji) ?? defaultEmoji
        metadata.sounds[sound.id] = SoundboardSoundMetadata(
            name: cleanedName.isEmpty ? nil : cleanedName,
            emoji: cleanedEmoji
        )
        guard saveMetadata() else { return }
        refresh()
        statusMessage = "Updated \(cleanedName.isEmpty ? sound.name : cleanedName)."
    }

    func clearMetadata(for sound: SoundboardItem) {
        metadata.sounds.removeValue(forKey: sound.id)
        guard saveMetadata() else { return }
        refresh()
        statusMessage = "Reset \(sound.filename)."
    }

    private func ensureFolder() {
        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )
        } catch {
            lastErrorMessage = "Could not create Soundboard folder."
        }
    }

    private var metadataURL: URL {
        folderURL.appendingPathComponent(".micrelay-soundboard.json")
    }

    private func discoverSounds() -> [SoundboardItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            let fileExtension = url.pathExtension.lowercased()
            guard AudioFileSupport.supportedExtensions.contains(fileExtension) else { return nil }

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { return nil }
            let metadata = self.metadata.sounds[url.path]
            let fallbackName = Self.cleanName(from: url)

            return SoundboardItem(
                id: url.path,
                url: url,
                name: metadata?.name?.nilIfBlank ?? fallbackName,
                filename: url.lastPathComponent,
                emoji: metadata?.emoji?.nilIfBlank ?? defaultEmoji,
                modifiedAt: values?.contentModificationDate ?? .distantPast
            )
        }
        .sorted { left, right in
            let nameOrder = left.name.localizedCaseInsensitiveCompare(right.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return left.modifiedAt > right.modifiedAt
        }
    }

    private func finishPlayback(_ playbackID: UUID) {
        guard let soundID = playbackByID.removeValue(forKey: playbackID) else { return }
        if !playbackByID.values.contains(soundID) {
            playingSoundIDs.remove(soundID)
        }
        if playingSoundIDs.isEmpty {
            statusMessage = sounds.isEmpty ? "Drop audio files into the folder." : "\(sounds.count) sound\(sounds.count == 1 ? "" : "s") ready."
        }
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL) else {
            metadata = SoundboardMetadataFile()
            return
        }

        do {
            metadata = try JSONDecoder().decode(SoundboardMetadataFile.self, from: data)
        } catch {
            metadata = SoundboardMetadataFile()
            lastErrorMessage = "Soundboard labels could not be read."
        }
    }

    private func saveMetadata() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Soundboard labels could not be saved."
            return false
        }
    }

    private static func cleanName(from url: URL) -> String {
        let rawName = url.deletingPathExtension().lastPathComponent
        let separated = rawName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let words = separated
            .split(separator: " ")
            .prefix(4)
            .map { word in
                word.prefix(1).uppercased() + String(word.dropFirst())
            }
        let result = words.joined(separator: " ")
        return result.isEmpty ? rawName : result
    }
}

private struct SoundboardMetadataFile: Codable {
    var sounds: [String: SoundboardSoundMetadata] = [:]
}

private struct SoundboardSoundMetadata: Codable {
    var name: String?
    var emoji: String?
}
