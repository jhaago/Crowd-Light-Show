# CrowdLight Bridge

Native macOS bridge prototype for ProPresenter → CoreMIDI/IAC → Firebase → CrowdLight.

The Swift source lives in the `CrowdLightBridge/` directory. GitHub Actions runs the Swift tests, builds a universal macOS app, validates the bundle/signature/architectures, and uploads an ad-hoc-signed ZIP artifact.

## Current prototype

Version: **0.2**

- macOS 11+
- Apple Silicon (arm64) + Intel (x86_64)
- no third-party libraries
- Apple CoreMIDI
- Firebase Realtime Database over HTTPS/REST
- dedicated controller identity + increasing command revisions
- Firebase server-clock probe using a server timestamp round trip
- stale REST-completion repair: if an older command finishes after a newer command, the newest revision is written again
- CoreMIDI multi-packet traversal tests
- selected MIDI-source loss automatically disarms external cues
- startup is idempotent
- external MIDI cues start disabled every launch
- manual BLACKOUT remains available
- SEND TEST CUE buttons deliberately write to the configured live/test CrowdLight room

Firebase authentication is intentionally not implemented yet while the project remains in controlled prototype testing. Do not use the current open/test-mode configuration for a public event.

## MIDI isolation

The intended ProPresenter setup is:

ProPresenter → dedicated macOS IAC bus named **CrowdLight** → CrowdLight Bridge → Firebase → audience phones

The default dedicated MIDI channel is **16**.

CrowdLight Bridge has no MIDI output or MIDI-through path. Existing ProPresenter MIDI devices should remain separate from the CrowdLight IAC bus.

## Cue map

The MIDI note number is authoritative because note-name octave conventions differ between applications.

- 24: BLACKOUT
- 25: ALL LIGHTS ON
- 26: SYNC FLASH
- 27: UNISON
- 28: TWINKLE
- 29: SPARKLE
- 30: CONSTELLATION

## Safety / test status

CrowdLight Bridge is still a prototype. Before ProPresenter integration, first test installation and manual/SEND TEST CUE operation on a non-production Mac. Then create the dedicated IAC bus and test MIDI isolation on the actual ProPresenter Mac.

The audience application remains responsible for the final flashlight safety ceiling and local command expiry. BLACKOUT is the safest state.
