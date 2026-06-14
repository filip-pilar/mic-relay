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
