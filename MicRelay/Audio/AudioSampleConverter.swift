@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

final class AudioSampleConverter: @unchecked Sendable {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return nil }
        guard let sourceBuffer = makePCMBuffer(from: sampleBuffer) else { return nil }
        return convertToOutputFormat(sourceBuffer) ?? sourceBuffer
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        var neededSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, neededSize > 0 else { return nil }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: neededSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: neededSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            bufferListNoCopy: UnsafePointer(audioBufferList)
        ) else { return nil }
        sourceBuffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)

        return copyBuffer(sourceBuffer)
    }

    private func convertToOutputFormat(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if sourceBuffer.format == outputFormat {
            return sourceBuffer
        }

        if converter == nil || converterInputFormat != sourceBuffer.format {
            converter = AVAudioConverter(from: sourceBuffer.format, to: outputFormat)
            converterInputFormat = sourceBuffer.format
        }

        guard let converter,
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(sourceBuffer.frameLength) *
                    outputFormat.sampleRate /
                    sourceBuffer.format.sampleRate
                ) + 512
              )
        else { return nil }

        let inputBox = ConverterInputBox(buffer: sourceBuffer)
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            guard let buffer = inputBox.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }

        return error == nil ? outputBuffer : nil
    }

    private func copyBuffer(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: sourceBuffer.format,
            frameCapacity: sourceBuffer.frameLength
        ) else { return nil }

        copy.frameLength = sourceBuffer.frameLength
        let frameLength = Int(sourceBuffer.frameLength)

        if let source = sourceBuffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<Int(sourceBuffer.format.channelCount) {
                destination[channel].update(from: source[channel], count: frameLength)
            }
            return copy
        }

        if let source = sourceBuffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<Int(sourceBuffer.format.channelCount) {
                destination[channel].update(from: source[channel], count: frameLength)
            }
            return copy
        }

        return nil
    }
}

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let result = buffer
        buffer = nil
        return result
    }
}
