# MacDJ

A macOS menu bar app that routes your music into Slack huddles and voice calls with one click.

Instead of manually creating virtual audio devices in Audio MIDI Setup, MacDJ does it all for you. Play Spotify, YouTube, or anything — your call participants hear the music while you still hear everything through your speakers.

## Modes

| Mode | Menu Bar Icon | What It Does |
|---|---|---|
| **Normal** | `mic` | Standard audio — your mic goes to calls, speakers play audio |
| **Music + Voice** | `music.mic` | Your music AND voice both go into the call |
| **DJ** | `music.note.list` | Only music goes into the call (no mic) |

## Requirements

- macOS 14 (Sonoma) or later
- [BlackHole 2ch](https://existential.audio/blackhole/) virtual audio driver (free, open source)
- Xcode 15+ (to build from source)

## Quick Start

1. Install BlackHole 2ch:
   ```bash
   brew install blackhole-2ch
   ```
   Then restart your Mac, or run: `sudo killall -9 coreaudiod`

2. Launch MacDJ — it appears in your menu bar

3. Click the menu bar icon and select **Music + Voice** to start routing music into your calls

4. Use a global hotkey (configurable in Settings) to quickly cycle between modes

## Building from Source

```bash
# Clone the repo
git clone <repo-url>
cd mac-dj

# Generate the Xcode project (requires xcodegen)
brew install xcodegen
xcodegen generate

# Open in Xcode
open MacDJ.xcodeproj

# Or build from command line
xcodebuild -project MacDJ.xcodeproj -scheme MacDJ -configuration Release -derivedDataPath build
```

The built app is at `build/Build/Products/Release/MacDJ.app`.

## Creating a .dmg for Distribution

```bash
# Install create-dmg
brew install create-dmg

# Build release
xcodebuild -project MacDJ.xcodeproj \
  -scheme MacDJ \
  -configuration Release \
  -derivedDataPath build

# Ad-hoc sign (no Apple Developer account needed)
codesign --force --deep --sign - "build/Build/Products/Release/MacDJ.app"

# Create the DMG
create-dmg \
  --volname "MacDJ" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "MacDJ.app" 175 190 \
  --app-drop-link 425 190 \
  "MacDJ.dmg" \
  "build/Build/Products/Release/MacDJ.app"
```

## Sharing with Friends

Share the `MacDJ.dmg` file via AirDrop, iMessage, Google Drive, etc.

**Recipients:**

1. Open the DMG and drag **MacDJ** to **Applications**
2. **First launch only:** Right-click `MacDJ.app` → **Open** → click **Open** in the dialog
   - This is a one-time Gatekeeper bypass since the app isn't notarized
   - Alternatively: System Settings → Privacy & Security → scroll down → "Open Anyway"
3. MacDJ will prompt to install BlackHole 2ch if it's not already installed
4. Click the menu bar icon to switch modes

## How It Works

MacDJ uses macOS CoreAudio APIs to programmatically create two virtual audio devices:

- **Multi-Output Device** — sends the same audio to both your speakers/headphones AND BlackHole 2ch. This way you hear your music while it also flows through the virtual cable.
- **Aggregate Device** — combines your real microphone and BlackHole 2ch into one input device. When Slack uses this as its mic, it receives both your voice and your music.

When you switch modes, MacDJ:
1. Creates a **Multi-Output Device** that sends audio to both your speakers and BlackHole
2. Sets the system default input to BlackHole (so Slack reads from it)
3. In **Music + Voice** mode, runs a lightweight audio engine that routes your mic into BlackHole alongside the music — CoreAudio mixes both streams automatically

When you quit, it cleans up virtual devices and restores your original audio settings.

No kernel extensions, no system modifications, no audio quality loss.

## Troubleshooting

**"BlackHole 2ch not installed"**
- Install it: `brew install blackhole-2ch`
- After installing, restart your Mac or run `sudo killall -9 coreaudiod`
- Click "Rescan Audio Devices" in the MacDJ menu

**No sound after switching modes**
- Open **Audio MIDI Setup** (in /Applications/Utilities/) and verify the MacDJ devices are listed
- Check that the sample rate matches across devices (48000 Hz is typical)
- Switch back to Normal mode and try again

**Music not reaching the call**
- Make sure your music app is playing to the system default output (not a specific device)
- In Slack/Zoom/etc., check that the input device is set to "Default" or "BlackHole 2ch"
- MacDJ must be running for Music + Voice mode to work (it actively routes mic audio)

**"Can't be opened because Apple cannot check it for malicious software"**
- Right-click the app → Open → click Open
- Or: System Settings → Privacy & Security → Open Anyway

**App crashed and left virtual devices behind**
- Just relaunch MacDJ — it automatically cleans up orphaned devices on startup
- Or open Audio MIDI Setup and manually delete any "MacDJ:" devices

## Optional: Notarized Distribution

If you want to distribute without Gatekeeper warnings, you need an [Apple Developer account](https://developer.apple.com/programs/) ($99/year):

```bash
# Sign with Developer ID
codesign --force --deep \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --options runtime --timestamp \
  --entitlements MacDJ/MacDJ.entitlements \
  "MacDJ.app"

# Notarize (takes 1-5 minutes)
xcrun notarytool submit MacDJ.dmg \
  --keychain-profile "notary" --wait

# Staple the ticket
xcrun stapler staple MacDJ.dmg
```

## License

MIT
