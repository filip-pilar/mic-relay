import Foundation

enum AudioFileSupport {
    static let supportedExtensions: Set<String> = [
        "aac", "aif", "aifc", "aiff", "caf", "flac", "m4a", "m4r",
        "mp3", "mp4", "sd2", "wav"
    ]

    /// Copy imports without replacing user files or moving the originals.
    static func importFiles(_ urls: [URL], into folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio file: \(url.lastPathComponent)"])
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var destination = folder.appendingPathComponent(url.lastPathComponent)
            if destination.standardizedFileURL == url.standardizedFileURL { continue }
            var suffix = 2
            while manager.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(suffix).\(url.pathExtension)")
                suffix += 1
            }
            try manager.copyItem(at: url, to: destination)
        }
    }

    static func cleanEmoji(_ value: String) -> String? {
        value.nilIfBlank.map { String($0.prefix(1)) }
    }

    static func playbackErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        if message == "The operation couldn’t be completed. (com.apple.coreaudio.avfaudio error 1685348671.)" {
            return "That file could not be played."
        }
        return message
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
