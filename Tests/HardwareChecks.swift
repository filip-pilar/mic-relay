import AVFoundation
import CoreAudio
import Foundation

/// Optional integration check: synthetic audio only, BlackHole input only, disposable files.
@main
struct HardwareChecks {
    @MainActor
    static func main() async throws {
        let defaultsBefore = [defaultDevice(kAudioHardwarePropertyDefaultInputDevice), defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)]
        guard let blackHole = AudioDeviceManager().findBlackHoleDevice() else { fatalError("Install BlackHole before running --audio") }
        precondition(!MicrophoneCapture.availableMicrophones().contains { $0.uniqueID == MicRelayConstants.blackHoleUID })
        let recorder = LoopbackMeasurement()
        var io: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&io, blackHole, nil) { @Sendable _, input, _, _, _ in
            recorder.record(input)
        }
        precondition(status == noErr)
        guard let io else { fatalError("BlackHole did not create an IO callback") }
        precondition(AudioDeviceStart(blackHole, io) == noErr)
        defer { AudioDeviceStop(blackHole, io); AudioDeviceDestroyIOProcID(blackHole, io) }
        let mixer = AudioMixer()
        for amplitude: Float in [0.1, 0.001, 0.00005] {
            try mixer.start(blackHoleDeviceID: blackHole, musicVolume: 1, microphoneVolume: 0)
            let buffer = mixer.musicBuffer
            let producer = Task.detached(priority: .high) {
                let clock = ContinuousClock()
                let start = clock.now
                var maximumLateness = Duration.zero
                for packet in 0..<200 {
                    maximumLateness = max(maximumLateness, start.advanced(by: .milliseconds(packet * 10)).duration(to: clock.now))
                    let pcm = AVAudioPCMBuffer(pcmFormat: MicRelayConstants.processingFormat, frameCapacity: 480)!
                    pcm.frameLength = 480
                    for frame in 0..<480 {
                        let value = amplitude * Float(sin(Double(packet * 480 + frame) * 2 * .pi * 440 / 48_000))
                        pcm.floatChannelData![0][frame] = value
                        pcm.floatChannelData![1][frame] = value
                    }
                    buffer.append(pcm)
                    try await clock.sleep(until: start.advanced(by: .milliseconds((packet + 1) * 10)))
                }
                return maximumLateness
            }
            try await Task.sleep(for: .milliseconds(500))
            recorder.reset()
            try await Task.sleep(for: .seconds(1))
            let result = recorder.snapshot()
            let expected = Double(amplitude) / sqrt(2)
            print("BlackHole amplitude \(amplitude): RMS \(result.rms), silent blocks \(result.silent)/\(result.blocks)")
            let maximumLateness = try await producer.value
            print("Synthetic producer maximum scheduling delay: \(maximumLateness)")
            fflush(nil)
            precondition(result.blocks > 10, "BlackHole did not deliver input")
            precondition(abs(result.rms / expected - 1) < 0.15, "Output level must track input even for quiet music")
            precondition(Double(result.silent) / Double(result.blocks) < 0.02, "Continuous input must not become dropouts")
            mixer.stop()
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MicRelayChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = root.appendingPathComponent("silence.caf")
        do {
            let pcm = AVAudioPCMBuffer(pcmFormat: MicRelayConstants.processingFormat, frameCapacity: 48_000)!
            pcm.frameLength = 48_000
            for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0, count: 48_000) }
            var settings = pcm.format.settings
            settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
            let file = try AVAudioFile(forWriting: clip, settings: settings)
            try file.write(from: pcm)
        }
        for output: AudioDeviceID? in [nil, blackHole] {
            let player = FilePlaybackEngine()
            let start = Date()
            var finished = 0
            let id = try player.play(url: clip, virtualMicDeviceID: output) { _ in finished += 1 }
            while player.isLoaded(id) && Date().timeIntervalSince(start) < 5 { try await Task.sleep(for: .milliseconds(20)) }
            precondition(finished == 1 && Date().timeIntervalSince(start) >= 0.9, "Natural completion must wait for playback")
            let first = try player.play(url: clip, virtualMicDeviceID: output) { _ in }
            let second = try player.play(url: clip, virtualMicDeviceID: output) { _ in }
            precondition(player.isPlaying(first) && player.isPlaying(second), "Clips must overlap")
            player.pause(first)
            try player.seek(first, to: 0.4)
            precondition(abs(player.currentTime(first) - 0.4) < 0.01 && !player.isPlaying(first))
            try player.resume(first)
            precondition(player.isPlaying(first))
            player.stopAll()
            precondition(!player.isLoaded(first) && !player.isLoaded(second))
        }
        print("File playback: complete endings, overlapping clips, pause/seek/resume, and stop passed.")

        for output: AudioDeviceID? in [nil, blackHole] {
            let monitor = AVAudioEngine()
            let call = AVAudioEngine()
            let player = FilePlaybackEngine(monitorEngine: monitor, callEngine: call)
            var completed = false
            let id = try player.play(url: clip, virtualMicDeviceID: output) { _ in completed = true }
            try await Task.sleep(for: .milliseconds(250))
            let position = player.currentTime(id)
            let changedEngine = output == nil ? monitor : call
            // Reproduce AVAudioEngine's documented stop + notification without changing devices.
            changedEngine.stop()
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: changedEngine)
            try await Task.sleep(for: .milliseconds(50))
            print("Interrupted \(output == nil ? "local" : "dual-output") playback: loaded=\(player.isLoaded(id)), playing=\(player.isPlaying(id)), completed=\(completed), position=\(player.currentTime(id))")
            fflush(nil)
            precondition(player.isLoaded(id) && !player.isPlaying(id) && !completed, "An output interruption must pause, not falsely finish or keep Playing")
            precondition(abs(player.currentTime(id) - position) < 0.1, "An interruption must preserve the track position")
            try player.resume(id)
            precondition(player.isPlaying(id))
            player.stopAll()
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: changedEngine)
            try await Task.sleep(for: .milliseconds(20))
            precondition(!player.isLoaded(id) && !completed, "Queued changes must not revive stopped playback")
        }
        print("Output interruptions pause at the current position; resume and explicit stop remain reliable.")

        let suite = "MicRelayChecks.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = LibraryState(folderURL: root.appendingPathComponent("Library"))
        let board = SoundboardState(folderURL: root.appendingPathComponent("Soundboard"))
        library.importFiles([clip])
        let track = library.tracks[0]
        library.updateMetadata(for: track, title: "Quiet test", emoji: "🎹")
        library.refresh()
        precondition(library.tracks[0].title == "Quiet test" && library.tracks[0].id == "silence.caf")
        library.play(library.tracks[0], sendToCall: false, virtualMicDeviceID: nil)
        library.pause()
        library.setScrubTime(library.playbackDuration)
        library.finishScrubbing()
        precondition(!library.isPlaying && library.playbackTime == library.playbackDuration)
        board.importFiles([clip])
        board.updateMetadata(for: board.sounds[0], name: "Quiet clip", emoji: "🎹")
        board.refresh()
        precondition(board.sounds[0].name == "Quiet clip" && board.sounds[0].id == board.sounds[0].url.path)
        for (folder, name) in [(library.folderURL, ".micrelay-library.json"), (board.folderURL, ".micrelay-soundboard.json")] {
            let metadata = folder.appendingPathComponent(name)
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        }
        library.updateMetadata(for: library.tracks[0], title: "Cannot save", emoji: "🎹")
        board.updateMetadata(for: board.sounds[0], name: "Cannot save", emoji: "🎹")
        precondition(library.lastErrorMessage == "Library labels could not be saved.")
        precondition(board.lastErrorMessage == "Soundboard labels could not be saved.")
        print("Library end-seeking, existing label formats, and visible label-write errors passed with disposable files.")
        let app = AppState(defaults: preferences, library: library, soundboard: board)
        app.toggleSharing()
        app.stopSharing()
        try await Task.sleep(for: .milliseconds(250))
        precondition(app.phase == .stopped)
        app.toggleSharing()
        for _ in 0..<100 where app.phase == .starting { try await Task.sleep(for: .milliseconds(20)) }
        precondition(app.isSharing, app.errorMessage ?? "Sharing did not start")
        app.selectedMusicBundleID = ""
        app.stopSharing()
        try await Task.sleep(for: .milliseconds(250))
        precondition(app.phase == .stopped, "A stale start must not restart the relay")
        app.teardown()
        precondition(defaultsBefore == [defaultDevice(kAudioHardwarePropertyDefaultInputDevice), defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)])
        print("Rapid start/stop/reconfigure passed. System audio defaults unchanged; microphone never started.")
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        precondition(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr)
        return id
    }
}

private final class LoopbackMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var squareSum: Double = 0
    private var samples = 0
    private var blocks = 0
    private var silent = 0

    func record(_ input: UnsafePointer<AudioBufferList>) {
        var sum: Double = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let values = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let length = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0..<length { sum += Double(values[index]) * Double(values[index]) }
            count += length
        }
        guard count > 0 else { return }
        lock.lock()
        squareSum += sum
        samples += count
        blocks += 1
        if sum / Double(count) < 1e-14 { silent += 1 }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        squareSum = 0; samples = 0; blocks = 0; silent = 0
        lock.unlock()
    }

    func snapshot() -> (rms: Double, blocks: Int, silent: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (sqrt(squareSum / Double(max(1, samples))), blocks, silent)
    }
}
