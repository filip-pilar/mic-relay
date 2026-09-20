@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

extension AVAudioEngine {
    /// Selects this engine's output without changing the system output device.
    func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MicRelayError.propertyError(status)
        }
    }
}

/// Joins the local and virtual-mic callbacks, which may arrive on different threads.
final class PlaybackCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let completion: @Sendable () -> Void

    init(remaining: Int, completion: @escaping @Sendable () -> Void) {
        self.remaining = remaining
        self.completion = completion
    }

    func markFinished() {
        lock.lock()
        remaining -= 1
        let shouldComplete = remaining == 0
        lock.unlock()

        if shouldComplete {
            completion()
        }
    }
}
