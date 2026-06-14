import Foundation

struct DownloaderToolStatus: Sendable {
    let ytDLPPath: String?
    let ffmpegPath: String?

    var hasRequiredTools: Bool {
        ytDLPPath != nil && ffmpegPath != nil
    }

    var missingMessage: String? {
        if ytDLPPath == nil && ffmpegPath == nil {
            return "Install yt-dlp and ffmpeg with Homebrew."
        }
        if ytDLPPath == nil {
            return "Install yt-dlp with Homebrew."
        }
        if ffmpegPath == nil {
            return "Install ffmpeg with Homebrew."
        }
        return nil
    }
}

@MainActor
final class LibraryDownloader {
    private var process: Process?
    private var outputBuffer = ""

    var toolStatus: DownloaderToolStatus {
        DownloaderToolStatus(
            ytDLPPath: Self.findExecutable(named: "yt-dlp", commonPaths: [
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp"
            ]),
            ffmpegPath: Self.findExecutable(named: "ffmpeg", commonPaths: [
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg"
            ])
        )
    }

    func download(
        urlString: String,
        into folderURL: URL,
        progress: @escaping @MainActor (String, Double?) -> Void
    ) async throws {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw LibraryDownloadError.emptyURL
        }

        let tools = toolStatus
        guard let ytDLPPath = tools.ytDLPPath else {
            throw LibraryDownloadError.missingTool(tools.missingMessage ?? "Install yt-dlp with Homebrew.")
        }
        guard let ffmpegPath = tools.ffmpegPath else {
            throw LibraryDownloadError.missingTool(tools.missingMessage ?? "Install ffmpeg with Homebrew.")
        }

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folderURL.appendingPathComponent("Playlists", isDirectory: true),
            withIntermediateDirectories: true
        )

        let isPlaylist = Self.looksLikePlaylistURL(trimmedURL)
        let outputTemplate = isPlaylist
            ? folderURL
                .appendingPathComponent("Playlists", isDirectory: true)
                .appendingPathComponent("%(playlist_title).150B", isDirectory: true)
                .appendingPathComponent("%(playlist_index)03d - %(title).200B.%(ext)s")
                .path
            : folderURL
                .appendingPathComponent("%(title).200B.%(ext)s")
                .path

        let ffmpegDirectory = URL(fileURLWithPath: ffmpegPath).deletingLastPathComponent().path
        var arguments = [
            "--newline",
            "--no-warnings",
            "--extract-audio",
            "--audio-format", "mp3",
            "--audio-quality", "0",
            "--ffmpeg-location", ffmpegDirectory,
            "--output", outputTemplate
        ]
        arguments.append(isPlaylist ? "--yes-playlist" : "--no-playlist")
        arguments.append(trimmedURL)

        progress(isPlaylist ? "Downloading playlist..." : "Downloading...", nil)
        outputBuffer = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDLPPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let handleData: @Sendable (Data) -> Void = { [weak self] data in
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task { @MainActor in
                self?.consumeOutput(text, progress: progress)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            handleData(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            handleData(handle.availableData)
        }

        let terminationStatus = await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
            self.process = process
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Int32.min)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        self.process = nil

        guard terminationStatus == 0 else {
            throw LibraryDownloadError.failed(Self.shortFailure(from: outputBuffer))
        }

        progress("Download complete.", 1)
    }

    func cancel() {
        guard let process else { return }
        process.terminate()
        self.process = nil
    }

    private func consumeOutput(
        _ text: String,
        progress: @escaping @MainActor (String, Double?) -> Void
    ) {
        outputBuffer.append(text)
        if outputBuffer.count > 12_000 {
            outputBuffer.removeFirst(outputBuffer.count - 12_000)
        }

        let lines = text
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map(String.init)

        for line in lines {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if let percent = Self.downloadPercent(from: cleaned) {
                progress(Self.compactStatus(from: cleaned), percent)
            } else if cleaned.contains("[ExtractAudio]") {
                progress("Converting to MP3...", nil)
            } else if cleaned.contains("[download]") || cleaned.contains("[youtube]") {
                progress(Self.compactStatus(from: cleaned), nil)
            }
        }
    }

    private static func compactStatus(from line: String) -> String {
        let stripped = line
            .replacingOccurrences(of: "[download]", with: "")
            .replacingOccurrences(of: "[youtube]", with: "")
            .replacingOccurrences(of: "[ExtractAudio]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return "Working..." }
        return String(stripped.prefix(92))
    }

    private static func downloadPercent(from line: String) -> Double? {
        guard let percentRange = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) else {
            return nil
        }
        let raw = line[percentRange].dropLast()
        guard let value = Double(raw) else { return nil }
        return min(1, max(0, value / 100))
    }

    private static func shortFailure(from output: String) -> String {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let errorLine = lines.reversed().first(where: { $0.localizedCaseInsensitiveContains("error") }) {
            return String(errorLine.prefix(140))
        }
        return "Download failed."
    }

    private static func looksLikePlaylistURL(_ urlString: String) -> Bool {
        let lowercased = urlString.lowercased()
        return lowercased.contains("list=") || lowercased.contains("/playlist")
    }

    private static func findExecutable(named name: String, commonPaths: [String]) -> String? {
        let manager = FileManager.default
        for path in commonPaths where manager.isExecutableFile(atPath: path) {
            return path
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirectories = pathValue
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
                .path
            if manager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}

enum LibraryDownloadError: LocalizedError {
    case emptyURL
    case missingTool(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            "Paste a YouTube URL first."
        case .missingTool(let message):
            message
        case .failed(let message):
            message
        }
    }
}
