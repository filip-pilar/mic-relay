import CoreAudio
import AVFoundation
import Foundation

// MARK: - Audio Mode

enum AudioMode: String, CaseIterable, Sendable {
    case stopped
    case musicAndVoice
    case musicOnly

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .musicAndVoice: "Music + Voice"
        case .musicOnly: "Music"
        }
    }

    var icon: String {
        switch self {
        case .stopped: "mic.slash"
        case .musicAndVoice: "music.mic"
        case .musicOnly: "music.note.list"
        }
    }

    var subtitle: String {
        switch self {
        case .stopped: "Mic Relay is not feeding the virtual microphone"
        case .musicAndVoice: "Selected app audio and your mic feed BlackHole"
        case .musicOnly: "Selected app audio feeds BlackHole without your mic"
        }
    }

    var includesMicrophone: Bool {
        self == .musicAndVoice
    }
}

// MARK: - Device Info

struct DeviceInfo: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

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
    static let blackHoleName = "BlackHole 2ch"
    static let blackHoleDriverPath = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"

    static let uidPrefix = "com.micrelay."
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
    case blackHoleNotInstalled
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
        case .blackHoleNotInstalled:
            "BlackHole 2ch is not installed"
        case .musicSourceNotAvailable:
            "The selected music app is not available for capture"
        case .screenCapturePermissionRequired:
            "Screen & System Audio Recording permission is required to capture app audio"
        case .microphonePermissionRequired:
            "Microphone permission is required to include your mic"
        case .captureFailed(let message):
            "Audio capture failed: \(message)"
        }
    }
}
