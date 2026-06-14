@preconcurrency import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class LocalFilePlaybackEngine {
    private let monitorEngine = AVAudioEngine()
    private let virtualMicEngine = AVAudioEngine()
    private var activePlaybacks: [UUID: ActivePlayback] = [:]
    private var virtualMicDeviceID: AudioDeviceID?

    var isPlaying: Bool {
        !activePlaybacks.isEmpty
    }

    func play(
        url: URL,
        virtualMicDeviceID: AudioDeviceID?,
        completion: @escaping @MainActor (UUID) -> Void
    ) throws -> UUID {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalFilePlaybackError.fileMissing
        }

        let monitorFile = try AVAudioFile(forReading: url)
        let monitorPlayer = AVAudioPlayerNode()
        let virtualMicFile: AVAudioFile?
        let virtualMicPlayer: AVAudioPlayerNode?
        let id = UUID()

        monitorEngine.attach(monitorPlayer)
        monitorEngine.connect(monitorPlayer, to: monitorEngine.mainMixerNode, format: monitorFile.processingFormat)

        if let virtualMicDeviceID {
            try configureVirtualMicOutput(virtualMicDeviceID)
            let file = try AVAudioFile(forReading: url)
            let player = AVAudioPlayerNode()
            virtualMicEngine.attach(player)
            virtualMicEngine.connect(player, to: virtualMicEngine.mainMixerNode, format: file.processingFormat)
            virtualMicFile = file
            virtualMicPlayer = player
        } else {
            virtualMicFile = nil
            virtualMicPlayer = nil
        }

        if !monitorEngine.isRunning {
            try monitorEngine.start()
        }
        if virtualMicPlayer != nil && !virtualMicEngine.isRunning {
            try virtualMicEngine.start()
        }

        activePlaybacks[id] = ActivePlayback(
            monitorPlayer: monitorPlayer,
            virtualMicPlayer: virtualMicPlayer
        )

        let completionBox = PlaybackCompletionBox(remaining: virtualMicPlayer == nil ? 1 : 2) { [weak self] in
            Task { @MainActor in
                self?.finishPlayback(id)
                completion(id)
            }
        }

        monitorPlayer.scheduleFile(monitorFile, at: nil) {
            completionBox.markFinished()
        }
        if let virtualMicFile, let virtualMicPlayer {
            virtualMicPlayer.scheduleFile(virtualMicFile, at: nil) {
                completionBox.markFinished()
            }
        }

        monitorPlayer.play()
        virtualMicPlayer?.play()
        return id
    }

    func stopAll() {
        for playback in activePlaybacks.values {
            playback.monitorPlayer.stop()
            playback.virtualMicPlayer?.stop()
            monitorEngine.detach(playback.monitorPlayer)
            if let virtualMicPlayer = playback.virtualMicPlayer {
                virtualMicEngine.detach(virtualMicPlayer)
            }
        }
        activePlaybacks.removeAll()

        monitorEngine.stop()
        virtualMicEngine.stop()
    }

    private func configureVirtualMicOutput(_ deviceID: AudioDeviceID) throws {
        guard virtualMicDeviceID != deviceID || !virtualMicEngine.isRunning else { return }

        if virtualMicEngine.isRunning {
            virtualMicEngine.stop()
        }

        var outputDeviceID = deviceID
        let status = AudioUnitSetProperty(
            virtualMicEngine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &outputDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MicRelayError.propertyError(status)
        }
        virtualMicDeviceID = deviceID
    }

    private func finishPlayback(_ id: UUID) {
        guard let playback = activePlaybacks.removeValue(forKey: id) else { return }
        playback.monitorPlayer.stop()
        playback.virtualMicPlayer?.stop()
        monitorEngine.detach(playback.monitorPlayer)
        if let virtualMicPlayer = playback.virtualMicPlayer {
            virtualMicEngine.detach(virtualMicPlayer)
        }

        if activePlaybacks.isEmpty {
            monitorEngine.stop()
            virtualMicEngine.stop()
        }
    }
}

private struct ActivePlayback {
    let monitorPlayer: AVAudioPlayerNode
    let virtualMicPlayer: AVAudioPlayerNode?
}

private final class PlaybackCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let completion: @Sendable () -> Void

    init(remaining: Int, completion: @escaping @Sendable () -> Void) {
        self.remaining = remaining
        self.completion = completion
    }

    func markFinished() {
        var shouldComplete = false
        lock.lock()
        remaining -= 1
        if remaining == 0 {
            shouldComplete = true
        }
        lock.unlock()

        if shouldComplete {
            completion()
        }
    }
}

enum LocalFilePlaybackError: LocalizedError {
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            "The audio file is no longer in the Soundboard folder."
        }
    }
}
