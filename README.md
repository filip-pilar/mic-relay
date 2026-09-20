# Mic Relay

Mic Relay sends music into voice calls on macOS. Capture one selected app, optionally add your microphone, and send the mix to [BlackHole 2ch](https://existential.audio/blackhole/) for your call app to use as its microphone.

A native window holds Music, Library, and Soundboard. The menu bar shortcut opens the window or starts/stops sharing. Library plays local tracks with seeking and playlist folders; Soundboard plays overlapping clips. Both also work locally without BlackHole.

Mic Relay does not capture whole-system audio, create multi-output devices, or change system audio defaults. Keep the call app's output on real headphones or speakers to prevent echo.

## Requirements and build

- macOS 14 Sonoma or later
- Xcode 16+ (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build
- BlackHole 2ch to send audio to calls
- Optional: `yt-dlp` and `ffmpeg` for Library downloads; no Swift package dependencies

```bash
brew install xcodegen blackhole-2ch
./scripts/setup-signing.sh # Once per Mac; macOS may ask to approve Keychain access
./scripts/build.sh
```

The script generates `MicRelay.xcodeproj` from `project.yml` and builds `build/Build/Products/Release/Mic Relay.app`. For Xcode editing, run `xcodegen generate` after changing the project spec. App metadata and permissions live in `MicRelay/Info.plist` and `MicRelay/MicRelay.entitlements`; version numbers live in `project.yml`.

```bash
./scripts/build.sh dmg    # Build and package Mic Relay.dmg
./scripts/build.sh clean  # Remove build artifacts and the DMG
```

Local builds use the **Mic Relay Local Development** certificate in your default Keychain. The setup script creates it once, limits its trust to code signing for your user, and removes temporary key files. Keep that identity: it survives `build.sh clean` and repository changes. Xcode and the build script use the same certificate; a missing identity causes a build error instead of falling back to ad-hoc signing. DMG packaging preserves the app's signature.

Open the DMG and drag the app to Applications, replacing the previous copy after quitting it. Run that installed copy consistently. This local signature is not Developer ID signing or notarization; macOS may require approving the app in Privacy & Security. Broader distribution still needs Developer ID signing and notarization.

## First use

1. Open Mic Relay. Setup checks BlackHole and explains the permissions; return anytime using **Setup & Slack Help**.
2. Start Spotify or another music app. In **Music**, click **Find Apps** and choose the source. Spotify is preferred on initial discovery. Choose **None — share files only** if you only want Library/Soundboard.
3. Enable **Include microphone** if you want to add your voice, and select the microphone. App/microphone choices and volumes are remembered.
4. In Slack or another call app, select **BlackHole 2ch** as microphone/input and your real headphones or speakers as output.
5. Click **Start Sharing** and play music. **Stop Sharing** stops all outgoing playback. ⌘Return toggles sharing from the main window.

For Slack music, turn off **noise suppression** and **automatic gain control** in Preferences → Audio & video. These voice-processing features can remove background music or change its level; Mic Relay cannot override them. See [Slack's audio settings guide](https://slack.com/help/articles/1500002037922-Adjust-your-huddles-preferences).

## Library and Soundboard

Use **Add Files** to copy audio into the selected collection. Imports preserve originals and give duplicate filenames a numeric suffix. The options menu also offers Open Folder and Refresh. Common formats include MP3, M4A, WAV, AIFF, CAF, and FLAC.

Files and custom labels stay under `~/Music/Mic Relay/Library/` and `~/Music/Mic Relay/Soundboard/`. Edit a title or emoji, or reset a label, without renaming the audio file. Library discovers nested files and groups `Playlists/<name>/` folders. Soundboard reads files directly in its folder.

While sharing is stopped, playback goes to your Mac's output. While sharing is on, new playback also goes to BlackHole. Starting or stopping sharing stops current tracks/clips, so replay them after changing the destination. You can pause, seek, and navigate Library tracks, or overlap Soundboard clips and use Stop All.

If macOS interrupts a file player's output, Library pauses and keeps its position; press Play to resume. Soundboard stops its clips so they do not unexpectedly restart on a different output.

For optional Library downloads:

```bash
brew install yt-dlp ffmpeg
```

Paste a video or playlist URL in Library and click Download. Downloads are saved as MP3 files; playlists get their own folders. Cancel waits for the downloader to exit before allowing another download.

## Permissions and troubleshooting

- Upgrading from an old ad-hoc build to the stable local signature may require one final permission approval. In Privacy & Security, enable the installed Mic Relay under Screen & System Audio Recording and, if needed, Microphone; then quit and reopen if macOS asks. Subsequent builds signed with the same identity retain a compatible code identity; macOS can still require its own reconfirmation.
- If an old screen-recording entry stays enabled but capture is denied, quit Mic Relay and run `tccutil reset ScreenCapture com.micrelay.app` once, then reopen the installed copy and click Find Apps. If it is missing from Settings, use the **+** button to add `/Applications/Mic Relay.app`. This recovery resets only Mic Relay's recording grant; never reset all apps' permissions or make this a build step.
- App discovery and capture use ScreenCaptureKit, scoped to the selected app. Allow Screen & System Audio Recording when prompted. If apps remain missing, confirm that the source is running and Mic Relay is enabled in that privacy pane; quit/reopen if macOS requests it, then refresh apps. Setup provides a link to the pane. No screen video is saved.
- Microphone permission is requested only when sharing with Include microphone enabled. BlackHole is excluded from the microphone picker. Mic Relay does not need Accessibility permission.
- If BlackHole is missing after installation, restart your Mac and click Check Again in Setup.
- The Music tab meters show captured app audio, microphone audio, and their mix sent to BlackHole. They do not measure Library/Soundboard playback or what a remote participant receives. There is no volume threshold in Mic Relay; the short buffer prefill depends only on time.
- If Music moves but To BlackHole stays silent, stop/start sharing and check for an output error. If To BlackHole moves but Slack cuts out, check Slack's input selection, mute state, noise suppression, and automatic gain control. A receiver-side check is needed to confirm the final call path.
- DRM/protected audio may be silent depending on the source app and macOS.
- If a call echoes, keep its output on real headphones/speakers and avoid capturing the call app or a browser carrying the call.
- Build failures are logged in `build/logs/xcodebuild.log`.

## Development and validation

Audio capture, conversion, mixing, and shared file playback live in `MicRelay/Audio/`; app state and SwiftUI views live in `MicRelay/App/`. Project constraints are in [AGENTS.md](AGENTS.md).

```bash
./scripts/check.sh        # Deterministic checks; no devices or user files
./scripts/build.sh        # Compile the app and resources
./scripts/probe-audio.sh  # Enumerate devices and check for BlackHole
./scripts/check.sh --audio # Optional real audio integration checks
```

There is no Xcode test target. The focused checks compile directly with Swift. They cover PCM layouts and resampling, quiet signals, queue boundaries, playback completion, and non-destructive imports. The optional audio checks measure generated tones through BlackHole at multiple levels, then exercise local/dual-output file playback, label compatibility, and start/stop cancellation with disposable files/preferences. Run them outside a live call: they write tones to BlackHole. They never start a physical microphone or alter system audio defaults. A restrictive sandbox can hide CoreAudio devices; a host without input permission may not allow loopback readback.

For changes affecting capture or UI, confirm the relevant behavior in the app: source discovery, music with/without the selected mic, start/stop, seeking, playlist/search filtering, label editing, and overlapping clips. Download/cancel checks require the optional tools. For end-to-end call validation, select BlackHole as input and real speakers as output, play both quiet and loud music, and have a remote participant confirm continuous audio and no echo. The independent `./scripts/probe-audio.sh --tone-to-blackhole` checks the driver path with a five-second tone; it does not test app capture or Slack processing.

## License

[MIT](LICENSE), copyright Mic Relay contributors.
