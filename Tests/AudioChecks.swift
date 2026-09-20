import AVFoundation
import CoreMedia
import Foundation

extension Checks {
    static func checkAudioConversion() {
        for commonFormat: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
                let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
                input.frameLength = 64
                for frame in 0..<64 {
                    for channel in 0..<2 {
                        let buffer = interleaved ? 0 : channel
                        let index = interleaved ? frame * 2 + channel : frame
                        let value: Float = channel == 0 ? 0.25 : -0.5
                        switch commonFormat {
                        case .pcmFormatFloat32: input.floatChannelData![buffer][index] = value
                        case .pcmFormatInt16: input.int16ChannelData![buffer][index] = Int16(value * 32768)
                        case .pcmFormatInt32: input.int32ChannelData![buffer][index] = Int32(Double(value) * 2147483648)
                        default: fatalError()
                        }
                    }
                }
                let converter = AudioSampleConverter(outputFormat: MicRelayConstants.processingFormat)
                guard let output = converter.convert(sampleBuffer: sampleBuffer(input)) else {
                    fatalError("Conversion failed: \(commonFormat), interleaved \(interleaved)")
                }
                precondition(output.format == MicRelayConstants.processingFormat)
                precondition(output.frameLength == 64)
                for frame in 0..<64 {
                    precondition(abs(output.floatChannelData![0][frame] - 0.25) < 0.001)
                    precondition(abs(output.floatChannelData![1][frame] + 0.5) < 0.001)
                }
            }
        }
        let quiet = AVAudioPCMBuffer(pcmFormat: MicRelayConstants.processingFormat, frameCapacity: 128)!
        quiet.frameLength = 128
        for channel in 0..<2 {
            quiet.floatChannelData![channel].update(repeating: 0.00005, count: 128)
        }
        let converted = AudioSampleConverter(outputFormat: quiet.format).convert(sampleBuffer: sampleBuffer(quiet))!
        precondition(converted.floatChannelData![0][100] == 0.00005, "Quiet audio must not be gated")
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let resampler = AudioSampleConverter(outputFormat: MicRelayConstants.processingFormat)
        var outputFrames = 0
        for _ in 0..<100 {
            let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 441)!
            input.frameLength = 441
            input.floatChannelData![0].update(repeating: 0.125, count: 441)
            let output = resampler.convert(sampleBuffer: sampleBuffer(input))!
            outputFrames += Int(output.frameLength)
            if outputFrames > 1_000 {
                for channel in 0..<2 {
                    precondition(abs(output.floatChannelData![channel][Int(output.frameLength) / 2] - 0.125) < 0.001)
                }
            }
        }
        precondition(abs(outputFrames - 48_000) < 512, "Resampling must preserve duration across capture packets")
        print("PCM conversion: planar/interleaved Float32, Int16, Int32, quiet audio, and continuous 44.1 kHz mono resampling passed.")
    }

    static func sampleBuffer(_ pcm: AVAudioPCMBuffer) -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        return sample!
    }
}

extension Checks {
    static func checkRingBuffer() {
        let queue = PCMRingBuffer(capacityFrames: 8, prefillFrames: 4)
        let output = AVAudioPCMBuffer(pcmFormat: MicRelayConstants.processingFormat, frameCapacity: 4)!
        output.frameLength = 4
        func write(_ values: [Float]) {
            values.withUnsafeBufferPointer { queue.write(left: $0.baseAddress!, right: $0.baseAddress!, frameCount: $0.count) }
        }
        func read(_ count: Int) -> [Float] {
            queue.read(into: UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList), frameCount: count)
            return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
        }
        write([1, 2])
        precondition(read(2) == [0, 0], "Wait for a small jitter cushion")
        write([3, 4])
        precondition(read(3) == [1, 2, 3])
        write([5, 6, 7, 8, 9, 10])
        precondition(read(4) == [4, 5, 6, 7], "Wraparound preserves order")
        precondition(read(4) == [8, 9, 10, 0], "Underrun fills only missing samples with silence")
        queue.clear()
        write(Array(1...12).map(Float.init))
        precondition(read(4) == [5, 6, 7, 8], "Overflow keeps the newest audio, bounding latency")
        precondition(read(4) == [9, 10, 11, 12])
        queue.clear()
        write([0.00001, -0.00001, 0.00001, -0.00001])
        precondition(read(4) == [0.00001, -0.00001, 0.00001, -0.00001], "No volume threshold")
        queue.clear()
        precondition(read(4) == [0, 0, 0, 0])
        print("Audio queue: prefill, wraparound, underrun, overflow, clear, and quiet signals passed.")
    }

    static func checkImports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("clip.wav")
        let destination = root.appendingPathComponent("Library", isDirectory: true)
        let data = Data([1, 2, 3])
        try data.write(to: source)
        try AudioFileSupport.importFiles([source], into: destination)
        try AudioFileSupport.importFiles([source], into: destination)
        let original = try Data(contentsOf: source)
        precondition(original == data)
        let first = try Data(contentsOf: destination.appendingPathComponent("clip.wav"))
        precondition(first == data)
        let second = try Data(contentsOf: destination.appendingPathComponent("clip 2.wav"))
        precondition(second == data)
        print("File imports preserve originals and existing names.")
    }
}
