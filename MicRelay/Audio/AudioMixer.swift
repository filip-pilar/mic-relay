@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation

/// A bounded capture/render queue. Prefill absorbs callback jitter, never gates by volume.
final class PCMRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [Float]
    private var right: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var primed = false
    private let prefillFrames: Int
    let meter = AudioMeter()

    init(capacityFrames: Int = 12_000, prefillFrames: Int = 1_920) {
        precondition(capacityFrames > 0 && prefillFrames >= 0 && prefillFrames <= capacityFrames)
        left = .init(repeating: 0, count: capacityFrames)
        right = .init(repeating: 0, count: capacityFrames)
        self.prefillFrames = prefillFrames
    }

    func clear() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        available = 0
        primed = false
        lock.unlock()
        _ = meter.consumePeak()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format == MicRelayConstants.processingFormat, let channels = buffer.floatChannelData else { return }
        write(left: channels[0], right: channels[1], frameCount: Int(buffer.frameLength))
        meter.record(buffer)
    }

    func write(left inputLeft: UnsafePointer<Float>, right inputRight: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let count = min(frameCount, left.count)
        let skipped = frameCount - count
        let overflow = max(0, available + count - left.count)
        readIndex = (readIndex + overflow) % left.count
        var copied = 0
        while copied < count {
            let chunk = min(count - copied, left.count - writeIndex)
            left.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: writeIndex).update(from: inputLeft + skipped + copied, count: chunk) }
            right.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: writeIndex).update(from: inputRight + skipped + copied, count: chunk) }
            writeIndex = (writeIndex + chunk) % left.count
            copied += chunk
        }
        available = min(left.count, available + count)
    }

    func read(into output: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        for buffer in output {
            buffer.mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: frameCount * Int(buffer.mNumberChannels))
        }
        lock.lock()
        defer { lock.unlock() }
        if !primed {
            guard available >= max(prefillFrames, frameCount) else { return }
            primed = true
        }
        let count = min(frameCount, available)
        var copied = 0
        while copied < count {
            let chunk = min(count - copied, left.count - readIndex)
            if output.count == 2 {
                left.withUnsafeBufferPointer { output[0].mData!.assumingMemoryBound(to: Float.self).advanced(by: copied).update(from: $0.baseAddress! + readIndex, count: chunk) }
                right.withUnsafeBufferPointer { output[1].mData!.assumingMemoryBound(to: Float.self).advanced(by: copied).update(from: $0.baseAddress! + readIndex, count: chunk) }
            } else if let data = output[0].mData?.assumingMemoryBound(to: Float.self) {
                let channels = Int(output[0].mNumberChannels)
                for frame in 0..<chunk {
                    data[(copied + frame) * channels] = left[readIndex + frame]
                    if channels > 1 { data[(copied + frame) * channels + 1] = right[readIndex + frame] }
                }
            }
            readIndex = (readIndex + chunk) % left.count
            copied += chunk
        }
        available -= count
        if count < frameCount { primed = false }
    }
}

/// Capture callbacks accumulate peaks; the UI samples them at a fixed rate.
final class AudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var value: Float = 0
        let buffers = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samples = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        for channel in 0..<buffers {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(samples))
            value = max(value, channelPeak)
        }
        lock.lock()
        peak = max(peak, value)
        lock.unlock()
    }

    func consumePeak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }
}

@MainActor
final class AudioMixer {
    let musicBuffer = PCMRingBuffer()
    let microphoneBuffer = PCMRingBuffer()
    let outputMeter = AudioMeter()
    var onFailure: (@MainActor (Error) -> Void)?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var musicMixer: AVAudioMixerNode?
    private var microphoneMixer: AVAudioMixerNode?

    func start(blackHoleDeviceID: AudioDeviceID, musicVolume: Float, microphoneVolume: Float) throws {
        stop()
        let engine = AVAudioEngine()
        try engine.setOutputDevice(blackHoleDeviceID)
        let musicMixer = attach(musicBuffer, to: engine)
        let microphoneMixer = attach(microphoneBuffer, to: engine)
        musicMixer.outputVolume = musicVolume
        microphoneMixer.outputVolume = microphoneVolume
        let meter = outputMeter
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
            meter.record(buffer)
        }
        self.engine = engine
        self.musicMixer = musicMixer
        self.microphoneMixer = microphoneMixer
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak engine] _ in
            // Hardware format changes stop AVAudioEngine. Leave its internal notification queue
            // before restarting; a queued notification must not revive an intentionally stopped relay.
            Task { @MainActor in
                guard let self, let engine, self.engine === engine, !engine.isRunning else { return }
                do { try engine.start() }
                catch { self.onFailure?(error) }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func setVolumes(music: Float, microphone: Float) {
        musicMixer?.outputVolume = music
        microphoneMixer?.outputVolume = microphone
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine = nil
        musicMixer = nil
        microphoneMixer = nil
        musicBuffer.clear()
        microphoneBuffer.clear()
        _ = outputMeter.consumePeak()
    }

    private func attach(_ buffer: PCMRingBuffer, to engine: AVAudioEngine) -> AVAudioMixerNode {
        let format = MicRelayConstants.processingFormat
        let source = AVAudioSourceNode(format: format) { @Sendable _, _, count, output -> OSStatus in
            buffer.read(into: UnsafeMutableAudioBufferListPointer(output), frameCount: Int(count))
            return noErr
        }
        let mixer = AVAudioMixerNode()
        engine.attach(source)
        engine.attach(mixer)
        engine.connect(source, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        return mixer
    }
}
