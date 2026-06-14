@preconcurrency import AVFoundation
import Foundation

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.micrelay.microphone.capture")
    private let converter = AudioSampleConverter(outputFormat: MicRelayConstants.processingFormat)
    private var isConfigured = false

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(deviceID: String) throws {
        stop()

        guard let device = Self.availableMicrophones().first(where: { $0.uniqueID == deviceID }) else {
            throw MicRelayError.deviceNotFound("Selected microphone")
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicRelayError.captureFailed("Cannot use selected microphone")
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicRelayError.captureFailed("Cannot read selected microphone")
        }
        session.addOutput(output)
        session.commitConfiguration()

        isConfigured = true
        queue.async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        guard isConfigured || session.isRunning else { return }
        isConfigured = false
        queue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    static func availableMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices.filter { $0.uniqueID != MicRelayConstants.blackHoleUID }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = converter.convert(sampleBuffer: sampleBuffer) else { return }
        onAudioBuffer?(buffer)
    }
}
