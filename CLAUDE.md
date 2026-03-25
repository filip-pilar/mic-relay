# MacDJ

macOS menu bar app that routes music into Slack huddles / voice calls via BlackHole 2ch.

## Project Setup

- Swift 6, SwiftUI, macOS 14+
- Xcode project generated via `xcodegen generate` (from `project.yml`)
- Single SPM dependency: `KeyboardShortcuts` by sindresorhus
- Build: `./scripts/build.sh` or `./scripts/build.sh dmg`

## Where We Left Off

The app compiles cleanly (Release, zero warnings). One thing remains before it's fully verified:

### Install BlackHole and test

```bash
brew install blackhole-2ch      # needs sudo (it's a system audio driver)
sudo killall -9 coreaudiod      # restart audio daemon (or reboot)
```

Then:

```bash
# 1. Run the test script to verify BlackHole is detected
swift test-audio.swift

# 2. Launch the app
open build/Build/Products/Release/MacDJ.app

# 3. Test all three modes:
#    - Normal: system audio unchanged
#    - Music + Voice: play music, join a Slack huddle — participants should hear both music AND your voice
#    - DJ: participants hear only music (no mic)
```

### What to check

- **Multi-Output device**: verified `kAudioAggregateDeviceIsStackedKey = 1` is correct for multi-output (tested empirically on this machine)
- **Music + Voice mixer**: the `AudioMixer` routes mic → BlackHole via AVAudioEngine. CoreAudio should mix it with the music already flowing to BlackHole from the Multi-Output. This is how multiple apps play through speakers simultaneously — same principle. Needs confirmation with BlackHole.
- If Music + Voice doesn't work (participants only hear music, no voice): the CoreAudio mixing assumption may not hold for BlackHole. Fallback would be requiring BlackHole 16ch as a second virtual device.

## Architecture

```
MacDJ/Audio/AudioDeviceManager.swift  — CoreAudio: enumerate, create multi-output, switch defaults
MacDJ/Audio/AudioMixer.swift          — AVAudioEngine: routes mic → BlackHole for Music+Voice mode
MacDJ/Audio/AudioDeviceTypes.swift    — AudioMode enum, DeviceInfo, constants, errors
MacDJ/Audio/BlackHoleDetector.swift   — Detects BlackHole 2ch installation
MacDJ/App/AppState.swift              — @Observable state: mode switching, lifecycle, hotkey, teardown
MacDJ/App/MenuBarView.swift           — Menu bar dropdown (mode toggles, settings, quit)
MacDJ/App/SettingsView.swift          — Hotkey recorder, launch-at-login, device info
MacDJ/App/OnboardingView.swift        — First-run BlackHole install guide
MacDJ/MacDJApp.swift                  — @main entry point, MenuBarExtra
```

## Key Decisions

- Multi-Output device is `isPrivate: 0` (public) so it survives crashes and Slack keeps its device selection
- Devices created once at launch, destroyed on quit (+ orphan cleanup on launch)
- Music + Voice uses AVAudioEngine mixer (mic → BlackHole) rather than an aggregate input device — aggregate input doesn't work because Slack/WebRTC only reads channels 1-2 from a 4-channel device
- `stacked=1` for multi-output (empirically verified — Apple's docs are misleading)
