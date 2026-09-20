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
        return convertToOutputFormat(sourceBuffer)
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)
        ) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        // CoreMedia copies every PCM layout, including interleaved and integer audio.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
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
