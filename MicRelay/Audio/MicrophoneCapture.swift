@preconcurrency import AVFoundation
import Foundation

/// Session operations and conversion run on one serial queue.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.micrelay.microphone.capture")
    private let converter = AudioSampleConverter(outputFormat: MicRelayConstants.processingFormat)
    var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func start(deviceID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard let device = Self.availableMicrophones().first(where: { $0.uniqueID == deviceID }) else {
                        throw MicRelayError.deviceNotFound("Selected microphone")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.beginConfiguration()
                    session.inputs.forEach { session.removeInput($0) }
                    session.outputs.forEach { session.removeOutput($0) }
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw MicRelayError.captureFailed("Cannot use selected microphone")
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    session.commitConfiguration()
                    session.startRunning()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    static func availableMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.filter { $0.uniqueID != MicRelayConstants.blackHoleUID }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = converter.convert(sampleBuffer: sampleBuffer) else { return }
        onAudioBuffer?(buffer)
    }
}
