@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit
import Foundation

@MainActor
final class AppAudioCapture: NSObject {
    private var stream: SCStream?
    private let output = StreamOutput()

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { output.onAudioBuffer }
        set { output.onAudioBuffer = newValue }
    }

    func availableSources() async throws -> [MusicSource] {
        let content = try await SCShareableContent.current
        return content.applications
            .filter { app in
                Self.isUsefulMusicSource(app)
            }
            .map {
                MusicSource(
                    id: $0.processID,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.applicationName
                )
            }
            .sorted { left, right in
                if left.isSpotify != right.isSpotify {
                    return left.isSpotify
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private static func isUsefulMusicSource(_ app: SCRunningApplication) -> Bool {
        guard !app.bundleIdentifier.isEmpty,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }

        let bundleID = app.bundleIdentifier.lowercased()
        let name = app.applicationName.lowercased()

        let alwaysIncludeBundleIDs: Set<String> = [
            "com.spotify.client",
            "com.apple.music",
            "com.google.chrome",
            "com.apple.safari",
            "com.hnc.discord",
            "com.microsoft.teams",
            "us.zoom.xos",
        ]
        if alwaysIncludeBundleIDs.contains(bundleID) {
            return true
        }

        let excludedNames = [
            "accessibility",
            "authenticationserviceshelper",
            "autofill",
            "control center",
            "cursoruiviewservice",
            "dock",
            "finder",
            "loginwindow",
            "mobiledeviceupdater",
            "notification center",
            "nsattributedstringagent",
            "privacy & security",
            "system settings",
            "themedwidgetcontrolviewservice",
            "universal control",
            "usernotificationcenter",
        ]
        if excludedNames.contains(where: { name.contains($0) }) {
            return false
        }

        if bundleID.hasPrefix("com.apple.") {
            return false
        }

        return true
    }

    func start(source: MusicSource) async throws {
        stop()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw MicRelayError.screenCapturePermissionRequired
        }

        guard let display = content.displays.first else {
            throw MicRelayError.captureFailed("No display is available for the capture filter")
        }
        guard let application = content.applications.first(where: {
            $0.processID == source.id || $0.bundleIdentifier == source.bundleIdentifier
        }) else {
            throw MicRelayError.musicSourceNotAvailable
        }

        let filter = SCContentFilter(
            display: display,
            including: [application],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.streamName = "Mic Relay App Audio"
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(MicRelayConstants.sampleRate)
        configuration.channelCount = MicRelayConstants.channelCount

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.micrelay.screencapture.audio")
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let appAudioConverter = AudioSampleConverter(outputFormat: MicRelayConstants.processingFormat)

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .audio:
            guard let buffer = appAudioConverter.convert(sampleBuffer: sampleBuffer) else { return }
            onAudioBuffer?(buffer)
        default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}
}
