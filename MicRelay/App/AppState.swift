import AppKit
import AVFoundation
import CoreGraphics
import CoreAudio
import Foundation

@MainActor
@Observable
final class AppState {
    var currentMode: AudioMode = .stopped
    var isBlackHoleInstalled = false
    var errorMessage: String?
    var musicSources: [MusicSource] = []
    var selectedMusicSource: MusicSource?
    var microphoneSources: [MicrophoneSource] = []
    var selectedMicrophoneID: String?
    var levels = AudioLevels()
    var sendToCall = false
    var isRouting = false
    var microphonePermissionGranted = false
    var screenCapturePermissionGranted = false
    var capturePermissionHint = "Click Refresh Music Apps to list Spotify or another app."
    var sourceDiagnostic = "Music apps are not scanned automatically so macOS does not prompt on launch."
    var audioStatusMessage = "Audio devices ready to scan."
    var soundboard = SoundboardState()
    var library = LibraryState()

    let audioManager = AudioDeviceManager()
    private let mixer = AudioMixer()
    private let appAudioCapture = AppAudioCapture()
    private let microphoneCapture = MicrophoneCapture()

    @ObservationIgnored private var hasTornDown = false
    @ObservationIgnored private var terminationObserver: Any?
    @ObservationIgnored private var levelDecayTimer: Timer?

    init() {
        setupTerminationHandler()
        setupAudioCallbacks()
        startLevelDecayTimer()
        audioManager.cleanupOrphanedMicRelayDevices()
        refreshAudioDevices()
        refreshScreenCapturePermissionStatus()
        refreshMicrophonePermissionStatus()
    }

    var blackHoleDevice: DeviceInfo? {
        audioManager.blackHoleDevice
    }

    func refreshAudioDevices() {
        audioManager.refreshDevices()
        isBlackHoleInstalled = BlackHoleDetector.detect(using: audioManager) == .installed

        refreshMicrophoneSources()
        if selectedMicrophoneID == nil || !microphoneSources.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = microphoneSources.first(where: \.isDefault)?.id ?? microphoneSources.first?.id
        }
    }

    func refreshScreenCapturePermissionStatus() {
        screenCapturePermissionGranted = CGPreflightScreenCaptureAccess()
    }

    func refreshSources() async {
        refreshScreenCapturePermissionStatus()
        capturePermissionHint = screenCapturePermissionGranted
            ? "macOS reports Screen & System Audio Recording is enabled."
            : "macOS may ask for Screen & System Audio Recording permission."

        do {
            musicSources = try await appAudioCapture.availableSources()
            if let spotify = musicSources.first(where: \.isSpotify) {
                selectedMusicSource = spotify
            } else if selectedMusicSource == nil || !musicSources.contains(where: { $0 == selectedMusicSource }) {
                selectedMusicSource = musicSources.first
            }
            refreshScreenCapturePermissionStatus()
            if musicSources.isEmpty {
                sourceDiagnostic = "ScreenCaptureKit succeeded, but returned 0 apps. Make sure Spotify is running; if it is, quit and reopen Mic Relay after toggling the permission."
            } else {
                sourceDiagnostic = "Found \(musicSources.count) capturable app\(musicSources.count == 1 ? "" : "s")."
            }
            capturePermissionHint = screenCapturePermissionGranted
                ? "Ready to capture app audio."
                : "macOS still reports Screen & System Audio Recording as not granted."
        } catch {
            musicSources = []
            selectedMusicSource = nil
            refreshScreenCapturePermissionStatus()
            capturePermissionHint = "Screen & System Audio Recording permission is needed for app audio capture."
            sourceDiagnostic = Self.describeCaptureError(error)
        }
    }

    func refreshMicrophonePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionGranted = true
        case .notDetermined:
            microphonePermissionGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            microphonePermissionGranted = false
        }
        refreshMicrophoneSources()
    }

    func refreshMicrophonePermissionStatus() {
        microphonePermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        refreshMicrophoneSources()
    }

    func switchMode(to mode: AudioMode) {
        Task {
            await startRouting(mode: mode)
        }
    }

    func setRouting(_ enabled: Bool, includeMicrophone: Bool) {
        if enabled {
            guard sendToCall else {
                errorMessage = "Turn on Send to Call first."
                return
            }
            switchMode(to: includeMicrophone ? .musicAndVoice : .musicOnly)
        } else {
            stopRouting()
        }
    }

    func setSendToCall(_ enabled: Bool) {
        if enabled {
            refreshAudioDevices()
            guard isBlackHoleInstalled else {
                sendToCall = false
                audioStatusMessage = "BlackHole is needed to send audio to calls."
                return
            }
            sendToCall = true
            errorMessage = nil
            audioStatusMessage = "Send to Call is on."
        } else {
            sendToCall = false
            stopRouting()
            soundboard.stopAll()
            library.stop()
            audioStatusMessage = "Send to Call is off. Sounds play locally."
        }
    }

    func setMicrophoneIncluded(_ included: Bool) {
        mixer.setMicrophoneIncluded(included)
        if isRouting {
            if included && currentMode == .musicOnly {
                switchMode(to: .musicAndVoice)
                return
            }
            if !included {
                microphoneCapture.stop()
                levels.microphone = 0
            }
            currentMode = included ? .musicAndVoice : .musicOnly
            updateOutputLevel()
        }
    }

    func startRouting(mode: AudioMode) async {
        guard mode != .stopped else {
            stopRouting()
            return
        }

        refreshAudioDevices()
        guard isBlackHoleInstalled, let blackHoleID = audioManager.findDevice(byUID: MicRelayConstants.blackHoleUID) else {
            failRouting("BlackHole 2ch is not installed or not visible to CoreAudio.")
            return
        }

        if mode.includesMicrophone {
            await refreshMicrophonePermission()
            guard microphonePermissionGranted else {
                failRouting(MicRelayError.microphonePermissionRequired.localizedDescription)
                return
            }
        }

        if musicSources.isEmpty {
            await refreshSources()
        }
        guard let selectedMusicSource else {
            failRouting("Start Spotify or another music app, then click Refresh Sources.")
            return
        }

        let microphoneID: String?
        if mode.includesMicrophone {
            refreshMicrophoneSources()
            guard let id = selectedMicrophoneID,
                  microphoneSources.contains(where: { $0.id == id })
            else {
                failRouting("The selected microphone is no longer available.")
                return
            }
            microphoneID = id
        } else {
            microphoneID = nil
        }

        do {
            appAudioCapture.stop()
            microphoneCapture.stop()
            mixer.stop()
            try mixer.start(
                blackHoleDeviceID: blackHoleID,
                includeMicrophone: mode.includesMicrophone
            )
            try await appAudioCapture.start(
                source: selectedMusicSource
            )
            if let microphoneID {
                try microphoneCapture.start(deviceID: microphoneID)
            }
            currentMode = mode
            isRouting = true
            errorMessage = nil
        } catch {
            failRouting(error.localizedDescription)
        }
    }

    func stopRouting() {
        appAudioCapture.stop()
        microphoneCapture.stop()
        mixer.stop()
        levels = AudioLevels()
        currentMode = .stopped
        isRouting = false
    }

    func rescanAudioDevices() {
        refreshAudioDevices()
        refreshMicrophoneSources()
        refreshScreenCapturePermissionStatus()
        audioStatusMessage = "Rescanned: \(microphoneSources.count) mic\(microphoneSources.count == 1 ? "" : "s"), BlackHole \(isBlackHoleInstalled ? "found" : "missing")."
    }

    func refreshMusicSources() {
        Task {
            await refreshSources()
        }
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func teardown() {
        guard !hasTornDown else { return }
        hasTornDown = true
        sendToCall = false
        stopRouting()
        soundboard.stopAll()
        library.teardown()
        levelDecayTimer?.invalidate()
        levelDecayTimer = nil
        audioManager.stopListeningForDeviceChanges()
    }

    private func setupAudioCallbacks() {
        let musicBuffer = mixer.musicBuffer
        appAudioCapture.onAudioBuffer = { [weak self] buffer in
            Self.appendMusic(buffer, to: musicBuffer)
            let value = Self.rms(buffer)
            Task { @MainActor in
                self?.levels.music = value
                self?.updateOutputLevel()
            }
        }
        let microphoneBuffer = mixer.microphoneBuffer
        microphoneCapture.onAudioBuffer = { [weak self] buffer in
            Self.appendMusic(buffer, to: microphoneBuffer)
            let value = Self.rms(buffer)
            Task { @MainActor in
                guard self?.currentMode.includesMicrophone == true else {
                    self?.levels.microphone = 0
                    self?.updateOutputLevel()
                    return
                }
                self?.levels.microphone = value
                self?.updateOutputLevel()
            }
        }
        audioManager.onDevicesChanged = { [weak self] in
            self?.handleDeviceChange()
        }
        audioManager.startListeningForDeviceChanges()
    }

    private func startLevelDecayTimer() {
        levelDecayTimer?.invalidate()
        levelDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.decayLevels()
            }
        }
    }

    private func decayLevels() {
        guard isRouting else {
            levels = AudioLevels()
            return
        }

        levels.music = Self.decay(levels.music)
        if currentMode.includesMicrophone {
            levels.microphone = Self.decay(levels.microphone)
        } else {
            levels.microphone = 0
        }
        updateOutputLevel()
    }

    private func updateOutputLevel() {
        levels.output = max(levels.music, currentMode.includesMicrophone ? levels.microphone : 0)
    }

    private func refreshMicrophoneSources() {
        let defaultMicrophoneID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let devices = MicrophoneCapture.availableMicrophones()

        microphoneSources = devices
            .map { device in
                MicrophoneSource(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: defaultMicrophoneID == device.uniqueID
                )
            }
            .sorted { left, right in
                if left.isDefault != right.isDefault {
                    return left.isDefault
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    nonisolated private static func appendMusic(_ buffer: AVAudioPCMBuffer, to musicBuffer: PCMRingBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        if buffer.format.channelCount == 1 {
            musicBuffer.write(left: channels[0], right: channels[0], frameCount: frameCount)
        } else {
            musicBuffer.write(left: channels[0], right: channels[1], frameCount: frameCount)
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }
        let meanSquare = sum / Float(channelCount * frameLength)
        return min(1, sqrt(meanSquare) * 3.5)
    }

    nonisolated private static func decay(_ value: Float) -> Float {
        let decayed = value * 0.86
        return decayed < 0.01 ? 0 : decayed
    }

    private func handleDeviceChange() {
        let wasRouting = isRouting
        let mode = currentMode
        refreshAudioDevices()

        guard isBlackHoleInstalled else {
            sendToCall = false
            soundboard.stopAll()
            library.stop()
            guard wasRouting else { return }
            failRouting("BlackHole disappeared. Routing stopped.")
            return
        }

        guard wasRouting else { return }

        Task {
            await startRouting(mode: mode)
        }
    }

    private func failRouting(_ message: String) {
        stopRouting()
        errorMessage = message
    }

    private static func describeCaptureError(_ error: Error) -> String {
        let nsError = error as NSError
        var message = error.localizedDescription
        if !nsError.domain.isEmpty {
            message += " (\(nsError.domain) \(nsError.code))"
        }
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" ||
            nsError.domain == "com.apple.screencapturekit.error" {
            message += ". Quit Mic Relay, toggle the permission off/on, reopen Mic Relay, then click Apps."
        }
        return message
    }

    private func setupTerminationHandler() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.teardown()
            }
        }
    }

}
