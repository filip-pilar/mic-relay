import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation

enum RelayPhase { case stopped, starting, sharing }

@MainActor
@Observable
final class AppState {
    private(set) var phase: RelayPhase = .stopped
    private(set) var blackHoleDeviceID: AudioDeviceID?
    private(set) var musicSources: [MusicSource] = []
    private(set) var microphoneSources: [MicrophoneSource] = []
    private(set) var isFindingApps = false
    private(set) var microphoneAuthorization: AVAuthorizationStatus = .notDetermined
    private(set) var screenCapturePermissionGranted = false
    private(set) var levels = AudioLevels()
    var errorMessage: String?

    var selectedMusicBundleID: String {
        didSet {
            defaults.set(selectedMusicBundleID, forKey: "musicApp")
            restartIfSharing()
        }
    }
    var selectedMicrophoneID: String {
        didSet {
            defaults.set(selectedMicrophoneID, forKey: "microphone")
            restartIfSharing()
        }
    }
    var includeMicrophone: Bool {
        didSet {
            defaults.set(includeMicrophone, forKey: "includeMicrophone")
            restartIfSharing()
        }
    }
    var musicVolume: Float {
        didSet {
            defaults.set(musicVolume, forKey: "musicVolume")
            updateVolumes()
        }
    }
    var microphoneVolume: Float {
        didSet {
            defaults.set(microphoneVolume, forKey: "microphoneVolume")
            updateVolumes()
        }
    }
    let soundboard: SoundboardState
    let library: LibraryState

    var isSharing: Bool { phase == .sharing }
    var microphonePermissionGranted: Bool { microphoneAuthorization == .authorized }
    var isBlackHoleInstalled: Bool { blackHoleDeviceID != nil }
    var selectedMusicSource: MusicSource? { musicSources.first { $0.bundleIdentifier == selectedMusicBundleID } }
    var statusText: String {
        switch phase {
        case .stopped: "Local playback"
        case .starting: "Connecting…"
        case .sharing: "Sharing to BlackHole"
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let audioManager = AudioDeviceManager()
    @ObservationIgnored private let mixer = AudioMixer()
    @ObservationIgnored private let appCapture = AppAudioCapture()
    @ObservationIgnored private let microphoneCapture = MicrophoneCapture()
    @ObservationIgnored private var routingTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [Any] = []
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isRefreshingDevices = false

    init(defaults: UserDefaults = .standard, library: LibraryState = LibraryState(), soundboard: SoundboardState = SoundboardState()) {
        self.defaults = defaults
        self.library = library
        self.soundboard = soundboard
        selectedMusicBundleID = defaults.string(forKey: "musicApp") ?? ""
        selectedMicrophoneID = defaults.string(forKey: "microphone") ?? ""
        includeMicrophone = defaults.bool(forKey: "includeMicrophone")
        musicVolume = min(1, max(0, (defaults.object(forKey: "musicVolume") as? NSNumber)?.floatValue ?? 1))
        microphoneVolume = min(1, max(0, (defaults.object(forKey: "microphoneVolume") as? NSNumber)?.floatValue ?? 1))
        let musicBuffer = mixer.musicBuffer
        let micBuffer = mixer.microphoneBuffer
        appCapture.onAudioBuffer = { musicBuffer.append($0) }
        microphoneCapture.onAudioBuffer = { micBuffer.append($0) }
        mixer.onFailure = { [weak self] error in
            self?.stopSharing()
            self?.errorMessage = "Audio output stopped: \(error.localizedDescription). Try Start Sharing again."
        }
        appCapture.onFailure = { [weak self] error in
            self?.stopSharing()
            self?.errorMessage = "App audio stopped: \(error.localizedDescription). Try Start Sharing again."
        }
        audioManager.onDevicesChanged = { [weak self] in self?.refreshDevices() }
        audioManager.startListeningForDeviceChanges()
        refreshDevices()
        refreshPermissions()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions(); self?.refreshDevices() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        })
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLevels() }
        }
    }

    func refreshPermissions() {
        screenCapturePermissionGranted = CGPreflightScreenCaptureAccess()
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func refreshDevices() {
        isRefreshingDevices = true
        let oldDevice = blackHoleDeviceID
        let oldMicrophone = selectedMicrophoneID
        blackHoleDeviceID = audioManager.findBlackHoleDevice()
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        microphoneSources = MicrophoneCapture.availableMicrophones().map {
            MicrophoneSource(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID)
        }.sorted { left, right in
            if left.isDefault != right.isDefault { return left.isDefault }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        if !microphoneSources.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = microphoneSources.first?.id ?? ""
        }
        isRefreshingDevices = false
        guard phase != .stopped else { return }
        if blackHoleDeviceID == nil {
            stopSharing()
            errorMessage = "BlackHole disconnected. Reconnect it, then start sharing again."
        } else if oldDevice != blackHoleDeviceID || (includeMicrophone && oldMicrophone != selectedMicrophoneID) {
            // Files also hold the previous device ID.
            library.stop()
            soundboard.stopAll()
            startSharing()
        }
    }

    func findMusicApps() async {
        guard !isFindingApps else { return }
        isFindingApps = true
        defer { isFindingApps = false }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        do {
            musicSources = try await appCapture.availableSources()
            screenCapturePermissionGranted = true
            if defaults.object(forKey: "musicApp") == nil {
                selectedMusicBundleID = musicSources.first(where: \.isSpotify)?.bundleIdentifier ?? musicSources.first?.bundleIdentifier ?? ""
            }
            errorMessage = musicSources.isEmpty ? "No apps found. Open your music app, then refresh." : nil
        } catch {
            refreshPermissions()
            errorMessage = "App audio access is unavailable. Open Screen & System Audio Recording in Setup, allow Mic Relay, then quit and reopen it if macOS asks."
        }
    }

    func requestMicrophoneAccess() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refreshPermissions()
    }

    func toggleSharing() {
        if phase == .stopped {
            // A destination change must never leave a local preview mislabeled as shared.
            library.stop()
            soundboard.stopAll()
            startSharing()
        } else { stopSharing() }
    }

    private func restartIfSharing() {
        guard !isRefreshingDevices, phase != .stopped else { return }
        startSharing()
    }

    private func startSharing() {
        generation += 1
        let request = generation
        let previous = routingTask
        previous?.cancel()
        mixer.stop()
        phase = .starting
        errorMessage = nil
        // Serialize capture teardown/start. A superseded permission prompt cannot re-enable routing.
        routingTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await appCapture.stop()
            await microphoneCapture.stop()
            do {
                try Task.checkCancellation()
                guard let device = blackHoleDeviceID else { throw MicRelayError.deviceNotFound("BlackHole 2ch — install it in Setup") }
                if includeMicrophone {
                    await requestMicrophoneAccess()
                    try Task.checkCancellation()
                    guard microphonePermissionGranted else { throw MicRelayError.microphonePermissionRequired }
                }
                if !selectedMusicBundleID.isEmpty {
                    if selectedMusicSource == nil { await findMusicApps() }
                    try Task.checkCancellation()
                    guard let source = selectedMusicSource else { throw MicRelayError.musicSourceNotAvailable }
                    try await appCapture.start(source: source)
                }
                try Task.checkCancellation()
                if includeMicrophone { try await microphoneCapture.start(deviceID: selectedMicrophoneID) }
                try Task.checkCancellation()
                try mixer.start(blackHoleDeviceID: device, musicVolume: musicVolume, microphoneVolume: includeMicrophone ? microphoneVolume : 0)
                phase = .sharing
            } catch {
                await appCapture.stop()
                await microphoneCapture.stop()
                guard generation == request else { return }
                mixer.stop()
                library.stop()
                soundboard.stopAll()
                phase = .stopped
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    func stopSharing() {
        generation += 1
        phase = .stopped
        let previous = routingTask
        previous?.cancel()
        mixer.stop()
        levels = AudioLevels()
        soundboard.stopAll()
        library.stop()
        routingTask = Task { [appCapture, microphoneCapture] in
            await previous?.value
            await appCapture.stop()
            await microphoneCapture.stop()
        }
    }

    private func updateVolumes() {
        mixer.setVolumes(music: musicVolume, microphone: includeMicrophone ? microphoneVolume : 0)
    }

    private func sampleLevels() {
        let music = mixer.musicBuffer.meter.consumePeak()
        let mic = mixer.microphoneBuffer.meter.consumePeak()
        let output = mixer.outputMeter.consumePeak()
        guard isSharing else { levels = AudioLevels(); return }
        levels = AudioLevels(music: max(music, levels.music * 0.75), microphone: includeMicrophone ? max(mic, levels.microphone * 0.75) : 0, output: max(output, levels.output * 0.75))
    }

    func openPrivacySettings(microphone: Bool = false) {
        let pane = microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    func teardown() {
        stopSharing()
        library.teardown()
        levelTimer?.invalidate()
        levelTimer = nil
        audioManager.stopListeningForDeviceChanges()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
