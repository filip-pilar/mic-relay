import AudioToolbox
import AVFoundation
import CoreAudio

/// Routes mic audio into BlackHole so it mixes with the music already
/// flowing there from the Multi-Output device.
///
/// CoreAudio automatically mixes multiple clients writing to the same output
/// device (the same way you hear multiple apps through your speakers at once).
/// So: Multi-Output sends music to BlackHole, and this mixer sends mic to
/// BlackHole — Slack reads BlackHole and gets both.
@MainActor
final class AudioMixer {
    private var engine: AVAudioEngine?
    private(set) var isRunning = false

    func start(micDeviceID: AudioDeviceID, blackHoleDeviceID: AudioDeviceID) throws {
        stop()

        let engine = AVAudioEngine()

        // Point the engine's input at the real mic (not system default,
        // since system default will be BlackHole in music modes)
        var micID = micDeviceID
        let inputStatus = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &micID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard inputStatus == noErr else {
            throw MacDJError.propertyError(inputStatus)
        }

        // Point the engine's output at BlackHole (mic audio will be
        // mixed with the music already arriving from Multi-Output)
        var bhID = blackHoleDeviceID
        let outputStatus = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &bhID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard outputStatus == noErr else {
            throw MacDJError.propertyError(outputStatus)
        }

        // Wire: mic → mixer → BlackHole
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: inputFormat)

        try engine.start()
        self.engine = engine
        isRunning = true
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
    }
}
