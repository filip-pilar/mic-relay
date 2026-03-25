import AppKit
import AVFoundation
import CoreAudio
import Foundation
import KeyboardShortcuts
import ServiceManagement

@MainActor
@Observable
final class AppState {
    // Current mode
    var currentMode: AudioMode = .normal

    // BlackHole status
    var isBlackHoleInstalled = false

    // Error display
    var errorMessage: String?

    // The user's real devices (saved before switching)
    private(set) var savedOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    private(set) var savedInputDeviceID: AudioObjectID = kAudioObjectUnknown

    // Created MacDJ multi-output device
    private(set) var multiOutputDeviceID: AudioObjectID = kAudioObjectUnknown

    // Audio manager and mixer
    let audioManager = AudioDeviceManager()
    private let mixer = AudioMixer()

    // Whether setup has completed
    private(set) var isSetupComplete = false

    // Internal guards (not observed by views)
    @ObservationIgnored private var hasTornDown = false
    @ObservationIgnored private var hasSetUp = false
    @ObservationIgnored private var suppressDeviceChangeHandling = false
    @ObservationIgnored private var terminationObserver: Any?

    // Launch at login
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = "Failed to update launch at login: \(error.localizedDescription)"
            }
        }
    }

    init() {
        setupHotkey()
        setupTerminationHandler()
        setup()
    }

    // MARK: - Setup

    private func setup() {
        guard !hasSetUp else { return }
        hasSetUp = true

        suppressDeviceChangeHandling = true
        audioManager.cleanupOrphanedDevices()
        suppressDeviceChangeHandling = false

        isBlackHoleInstalled = BlackHoleDetector.detect(using: audioManager) == .installed
        guard isBlackHoleInstalled else {
            isSetupComplete = true
            return
        }

        // Pre-request mic permission so the user isn't surprised
        // when they first switch to Music + Voice mode
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Save current real devices
        savedOutputDeviceID = audioManager.getDefaultOutputDevice() ?? kAudioObjectUnknown
        savedInputDeviceID = audioManager.getDefaultInputDevice() ?? kAudioObjectUnknown

        // Create multi-output device (speakers + BlackHole)
        suppressDeviceChangeHandling = true
        createMultiOutputDevice()
        suppressDeviceChangeHandling = false

        // Listen for device changes
        audioManager.onDevicesChanged = { [weak self] in
            self?.handleDeviceChange()
        }
        audioManager.startListeningForDeviceChanges()

        isSetupComplete = true
    }

    // MARK: - Termination

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

    // MARK: - Multi-Output Device

    private func createMultiOutputDevice() {
        guard let outputUID = audioManager.getDeviceUID(for: savedOutputDeviceID) else {
            errorMessage = "Could not read current output device UID"
            return
        }
        do {
            multiOutputDeviceID = try audioManager.createMultiOutputDevice(outputUID: outputUID)
        } catch {
            errorMessage = "Failed to create multi-output device: \(error.localizedDescription)"
        }
    }

    private func destroyMultiOutputDevice() {
        suppressDeviceChangeHandling = true
        if multiOutputDeviceID != kAudioObjectUnknown {
            audioManager.destroyDevice(multiOutputDeviceID)
            multiOutputDeviceID = kAudioObjectUnknown
        }
        suppressDeviceChangeHandling = false
    }

    // MARK: - Mode Switching
    //
    // Signal flow per mode:
    //
    // Normal:
    //   output = speakers, input = mic, mixer OFF
    //
    // Music + Voice:
    //   output = Multi-Output (speakers + BlackHole)
    //   input  = BlackHole (Slack reads music + mic from here)
    //   mixer  = ON (mic → BlackHole, mixed with music by CoreAudio)
    //
    // DJ:
    //   output = Multi-Output (speakers + BlackHole)
    //   input  = BlackHole (Slack reads music only)
    //   mixer  = OFF (no mic)

    func switchMode(to mode: AudioMode) {
        guard isBlackHoleInstalled else {
            errorMessage = "BlackHole 2ch is not installed"
            return
        }

        // Stop mixer before switching (will restart if needed)
        mixer.stop()

        do {
            switch mode {
            case .normal:
                if savedOutputDeviceID != kAudioObjectUnknown {
                    try audioManager.setDefaultOutput(savedOutputDeviceID)
                }
                if savedInputDeviceID != kAudioObjectUnknown {
                    try audioManager.setDefaultInput(savedInputDeviceID)
                }

            case .musicAndVoice:
                guard multiOutputDeviceID != kAudioObjectUnknown else {
                    errorMessage = "Multi-output device not ready"
                    return
                }
                guard let blackHoleID = audioManager.findDevice(byUID: MacDJConstants.blackHoleUID) else {
                    errorMessage = "BlackHole device not found"
                    return
                }

                try audioManager.setDefaultOutput(multiOutputDeviceID)
                try audioManager.setDefaultInput(blackHoleID)

                // Start mixer: mic audio → BlackHole (mixes with music already there)
                try mixer.start(
                    micDeviceID: savedInputDeviceID,
                    blackHoleDeviceID: blackHoleID
                )

            case .dj:
                guard multiOutputDeviceID != kAudioObjectUnknown else {
                    errorMessage = "Multi-output device not ready"
                    return
                }
                guard let blackHoleID = audioManager.findDevice(byUID: MacDJConstants.blackHoleUID) else {
                    errorMessage = "BlackHole device not found"
                    return
                }

                try audioManager.setDefaultOutput(multiOutputDeviceID)
                try audioManager.setDefaultInput(blackHoleID)
                // No mixer — DJ mode sends only music, no mic
            }

            currentMode = mode
            errorMessage = nil
        } catch {
            // Roll back: stop mixer, restore original devices
            mixer.stop()
            try? audioManager.setDefaultOutput(savedOutputDeviceID)
            try? audioManager.setDefaultInput(savedInputDeviceID)
            currentMode = .normal
            errorMessage = "Failed to switch mode: \(error.localizedDescription)"
        }
    }

    func cycleMode() {
        let modes = AudioMode.allCases
        guard let currentIndex = modes.firstIndex(of: currentMode) else { return }
        let nextIndex = (currentIndex + 1) % modes.count
        switchMode(to: modes[nextIndex])
    }

    // MARK: - Device Change Handling

    private func handleDeviceChange() {
        guard !suppressDeviceChangeHandling else { return }
        guard currentMode != .normal else { return }

        let multiOutputExists = audioManager.allDevices.contains {
            $0.uid == MacDJConstants.multiOutputUID
        }

        if !multiOutputExists {
            mixer.stop()
            currentMode = .normal

            let currentOutput = audioManager.getDefaultOutputDevice() ?? kAudioObjectUnknown
            if currentOutput == multiOutputDeviceID || currentOutput == kAudioObjectUnknown {
                if savedOutputDeviceID != kAudioObjectUnknown {
                    try? audioManager.setDefaultOutput(savedOutputDeviceID)
                }
            } else {
                savedOutputDeviceID = currentOutput
            }

            if savedInputDeviceID != kAudioObjectUnknown {
                try? audioManager.setDefaultInput(savedInputDeviceID)
            }

            errorMessage = "Audio device changed — reverted to Normal mode"

            destroyMultiOutputDevice()
            suppressDeviceChangeHandling = true
            createMultiOutputDevice()
            suppressDeviceChangeHandling = false
        }
    }

    // MARK: - Rescan (after BlackHole install)

    func rescanForBlackHole() {
        audioManager.refreshDevices()
        isBlackHoleInstalled = BlackHoleDetector.detect(using: audioManager) == .installed
        if isBlackHoleInstalled && multiOutputDeviceID == kAudioObjectUnknown {
            savedOutputDeviceID = audioManager.getDefaultOutputDevice() ?? kAudioObjectUnknown
            savedInputDeviceID = audioManager.getDefaultInputDevice() ?? kAudioObjectUnknown
            suppressDeviceChangeHandling = true
            createMultiOutputDevice()
            suppressDeviceChangeHandling = false
        }
    }

    // MARK: - Teardown

    func teardown() {
        guard !hasTornDown else { return }
        hasTornDown = true

        mixer.stop()
        if currentMode != .normal {
            switchMode(to: .normal)
        }
        audioManager.stopListeningForDeviceChanges()
        destroyMultiOutputDevice()
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        KeyboardShortcuts.onKeyUp(for: .cycleMode) { [weak self] in
            Task { @MainActor in
                self?.cycleMode()
            }
        }
    }
}
