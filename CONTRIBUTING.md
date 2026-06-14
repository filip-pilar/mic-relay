# Contributing

Thanks for taking a look at Mic Relay.

## Local Setup

1. Install Xcode 16 or newer.
2. Install XcodeGen.
3. Install BlackHole 2ch if you want to test audio routing.

```bash
brew install xcodegen blackhole-2ch
xcodegen generate
./scripts/build.sh
```

Optional Library download support uses:

```bash
brew install yt-dlp ffmpeg
```

## Project Direction

Mic Relay v1 intentionally keeps a narrow audio model:

- selected app audio, preferably Spotify
- optional selected physical microphone
- AVAudioEngine mixer
- BlackHole 2ch as the virtual microphone

Please avoid changes that capture whole-system audio, create multi-output devices, change the default system output, or route call audio back into the virtual microphone unless that direction is discussed first.

## Validation

Before opening a pull request, run:

```bash
./scripts/build.sh
./scripts/probe-audio.sh
```

For audio behavior changes, also run:

```bash
./scripts/probe-audio.sh --tone-to-blackhole
```

Then manually confirm the call app output remains real headphones or speakers, not BlackHole 2ch.

### Manual Echo Checklist

- Call app input is BlackHole 2ch.
- Call app output is real headphones/speakers, not BlackHole 2ch.
- Mic Relay music source is Spotify or the intended music app, not the call app.
- Other participants hear music in Music Only mode.
- Other participants do not hear your mic in Music Only mode.
- Other participants hear music and your mic when Include microphone is on.
- Other participants do not hear themselves come back after they speak.

## Releasing

For a quick friendly build:

```bash
./scripts/build.sh dmg
```

Attach `Mic Relay.dmg` to a GitHub Release with short install notes:

1. Install BlackHole 2ch.
2. Open the DMG and drag Mic Relay to Applications.
3. Right-click Mic Relay and choose Open on first launch if macOS blocks it.
4. Select BlackHole 2ch as the microphone/input in the call app.

For broader distribution, use an Apple Developer ID certificate and notarize the app or DMG. That avoids most Gatekeeper friction.
