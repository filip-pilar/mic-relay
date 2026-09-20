import AppKit
import CoreAudio
import Foundation

struct LibraryTrack: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let title: String
    let derivedTitle: String
    let filename: String
    let emoji: String
    let playlistID: String?
    let playlistName: String?
    let modifiedAt: Date
}

struct LibrarySourceFilter: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

@MainActor
@Observable
final class LibraryState {
    static let allTracksSourceID = "all"

    var importURLText = ""
    var searchText = ""
    var selectedSourceID = "all"
    var tracks: [LibraryTrack] = []
    var sourceFilters: [LibrarySourceFilter] = [
        LibrarySourceFilter(id: "all", name: "All Tracks")
    ]
    var statusMessage = "Add audio files or paste a YouTube URL."
    var lastErrorMessage: String?
    var isDownloading = false
    var downloadProgress: Double?
    var nowPlayingTrackID: String?
    var nowPlayingTitle = "No track selected"
    var playbackTime: TimeInterval = 0
    var playbackDuration: TimeInterval = 0
    var isPlaying = false
    var isScrubbing = false

    let folderURL: URL

    private let playbackEngine = FilePlaybackEngine()
    private var playbackID: UUID?
    private let downloader = LibraryDownloader()
    private let defaultEmoji = "🎵"
    private var metadata = LibraryMetadataFile()
    private var progressTimer: Timer?
    private var downloadTask: Task<Void, Never>?

    init(folderURL: URL? = nil) {
        self.folderURL = folderURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Mic Relay", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        refresh()
        playbackEngine.onInterruption = { [weak self] in
            self?.pause()
            self?.lastErrorMessage = "Audio output changed. Press Play to resume."
        }
        startProgressTimer()
        updateToolStatusMessage()
    }

    var filteredTracks: [LibraryTrack] {
        let sourceFiltered = selectedSourceID == Self.allTracksSourceID
            ? tracks
            : tracks.filter { $0.playlistID == selectedSourceID }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sourceFiltered }
        return sourceFiltered.filter { track in
            track.title.localizedCaseInsensitiveContains(query) ||
            track.derivedTitle.localizedCaseInsensitiveContains(query) ||
            track.filename.localizedCaseInsensitiveContains(query) ||
            track.emoji.localizedCaseInsensitiveContains(query)
        }
    }

    var hasCurrentTrack: Bool {
        nowPlayingTrackID != nil
    }

    var toolStatus: DownloaderToolStatus {
        downloader.toolStatus
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
        statusMessage = "Library folder opened."
    }

    func refresh() {
        ensureFolder()
        loadMetadata()
        let discoveredTracks = discoverTracks()
        tracks = discoveredTracks
        sourceFilters = makeSourceFilters(from: discoveredTracks)
        if selectedSourceID != Self.allTracksSourceID &&
            !sourceFilters.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = Self.allTracksSourceID
        }
        if let nowPlayingTrackID,
           !discoveredTracks.contains(where: { $0.id == nowPlayingTrackID }) {
            stop()
            lastErrorMessage = "That file is no longer available."
        }
        if !isDownloading {
            statusMessage = discoveredTracks.isEmpty
                ? "Add audio files or paste a YouTube URL."
                : "\(discoveredTracks.count) track\(discoveredTracks.count == 1 ? "" : "s") ready."
        }
    }

    func startDownload() {
        guard !isDownloading else { return }
        let urlText = importURLText
        isDownloading = true
        downloadProgress = nil
        lastErrorMessage = nil
        statusMessage = "Starting download..."

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await downloader.download(urlString: urlText, into: folderURL) { [weak self] message, progress in
                    guard let self, downloadTask?.isCancelled == false else { return }
                    statusMessage = message
                    downloadProgress = progress
                }
                try Task.checkCancellation()
                importURLText = ""
                isDownloading = false
                downloadProgress = nil
                refresh()
            } catch {
                isDownloading = false
                downloadProgress = nil
                if Task.isCancelled {
                    statusMessage = "Download canceled."
                } else {
                    lastErrorMessage = error.localizedDescription
                    statusMessage = "Download failed."
                }
            }
            downloadTask = nil
        }
    }

    func cancelDownload() {
        guard isDownloading else { return }
        downloadTask?.cancel()
        downloader.cancel()
        downloadProgress = nil
        statusMessage = "Canceling download…"
    }

    func play(_ track: LibraryTrack, sendToCall: Bool, virtualMicDeviceID: AudioDeviceID?) {
        if sendToCall && virtualMicDeviceID == nil {
            lastErrorMessage = "BlackHole 2ch is not available."
            return
        }
        guard FileManager.default.fileExists(atPath: track.url.path) else {
            refresh()
            lastErrorMessage = "That file is no longer available."
            return
        }

        do {
            playbackEngine.stopAll()
            playbackID = try playbackEngine.play(
                url: track.url,
                virtualMicDeviceID: sendToCall ? virtualMicDeviceID : nil
            ) { [weak self] _ in
                self?.finishPlayback()
            }
            nowPlayingTrackID = track.id
            nowPlayingTitle = track.title
            playbackDuration = playbackID.map { playbackEngine.duration($0) } ?? 0
            playbackTime = 0
            isPlaying = true
            lastErrorMessage = nil
            statusMessage = sendToCall ? "Playing \(track.title) to call." : "Previewing \(track.title)."
        } catch {
            stop()
            refresh()
            lastErrorMessage = AudioFileSupport.playbackErrorMessage(error)
        }
    }

    func togglePlayPause(sendToCall: Bool, virtualMicDeviceID: AudioDeviceID?) {
        if isPlaying {
            pause()
            return
        }

        if let playbackID, playbackEngine.isLoaded(playbackID) {
            do {
                try playbackEngine.resume(playbackID)
                isPlaying = playbackEngine.isPlaying(playbackID)
                lastErrorMessage = nil
                if isPlaying { statusMessage = "Playing \(nowPlayingTitle)." }
            } catch {
                lastErrorMessage = AudioFileSupport.playbackErrorMessage(error)
            }
            return
        }

        if let current = currentTrack ?? filteredTracks.first {
            play(current, sendToCall: sendToCall, virtualMicDeviceID: virtualMicDeviceID)
        }
    }

    func pause() {
        if let playbackID { playbackEngine.pause(playbackID) }
        playbackTime = playbackID.map { playbackEngine.currentTime($0) } ?? 0
        isPlaying = false
        statusMessage = "Paused."
    }

    func stop() {
        playbackEngine.stopAll()
        playbackID = nil
        playbackTime = 0
        playbackDuration = 0
        isPlaying = false
        isScrubbing = false
        nowPlayingTrackID = nil
        nowPlayingTitle = "No track selected"
        statusMessage = tracks.isEmpty
            ? "Add audio files or paste a YouTube URL."
            : "\(tracks.count) track\(tracks.count == 1 ? "" : "s") ready."
    }

    func playPrevious(sendToCall: Bool, virtualMicDeviceID: AudioDeviceID?) {
        guard let target = adjacentTrack(offset: -1) else { return }
        play(target, sendToCall: sendToCall, virtualMicDeviceID: virtualMicDeviceID)
    }

    func playNext(sendToCall: Bool, virtualMicDeviceID: AudioDeviceID?) {
        guard let target = adjacentTrack(offset: 1) else { return }
        play(target, sendToCall: sendToCall, virtualMicDeviceID: virtualMicDeviceID)
    }

    func setScrubTime(_ time: TimeInterval) {
        isScrubbing = true
        playbackTime = max(0, min(playbackDuration, time))
    }

    func finishScrubbing() {
        defer { isScrubbing = false }
        do {
            guard let playbackID else { return }
            try playbackEngine.seek(playbackID, to: playbackTime)
            playbackTime = playbackEngine.isLoaded(playbackID) ? playbackEngine.currentTime(playbackID) : playbackDuration
            isPlaying = playbackEngine.isPlaying(playbackID)
        } catch {
            lastErrorMessage = AudioFileSupport.playbackErrorMessage(error)
        }
    }

    func updateMetadata(for track: LibraryTrack, title: String, emoji: String) {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEmoji = AudioFileSupport.cleanEmoji(emoji) ?? defaultEmoji
        metadata.tracks[track.id] = LibraryTrackMetadata(
            title: cleanedTitle.isEmpty ? nil : cleanedTitle,
            emoji: cleanedEmoji
        )
        guard saveMetadata() else { return }
        refresh()
        if nowPlayingTrackID == track.id {
            nowPlayingTitle = cleanedTitle.isEmpty ? track.derivedTitle : cleanedTitle
        }
        statusMessage = "Updated \(cleanedTitle.isEmpty ? track.derivedTitle : cleanedTitle)."
    }

    func clearMetadata(for track: LibraryTrack) {
        metadata.tracks.removeValue(forKey: track.id)
        guard saveMetadata() else { return }
        refresh()
        if nowPlayingTrackID == track.id {
            nowPlayingTitle = track.derivedTitle
        }
        statusMessage = "Reset \(track.filename)."
    }

    func teardown() {
        cancelDownload()
        playbackEngine.stopAll()
        playbackID = nil
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private var currentTrack: LibraryTrack? {
        guard let nowPlayingTrackID else { return nil }
        return tracks.first(where: { $0.id == nowPlayingTrackID })
    }

    private func adjacentTrack(offset: Int) -> LibraryTrack? {
        let queue = filteredTracks
        guard !queue.isEmpty else { return nil }
        guard let nowPlayingTrackID,
              let index = queue.firstIndex(where: { $0.id == nowPlayingTrackID })
        else {
            return offset >= 0 ? queue.first : queue.last
        }
        let nextIndex = index + offset
        guard queue.indices.contains(nextIndex) else { return nil }
        return queue[nextIndex]
    }

    private func ensureFolder() {
        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: folderURL.appendingPathComponent("Playlists", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            lastErrorMessage = "Could not create Library folder."
        }
    }

    private var metadataURL: URL {
        folderURL.appendingPathComponent(".micrelay-library.json")
    }

    private func discoverTracks() -> [LibraryTrack] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var discoveredTracks: [LibraryTrack] = []
        for case let url as URL in enumerator {
            let fileExtension = url.pathExtension.lowercased()
            guard AudioFileSupport.supportedExtensions.contains(fileExtension) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { continue }

            let relativePath = Self.relativePath(for: url, in: folderURL)
            let metadata = metadata.tracks[relativePath]
            let derivedTitle = Self.cleanTitle(from: url)
            let playlist = Self.playlistInfo(for: relativePath)
            discoveredTracks.append(
                LibraryTrack(
                    id: relativePath,
                    url: url,
                    title: metadata?.title?.nilIfBlank ?? derivedTitle,
                    derivedTitle: derivedTitle,
                    filename: url.lastPathComponent,
                    emoji: metadata?.emoji?.nilIfBlank ?? defaultEmoji,
                    playlistID: playlist.id,
                    playlistName: playlist.name,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            )
        }

        return discoveredTracks.sorted { left, right in
            if left.playlistName != right.playlistName {
                return (left.playlistName ?? "").localizedCaseInsensitiveCompare(right.playlistName ?? "") == .orderedAscending
            }
            let nameOrder = left.title.localizedCaseInsensitiveCompare(right.title)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return left.modifiedAt > right.modifiedAt
        }
    }

    private func makeSourceFilters(from tracks: [LibraryTrack]) -> [LibrarySourceFilter] {
        let playlistFilters = Dictionary(grouping: tracks.compactMap { track -> LibrarySourceFilter? in
            guard let id = track.playlistID, let name = track.playlistName else { return nil }
            return LibrarySourceFilter(id: id, name: name)
        }, by: \.id)
            .compactMap { _, filters in filters.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return [LibrarySourceFilter(id: Self.allTracksSourceID, name: "All Tracks")] + playlistFilters
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePlaybackProgress()
            }
        }
    }

    private func updatePlaybackProgress() {
        guard let playbackID, playbackEngine.isPlaying(playbackID) else { return }
        let time = playbackEngine.currentTime(playbackID)
        if !isScrubbing {
            playbackTime = time
        }
    }

    private func finishPlayback() {
        playbackID = nil
        playbackTime = playbackDuration
        isPlaying = false
        statusMessage = "Finished \(nowPlayingTitle)."
    }

    private func updateToolStatusMessage() {
        guard tracks.isEmpty, let message = toolStatus.missingMessage else { return }
        statusMessage = message
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL) else {
            metadata = LibraryMetadataFile()
            return
        }

        do {
            metadata = try JSONDecoder().decode(LibraryMetadataFile.self, from: data)
        } catch {
            metadata = LibraryMetadataFile()
            lastErrorMessage = "Library labels could not be read."
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
            lastErrorMessage = "Library labels could not be saved."
            return false
        }
    }

    private static func relativePath(for url: URL, in folderURL: URL) -> String {
        let basePath = folderURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(basePath + "/") else { return url.lastPathComponent }
        return String(filePath.dropFirst(basePath.count + 1))
    }

    private static func playlistInfo(for relativePath: String) -> (id: String?, name: String?) {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0] == "Playlists" else {
            return (nil, nil)
        }
        let folderName = components[1]
        return ("Playlists/\(folderName)", cleanPlaylistName(folderName))
    }

    private static func cleanPlaylistName(_ folderName: String) -> String {
        folderName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanTitle(from url: URL) -> String {
        let rawName = url.deletingPathExtension().lastPathComponent
        let withoutIndex = rawName.replacingOccurrences(
            of: #"^\d+\s*[-_.]\s*"#,
            with: "",
            options: .regularExpression
        )
        let separated = withoutIndex
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let words = separated
            .split(separator: " ")
            .prefix(8)
            .map { word in
                word.prefix(1).uppercased() + String(word.dropFirst())
            }
        let result = words.joined(separator: " ")
        return result.isEmpty ? rawName : result
    }

}

private struct LibraryMetadataFile: Codable {
    var tracks: [String: LibraryTrackMetadata] = [:]
}

private struct LibraryTrackMetadata: Codable {
    var title: String?
    var emoji: String?
}
