@preconcurrency import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class LongFormFilePlaybackEngine {
    private let monitorEngine = AVAudioEngine()
    private let virtualMicEngine = AVAudioEngine()
    private var monitorPlayer: AVAudioPlayerNode?
    private var virtualMicPlayer: AVAudioPlayerNode?
    private var monitorFile: AVAudioFile?
    private var virtualMicFile: AVAudioFile?
    private var virtualMicDeviceID: AudioDeviceID?
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = MicRelayConstants.sampleRate
    private var scheduleGeneration = 0
    private var completion: (() -> Void)?

    private(set) var isLoaded = false
    private(set) var isPlaying = false

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(totalFrames) / sampleRate
    }

    var currentTime: TimeInterval {
        guard isLoaded else { return 0 }
        let frame = currentFrame()
        guard sampleRate > 0 else { return 0 }
        return min(duration, max(0, TimeInterval(frame) / sampleRate))
    }

    func play(
        url: URL,
        virtualMicDeviceID: AudioDeviceID?,
        completion: @escaping () -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LongFormFilePlaybackError.fileMissing
        }

        stop()
        let monitorFile = try AVAudioFile(forReading: url)
        let monitorPlayer = AVAudioPlayerNode()
        let virtualMicFile: AVAudioFile?
        let virtualMicPlayer: AVAudioPlayerNode?

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

        self.monitorPlayer = monitorPlayer
        self.virtualMicPlayer = virtualMicPlayer
        self.monitorFile = monitorFile
        self.virtualMicFile = virtualMicFile
        self.totalFrames = monitorFile.length
        self.sampleRate = monitorFile.processingFormat.sampleRate
        self.scheduledStartFrame = 0
        self.completion = completion
        self.isLoaded = true

        try startEnginesIfNeeded()
        scheduleFromCurrentFrame(autoplay: true)
    }

    func pause() {
        guard isPlaying else { return }
        let frame = currentFrame()
        scheduleGeneration += 1
        monitorPlayer?.stop()
        virtualMicPlayer?.stop()
        scheduledStartFrame = frame
        isPlaying = false
    }

    func resume() throws {
        guard isLoaded, !isPlaying else { return }
        try startEnginesIfNeeded()
        scheduleFromCurrentFrame(autoplay: true)
    }

    func stop() {
        scheduleGeneration += 1
        monitorPlayer?.stop()
        virtualMicPlayer?.stop()

        if let monitorPlayer {
            monitorEngine.detach(monitorPlayer)
        }
        if let virtualMicPlayer {
            virtualMicEngine.detach(virtualMicPlayer)
        }

        monitorEngine.stop()
        virtualMicEngine.stop()
        monitorPlayer = nil
        virtualMicPlayer = nil
        monitorFile = nil
        virtualMicFile = nil
        completion = nil
        scheduledStartFrame = 0
        totalFrames = 0
        isLoaded = false
        isPlaying = false
    }

    func seek(to time: TimeInterval) throws {
        guard isLoaded else { return }
        let wasPlaying = isPlaying
        let targetFrame = AVAudioFramePosition(max(0, min(duration, time)) * sampleRate)
        scheduledStartFrame = min(totalFrames, max(0, targetFrame))
        scheduleGeneration += 1
        monitorPlayer?.stop()
        virtualMicPlayer?.stop()
        try startEnginesIfNeeded()
        scheduleFromCurrentFrame(autoplay: wasPlaying)
        isPlaying = wasPlaying
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

    private func startEnginesIfNeeded() throws {
        if !monitorEngine.isRunning {
            try monitorEngine.start()
        }
        if virtualMicPlayer != nil && !virtualMicEngine.isRunning {
            try virtualMicEngine.start()
        }
    }

    private func scheduleFromCurrentFrame(autoplay: Bool) {
        guard let monitorPlayer,
              let monitorFile
        else { return }

        scheduleGeneration += 1
        let generation = scheduleGeneration
        let remainingFrames = max(0, totalFrames - scheduledStartFrame)

        guard remainingFrames > 0 else {
            finishIfCurrent(generation)
            return
        }

        let frameCount = AVAudioFrameCount(min(Int64(UInt32.max), remainingFrames))
        let completionBox = LongFormCompletionBox(remaining: virtualMicPlayer == nil ? 1 : 2) { [weak self] in
            Task { @MainActor in
                self?.finishIfCurrent(generation)
            }
        }

        monitorPlayer.scheduleSegment(
            monitorFile,
            startingFrame: scheduledStartFrame,
            frameCount: frameCount,
            at: nil
        ) {
            completionBox.markFinished()
        }
        if let virtualMicFile, let virtualMicPlayer {
            virtualMicPlayer.scheduleSegment(
                virtualMicFile,
                startingFrame: scheduledStartFrame,
                frameCount: frameCount,
                at: nil
            ) {
                completionBox.markFinished()
            }
        }

        if autoplay {
            monitorPlayer.play()
            virtualMicPlayer?.play()
            isPlaying = true
        }
    }

    private func currentFrame() -> AVAudioFramePosition {
        guard let player = monitorPlayer,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else {
            return scheduledStartFrame
        }
        return min(totalFrames, max(0, scheduledStartFrame + playerTime.sampleTime))
    }

    private func finishIfCurrent(_ generation: Int) {
        guard generation == scheduleGeneration else { return }
        let finished = completion
        stop()
        finished?()
    }
}

private final class LongFormCompletionBox: @unchecked Sendable {
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

enum LongFormFilePlaybackError: LocalizedError {
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            "The audio file is no longer in the Library folder."
        }
    }
}
