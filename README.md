# Mic Relay

Mic Relay is a macOS menu bar app that feeds a virtual microphone for voice-call apps.

The v1 signal flow is:

```text
selected music app, preferably Spotify
    + optional real microphone
    -> Mic Relay mixer
    -> BlackHole 2ch
    -> selected as microphone in Slack, Discord, Zoom, Meet, etc.
```

Mic Relay does not route whole-system audio and does not change the system default output. Keep your call app speaker/output on real headphones or speakers so call audio is not captured back into the virtual mic.

## Status

Mic Relay is early open-source macOS software. The current build is intended for local use and friendly testing, not polished notarized distribution.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16+ to build from source
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the Xcode project from `project.yml`
- [BlackHole 2ch](https://existential.audio/blackhole/) as the virtual microphone device
- Optional: `yt-dlp` and `ffmpeg` for Library downloads

Install BlackHole:

```bash
brew install blackhole-2ch
sudo killall -9 coreaudiod
```

Restarting instead of killing `coreaudiod` is also fine.

Install optional Library download tools:

```bash
brew install yt-dlp ffmpeg
```

## Build

```bash
xcodegen generate
./scripts/build.sh
```

The built app is at:

```text
build/Build/Products/Release/Mic Relay.app
```

Build a DMG:

```bash
./scripts/build.sh dmg
```

The DMG build is ad-hoc signed. Friends may need to right-click the app and choose Open on first launch unless you distribute a Developer ID signed and notarized build.

## Use

1. Start Spotify or another music app.
2. Launch Mic Relay.
3. Grant Microphone permission if you want to include your mic.
4. Grant Screen & System Audio Recording permission when macOS asks for app-audio capture.
5. In Mic Relay, choose the music source and microphone.
6. Turn Routing on. Use Include microphone to choose music-only or music plus voice.
7. In the call app, set microphone/input to BlackHole 2ch.
8. In the call app, keep speaker/output set to real headphones or speakers.

## Privacy and Safety

- App audio capture uses ScreenCaptureKit and is scoped to the selected app.
- Mic Relay does not capture whole-system audio.
- Mic Relay does not set or change the system default audio output.
- Microphone permission is only needed when you include your physical microphone.
- Downloaded Library and Soundboard files live locally under `~/Music/Mic Relay/`.
- BlackHole 2ch is a separate virtual audio driver and must be installed by the user.

## Validation

List audio devices and verify BlackHole:

```bash
./scripts/probe-audio.sh
```

Write a generated tone into BlackHole:

```bash
./scripts/probe-audio.sh --tone-to-blackhole
```

For the tone test, select BlackHole 2ch as a microphone in a call app or a recording app and confirm the tone appears on the input meter.

### Manual Echo Checklist

- Call app input is BlackHole 2ch.
- Call app output is real headphones/speakers, not BlackHole 2ch.
- Mic Relay music source is Spotify or the intended music app, not the call app.
- Other participants hear music in Music Only mode.
- Other participants do not hear your mic in Music Only mode.
- Other participants hear music and your mic when Include microphone is on.
- Other participants do not hear themselves come back after they speak.

## Architecture Notes

- App-specific music capture uses ScreenCaptureKit with an application content filter.
- Physical microphone capture uses AVFoundation and passes the selected `AVCaptureDevice` into the mixer.
- The mixer uses AVAudioEngine and writes its output directly to BlackHole 2ch.
- BlackHole is used as a virtual mic any call app can select.
- Local music monitoring is provided by the music app's normal playback path; Mic Relay does not need to mirror call audio or system output.
- DRM/protected audio may be unavailable or silent depending on the source app and OS behavior.

## Releasing

For a quick friend build:

```bash
./scripts/build.sh dmg
```

Attach `Mic Relay.dmg` to a GitHub Release with short install notes:

1. Install BlackHole 2ch.
2. Open the DMG and drag Mic Relay to Applications.
3. Right-click Mic Relay and choose Open on first launch if macOS blocks it.
4. Select BlackHole 2ch as the microphone/input in the call app.

For broader distribution, use an Apple Developer ID certificate and notarize the app or DMG. That avoids most Gatekeeper friction and is more important than whether the repository is public.

## Contributing

Please keep changes scoped to the app's v1 audio model: selected app audio plus optional physical microphone into BlackHole 2ch. Avoid whole-system capture, multi-output devices, or changing the user's default output unless the project intentionally changes direction.

## Troubleshooting

**BlackHole is missing**

Install BlackHole 2ch, restart the audio daemon or reboot, then click Refresh in Mic Relay.

**No music sources appear**

Start Spotify or another audio app, then click Refresh. If macOS has not granted Screen & System Audio Recording permission, enable it in System Settings > Privacy & Security.

**The call hears nothing**

Make sure Mic Relay is routing, BlackHole 2ch is selected as the call app microphone, and the Output meter is moving.

**Echo**

Make sure the call app output is not BlackHole 2ch and that the selected Mic Relay source is not the call app.

## License

Mic Relay is available under the MIT License. See [LICENSE](LICENSE).
