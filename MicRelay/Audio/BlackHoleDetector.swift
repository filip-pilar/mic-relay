import Foundation

enum BlackHoleStatus: Sendable {
    case installed
    case notInstalled
}

struct BlackHoleDetector {
    static let installURL = URL(string: "https://existential.audio/blackhole/")!
    static let brewCommand = "brew install blackhole-2ch"

    @MainActor
    static func detect(using manager: AudioDeviceManager) -> BlackHoleStatus {
        if manager.findDevice(byUID: MicRelayConstants.blackHoleUID) != nil {
            return .installed
        }
        return .notInstalled
    }

    static var driverFileExists: Bool {
        FileManager.default.fileExists(atPath: MicRelayConstants.blackHoleDriverPath)
    }
}
