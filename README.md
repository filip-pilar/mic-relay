# Mic Relay

Mic Relay is a small macOS menu bar app for sending music into voice calls.

It captures audio from one selected app, optionally mixes in your real microphone, and sends the result to [BlackHole 2ch](https://existential.audio/blackhole/) so Slack, Discord, Zoom, Meet, and similar apps can use it as a microphone.

```text
selected music app + optional microphone
    -> Mic Relay
    -> BlackHole 2ch
    -> your call app's microphone input
```

Mic Relay does not capture whole-system audio, create multi-output devices, or change your system output. Keep the call app's speaker/output set to real headphones or speakers so other people do not hear themselves echo back.

## Status

Mic Relay is early open-source macOS software. It works as a local/friendly-testing build, but releases are not notarized yet.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16+ to build from source
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [BlackHole 2ch](https://existential.audio/blackhole/)
- Optional: `yt-dlp` and `ffmpeg` for Library downloads

```bash
brew install xcodegen blackhole-2ch
```

After installing BlackHole, restart your Mac or run:

```bash
sudo killall -9 coreaudiod
```

## Build

```bash
xcodegen generate
./scripts/build.sh
```

The app is built at:

```text
build/Build/Products/Release/Mic Relay.app
```

To build a shareable DMG:

```bash
./scripts/build.sh dmg
```

The DMG is ad-hoc signed. On first launch, macOS may require right-clicking the app and choosing Open.

## Use

1. Start Spotify or another music app.
2. Launch Mic Relay.
3. Choose the music source.
4. Enable Include microphone if you want your voice mixed in.
5. Turn on Send to Call, then start App Stream.
6. In the call app, set microphone/input to BlackHole 2ch.
7. Keep the call app speaker/output on real headphones or speakers.

## Privacy

- App audio capture uses ScreenCaptureKit and is scoped to the selected app.
- Microphone access is only needed when Include microphone is enabled.
- Library and Soundboard files stay local under `~/Music/Mic Relay/`.
- BlackHole 2ch is a separate virtual audio driver installed by the user.

## Known Limits

- DRM/protected audio may be silent depending on the source app and macOS behavior.
- BlackHole 2ch must be installed separately.
- Builds are not Developer ID signed or notarized yet.
- Soundboard and Library are useful but still early.

## Development

Project notes and validation steps live in [CONTRIBUTING.md](CONTRIBUTING.md). Agent-specific repo guidance lives in [AGENTS.md](AGENTS.md).

## License

Mic Relay is available under the MIT License. See [LICENSE](LICENSE).
