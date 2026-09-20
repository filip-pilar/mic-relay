@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Library uses one playback; Soundboard keeps several. Both share the same scheduling rules.
@MainActor
final class FilePlaybackEngine: NSObject {
    private let monitorEngine: AVAudioEngine
    private let callEngine: AVAudioEngine
    private var callDeviceID: AudioDeviceID?
    private var playbacks: [UUID: Playback] = [:]
    var onInterruption: (@MainActor () -> Void)?

    init(monitorEngine: AVAudioEngine = AVAudioEngine(), callEngine: AVAudioEngine = AVAudioEngine()) {
        self.monitorEngine = monitorEngine
        self.callEngine = callEngine
        super.init()
        for engine in [monitorEngine, callEngine] {
            NotificationCenter.default.addObserver(self, selector: #selector(engineConfigurationChanged), name: .AVAudioEngineConfigurationChange, object: engine)
        }
    }

    func play(url: URL, virtualMicDeviceID: AudioDeviceID?, completion: @escaping @MainActor (UUID) -> Void) throws -> UUID {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw MicRelayError.captureFailed("The audio file is empty") }
        let id = UUID()
        var outputs: [Output] = []
        do {
            outputs.append(attach(file: file, to: monitorEngine))
            if let virtualMicDeviceID {
                if callDeviceID != virtualMicDeviceID || !callEngine.isRunning {
                    try callEngine.setOutputDevice(virtualMicDeviceID)
                    callDeviceID = virtualMicDeviceID
                }
                outputs.append(attach(file: try AVAudioFile(forReading: url), to: callEngine))
            }
            let playback = Playback(outputs: outputs, completion: completion)
            playbacks[id] = playback
            try resume(id)
            return id
        } catch {
            playbacks.removeValue(forKey: id)
            detach(outputs)
            stopIdleEngines()
            throw error
        }
    }

    func duration(_ id: UUID) -> TimeInterval {
        guard let playback = playbacks[id] else { return 0 }
        return Double(playback.file.length) / playback.file.processingFormat.sampleRate
    }

    func currentTime(_ id: UUID) -> TimeInterval {
        guard let playback = playbacks[id] else { return 0 }
        return Double(currentFrame(playback)) / playback.file.processingFormat.sampleRate
    }

    func isPlaying(_ id: UUID) -> Bool { playbacks[id]?.isPlaying == true }
    func isLoaded(_ id: UUID) -> Bool { playbacks[id] != nil }

    func pause(_ id: UUID) {
        guard let playback = playbacks[id], playback.isPlaying else { return }
        let frame = currentFrame(playback)
        unschedule(playback)
        playback.position = frame
    }

    func resume(_ id: UUID) throws {
        guard let playback = playbacks[id], !playback.isPlaying else { return }
        for output in playback.outputs where !output.engine.isRunning {
            try output.engine.start()
        }
        schedule(id, playback)
    }

    func seek(_ id: UUID, to time: TimeInterval) throws {
        guard let playback = playbacks[id], time.isFinite else { return }
        let wasPlaying = playback.isPlaying
        unschedule(playback)
        playback.position = AVAudioFramePosition(min(duration(id), max(0, time)) * playback.file.processingFormat.sampleRate)
        if playback.position >= playback.file.length {
            finish(id)
        } else if wasPlaying {
            try resume(id)
        }
    }

    func stopAll() {
        let active = Array(playbacks.values)
        playbacks.removeAll()
        for playback in active { detach(playback.outputs) }
        monitorEngine.stop()
        callEngine.stop()
    }

    @objc nonisolated private func engineConfigurationChanged(_ notification: Notification) {
        guard let engine = notification.object as? AVAudioEngine else { return }
        // AVAudioEngine posts on an internal queue; stop player nodes after leaving that queue.
        Task { @MainActor [weak self] in self?.pauseAfterInterruption(of: engine) }
    }

    private func pauseAfterInterruption(of engine: AVAudioEngine) {
        guard !engine.isRunning else { return }
        let affected = playbacks.filter { _, playback in
            playback.isPlaying && playback.outputs.contains { $0.engine === engine }
        }
        guard !affected.isEmpty else { return }
        for id in affected.keys { pause(id) }
        onInterruption?()
    }

    private func attach(file: AVAudioFile, to engine: AVAudioEngine) -> Output {
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        return Output(engine: engine, node: node, file: file)
    }

    private func schedule(_ id: UUID, _ playback: Playback) {
        let remaining = playback.file.length - playback.position
        guard remaining > 0 else { finish(id); return }
        let count = AVAudioFrameCount(min(Int64(UInt32.max), remaining))
        let endFrame = playback.position + Int64(count)
        let generation = UUID()
        playback.generation = generation
        let completion = PlaybackCompletion(remaining: playback.outputs.count) { [weak self] in
            Task { @MainActor in
                guard let self, let active = self.playbacks[id], active.generation == generation else { return }
                // Stopping an engine may invoke completion before its configuration notification.
                if let stopped = active.outputs.first(where: { !$0.engine.isRunning }) {
                    self.pauseAfterInterruption(of: stopped.engine)
                    return
                }
                if endFrame < active.file.length {
                    self.unschedule(active)
                    active.position = endFrame
                    self.schedule(id, active)
                } else {
                    self.finish(id)
                }
            }
        }
        for output in playback.outputs {
            output.node.scheduleSegment(output.file, startingFrame: playback.position, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { @Sendable _ in
                completion.markFinished()
            }
        }
        playback.isPlaying = true
        playback.lastKnownFrame = playback.position
        for output in playback.outputs { output.node.play() }
    }

    private func currentFrame(_ playback: Playback) -> AVAudioFramePosition {
        guard playback.isPlaying else { return playback.position }
        for output in playback.outputs where output.engine.isRunning {
            if let time = output.node.lastRenderTime,
               let playerTime = output.node.playerTime(forNodeTime: time) {
                playback.lastKnownFrame = min(playback.file.length, max(playback.position, playback.position + playerTime.sampleTime))
                break
            }
        }
        // The Library samples progress every 250 ms. Keep that position if a device reset
        // has already invalidated both render clocks, rather than jumping to the track's start.
        return playback.lastKnownFrame
    }

    private func unschedule(_ playback: Playback) {
        playback.generation = UUID()
        playback.isPlaying = false
        for output in playback.outputs { output.node.stop() }
    }

    private func finish(_ id: UUID) {
        guard let playback = playbacks.removeValue(forKey: id) else { return }
        detach(playback.outputs)
        stopIdleEngines()
        playback.completion(id)
    }

    private func detach(_ outputs: [Output]) {
        for output in outputs {
            output.node.stop()
            output.engine.detach(output.node)
        }
    }

    private func stopIdleEngines() {
        if playbacks.isEmpty { monitorEngine.stop() }
        if !playbacks.values.contains(where: { $0.outputs.count == 2 }) { callEngine.stop() }
    }
}

private struct Output {
    let engine: AVAudioEngine
    let node: AVAudioPlayerNode
    let file: AVAudioFile
}

@MainActor
private final class Playback {
    let outputs: [Output]
    let completion: @MainActor (UUID) -> Void
    var position: AVAudioFramePosition = 0
    var lastKnownFrame: AVAudioFramePosition = 0
    var isPlaying = false
    var generation = UUID()
    var file: AVAudioFile { outputs[0].file }

    init(outputs: [Output], completion: @escaping @MainActor (UUID) -> Void) {
        self.outputs = outputs
        self.completion = completion
    }
}
