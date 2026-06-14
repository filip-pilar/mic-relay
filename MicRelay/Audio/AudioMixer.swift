@preconcurrency import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

final class PCMRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [Float]
    private var right: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0

    init(capacityFrames: Int) {
        left = Array(repeating: 0, count: capacityFrames)
        right = Array(repeating: 0, count: capacityFrames)
    }

    var capacityFrames: Int { left.count }

    func clear() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        lock.unlock()
    }

    func write(left inputLeft: UnsafePointer<Float>, right inputRight: UnsafePointer<Float>, frameCount: Int) {
        lock.lock()
        for frame in 0..<frameCount {
            left[writeIndex] = inputLeft[frame]
            right[writeIndex] = inputRight[frame]
            writeIndex = (writeIndex + 1) % capacityFrames
            if availableFrames == capacityFrames {
                readIndex = (readIndex + 1) % capacityFrames
            } else {
                availableFrames += 1
            }
        }
        lock.unlock()
    }

    func read(into ioData: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        lock.lock()
        for frame in 0..<frameCount {
            let sampleLeft: Float
            let sampleRight: Float
            if availableFrames > 0 {
                sampleLeft = left[readIndex]
                sampleRight = right[readIndex]
                readIndex = (readIndex + 1) % capacityFrames
                availableFrames -= 1
            } else {
                sampleLeft = 0
                sampleRight = 0
            }

            for bufferIndex in 0..<ioData.count {
                let channels = Int(ioData[bufferIndex].mNumberChannels)
                guard let data = ioData[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if ioData.count == 1 {
                    let base = frame * channels
                    data[base] = sampleLeft
                    if channels > 1 {
                        data[base + 1] = sampleRight
                    }
                } else if bufferIndex == 0 {
                    data[frame] = sampleLeft
                } else {
                    data[frame] = sampleRight
                }
            }
        }
        lock.unlock()
    }
}

@MainActor
final class AudioMixer {
    let musicBuffer = PCMRingBuffer(capacityFrames: 48_000 * 3)
    let microphoneBuffer = PCMRingBuffer(capacityFrames: 48_000 * 3)

    private var engine: AVAudioEngine?
    private var musicSourceNode: AVAudioSourceNode?
    private var microphoneSourceNode: AVAudioSourceNode?
    private var musicMixerNode: AVAudioMixerNode?
    private var microphoneMixerNode: AVAudioMixerNode?
    private(set) var isRunning = false

    func start(
        blackHoleDeviceID: AudioDeviceID,
        includeMicrophone: Bool
    ) throws {
        stop()
        musicBuffer.clear()
        microphoneBuffer.clear()

        let engine = AVAudioEngine()
        let format = MicRelayConstants.processingFormat

        let musicSourceNode = Self.makeSourceNode(buffer: musicBuffer)
        let microphoneSourceNode = Self.makeSourceNode(buffer: microphoneBuffer)

        let musicMixer = AVAudioMixerNode()
        let microphoneMixer = AVAudioMixerNode()
        musicMixer.outputVolume = 1
        microphoneMixer.outputVolume = includeMicrophone ? 1 : 0

        engine.attach(musicSourceNode)
        engine.attach(microphoneSourceNode)
        engine.attach(musicMixer)
        engine.attach(microphoneMixer)
        engine.connect(musicSourceNode, to: musicMixer, format: format)
        engine.connect(microphoneSourceNode, to: microphoneMixer, format: format)
        engine.connect(musicMixer, to: engine.mainMixerNode, format: format)
        engine.connect(microphoneMixer, to: engine.mainMixerNode, format: format)

        var blackHoleID = blackHoleDeviceID
        let outputStatus = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &blackHoleID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard outputStatus == noErr else {
            throw MicRelayError.propertyError(outputStatus)
        }

        try engine.start()

        self.engine = engine
        self.musicSourceNode = musicSourceNode
        self.microphoneSourceNode = microphoneSourceNode
        self.musicMixerNode = musicMixer
        self.microphoneMixerNode = microphoneMixer
        isRunning = true
    }

    func setMicrophoneIncluded(_ included: Bool) {
        microphoneMixerNode?.outputVolume = included ? 1 : 0
    }

    func stop() {
        engine?.stop()
        engine = nil
        musicSourceNode = nil
        microphoneSourceNode = nil
        musicMixerNode = nil
        microphoneMixerNode = nil
        isRunning = false
        musicBuffer.clear()
        microphoneBuffer.clear()
    }

    nonisolated private static func makeSourceNode(buffer: PCMRingBuffer) -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            buffer.read(
                into: UnsafeMutableAudioBufferListPointer(audioBufferList),
                frameCount: Int(frameCount)
            )
            return noErr
        }
    }
}
