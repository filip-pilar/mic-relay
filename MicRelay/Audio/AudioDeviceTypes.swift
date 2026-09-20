import CoreAudio
import AVFoundation
import Foundation

// MARK: - Device Info

struct MicrophoneSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

// MARK: - Music Source

struct MusicSource: Identifiable, Hashable, Sendable {
    let id: Int32
    let bundleIdentifier: String
    let name: String

    var isSpotify: Bool {
        bundleIdentifier == MicRelayConstants.spotifyBundleIdentifier
    }
}

// MARK: - Levels

struct AudioLevels: Sendable {
    var music: Float = 0
    var microphone: Float = 0
    var output: Float = 0
}

// MARK: - Constants

enum MicRelayConstants {
    static let blackHoleUID = "BlackHole2ch_UID"
    static let spotifyBundleIdentifier = "com.spotify.client"
    static let sampleRate = 48_000.0
    static let channelCount = 2
    static let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channelCount),
        interleaved: false
    )!
}

// MARK: - Errors

enum MicRelayError: LocalizedError {
    case deviceNotFound(String)
    case propertyError(OSStatus)
    case musicSourceNotAvailable
    case screenCapturePermissionRequired
    case microphonePermissionRequired
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let name):
            "Audio device not found: \(name)"
        case .propertyError(let status):
            "Audio property error (error \(status))"
        case .musicSourceNotAvailable:
            "The selected music app is not available for capture"
        case .screenCapturePermissionRequired:
            "Screen & System Audio Recording permission is required to capture app audio"
        case .microphonePermissionRequired:
            "Allow Mic Relay in System Settings → Privacy & Security → Microphone, or turn off Include microphone."
        case .captureFailed(let message):
            "Audio capture failed: \(message)"
        }
    }
}
