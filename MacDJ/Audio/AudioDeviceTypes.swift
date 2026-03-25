import CoreAudio
import Foundation

// MARK: - Audio Mode

enum AudioMode: String, CaseIterable, Sendable {
    case normal
    case musicAndVoice
    case dj

    var label: String {
        switch self {
        case .normal: "Normal"
        case .musicAndVoice: "Music + Voice"
        case .dj: "DJ"
        }
    }

    var icon: String {
        switch self {
        case .normal: "mic"
        case .musicAndVoice: "music.mic"
        case .dj: "music.note.list"
        }
    }

    var subtitle: String {
        switch self {
        case .normal: "Standard audio — mic to calls, speakers for playback"
        case .musicAndVoice: "Your music AND voice go into the call"
        case .dj: "Only music goes into the call (no mic)"
        }
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

// MARK: - Constants

enum MacDJConstants {
    static let blackHoleUID = "BlackHole2ch_UID"
    static let blackHoleName = "BlackHole 2ch"
    static let blackHoleDriverPath = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"

    static let multiOutputUID = "com.forma.macdj.multioutput"
    static let multiOutputName = "MacDJ: Multi-Output"

    static let uidPrefix = "com.forma.macdj."
}

// MARK: - Errors

enum MacDJError: LocalizedError {
    case deviceCreationFailed(OSStatus)
    case deviceNotFound(String)
    case propertyError(OSStatus)
    case blackHoleNotInstalled

    var errorDescription: String? {
        switch self {
        case .deviceCreationFailed(let status):
            "Failed to create audio device (error \(status))"
        case .deviceNotFound(let name):
            "Audio device not found: \(name)"
        case .propertyError(let status):
            "Audio property error (error \(status))"
        case .blackHoleNotInstalled:
            "BlackHole 2ch is not installed"
        }
    }
}
