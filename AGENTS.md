# Mic Relay

Swift 6 / SwiftUI app with a menu bar shortcut, macOS 14+. No Swift package dependencies.

- Capture one selected app through ScreenCaptureKit, optionally mix a physical microphone, and write to BlackHole 2ch. Never capture whole-system audio, create aggregate/multi-output devices, or change system audio defaults. Call output stays on real headphones/speakers to prevent echo.
- Request microphone permission only when Include microphone is enabled. App discovery/capture can prompt for Screen & System Audio Recording; keep first access user-initiated. Accessibility permission is not needed. The microphone picker excludes BlackHole.
- One Start/Stop Sharing control governs outgoing audio. Library and Soundboard preview locally while stopped; starting or stopping sharing stops existing playback. Library supports seeking and playlist folders; Soundboard supports overlapping clips.
- Preserve files and label metadata under `~/Music/Mic Relay/`. Library metadata keys are relative paths; Soundboard keys are absolute paths. Downloads optionally use external `yt-dlp` and `ffmpeg`.
- `AudioSampleConverter` handles capture formats; `AudioMixer` bridges capture/render callbacks with a bounded queue and no volume gate. Audio callbacks must not inherit MainActor isolation. Meter updates are sampled at a fixed rate. Both file features use `FilePlaybackEngine`.
- `project.yml` defines the Xcode project and version. The checked-in plist and entitlements define app metadata and permissions; the Xcode project is generated and ignored.
- Keep the local signing identity stable across Xcode builds and DMGs; ad-hoc signing can invalidate macOS permission grants. `./scripts/setup-signing.sh` provisions the identity once in the user's Keychain. Never regenerate it during a build or reset privacy permissions as a build step.

Commands:

- `./scripts/build.sh` generates the project and builds Release; `dmg` also packages it and `clean` removes build artifacts.
- `./scripts/check.sh` runs deterministic conversion, buffer, completion, and import checks using disposable inputs.
- `./scripts/check.sh --audio` exercises real BlackHole output/readback, file playback, and routing lifecycle. It writes synthetic tones to BlackHole and uses silent temporary files; it does not start a physical microphone or change system audio defaults. Run outside a live call.
- `./scripts/probe-audio.sh` independently lists audio devices; `--tone-to-blackhole` writes a five-second tone to BlackHole.

See [README.md](README.md) for setup, troubleshooting, and manual validation. Use checks relevant to the change; device checks need CoreAudio access outside a restrictive sandbox. End-to-end Slack reception cannot be inferred from compilation or a moving meter alone.
