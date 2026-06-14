# Mic Relay

macOS menu bar app that feeds a virtual microphone for call apps using app-specific music capture plus an optional real microphone.

## Project Setup

- Swift 6, SwiftUI, macOS 14+
- Xcode project generated via `xcodegen generate` from `project.yml`
- No Swift package dependencies
- Build: `./scripts/build.sh` or `./scripts/build.sh dmg`
- Probe: `./scripts/probe-audio.sh` or `./scripts/probe-audio.sh --tone-to-blackhole`

## v1 Architecture

```text
selected music app, preferably Spotify
    + optional selected microphone
    -> AVAudioEngine mixer
    -> BlackHole 2ch
    -> user selects BlackHole 2ch as mic in any call app
```

Mic Relay intentionally does not create a multi-output device, does not set default system output, and does not capture whole-system audio. The call app output must stay on real headphones/speakers to avoid echo.

## Important Files

```text
MicRelay/Audio/AppAudioCapture.swift      — ScreenCaptureKit app-specific music capture
MicRelay/Audio/MicrophoneCapture.swift    — AVFoundation physical microphone capture
MicRelay/Audio/AudioMixer.swift           — AVAudioEngine music/mic mixer -> BlackHole
MicRelay/Audio/AudioDeviceManager.swift   — CoreAudio device enumeration and change listener
MicRelay/Audio/AudioDeviceTypes.swift     — AudioMode, MusicSource, DeviceInfo, levels, constants
MicRelay/Audio/BlackHoleDetector.swift    — Detects BlackHole 2ch installation
MicRelay/App/AppState.swift               — Observable app state and routing lifecycle
MicRelay/App/MenuBarView.swift            — Menu bar control surface
MicRelay/App/OnboardingView.swift         — BlackHole install guide
MicRelay/MicRelayApp.swift                — @main, MenuBarExtra
test-audio.swift                          — Audio device and BlackHole tone probe
```

## Permissions

- Microphone permission is required only when Include microphone is enabled.
- Screen & System Audio Recording permission is required for ScreenCaptureKit app-audio capture.
- BlackHole 2ch must be installed separately.

## Current UX Decisions

- The menu bar label uses `dot.radiowaves.left.and.right`, which is intentionally simpler than the old waveform symbol at menu bar size.
- The menu UI has four top-level tabs: Stream, Library, Soundboard, and Config.
- The main Stream action starts/stops writing the mixed signal to BlackHole.
- Level meters show live signal only while audio is being sent. They should occupy stable space and never change the menu height.
- The microphone picker uses AVFoundation microphone devices and intentionally excludes BlackHole.

## Validation Checklist

1. `./scripts/probe-audio.sh` finds BlackHole 2ch.
2. `./scripts/probe-audio.sh --tone-to-blackhole` moves the input meter in a call/recording app with BlackHole selected as mic.
3. Spotify appears as the preferred music source when running.
4. Music Only sends music to BlackHole without mic.
5. Music + Voice sends music and selected mic to BlackHole.
6. Call app output remains real headphones/speakers.
7. Other participants do not hear themselves echoed back.

## Known Limits

- DRM/protected audio may be silent depending on the app and macOS behavior.
- Friend-friendly notarized distribution is not v1.
- DRM/protected audio may be silent depending on the app and macOS behavior.
