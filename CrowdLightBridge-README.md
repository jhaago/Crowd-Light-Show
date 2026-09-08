# CrowdLight Bridge

Native macOS bridge prototype for ProPresenter → CoreMIDI/IAC → Firebase → CrowdLight.

The Swift source lives in the `CrowdLightBridge/` directory. GitHub Actions runs the Swift tests, builds a universal macOS app, validates the bundle/signature/architectures, and uploads an ad-hoc-signed ZIP artifact.

## Current prototype

Version: **0.3**

- macOS 11+
- Apple Silicon (arm64) + Intel (x86_64)
- no third-party libraries
- Apple CoreMIDI
- Firebase Realtime Database over HTTPS/REST
- dedicated controller identity + increasing command revisions
- Firebase server-clock probe using a server timestamp round trip
- stale REST-completion repair
- CoreMIDI multi-packet traversal tests
- selected MIDI-source loss automatically disarms external cues
- startup is idempotent
- external MIDI cues start disabled every launch
- manual BLACKOUT remains available
- SEND TEST CUE buttons deliberately write to the configured CrowdLight room

Firebase authentication is intentionally not implemented yet while the project remains in controlled prototype testing. Do not use the current open/test-mode configuration for a public event.

## MIDI isolation

The intended ProPresenter setup is:

ProPresenter → dedicated macOS IAC bus named **CrowdLight** → CrowdLight Bridge → Firebase → audience phones

The default dedicated MIDI channel is **16**.

CrowdLight Bridge has no MIDI output or MIDI-through path. Existing ProPresenter MIDI devices should remain separate from the CrowdLight IAC bus.

## Cue map

The MIDI note number is authoritative because note-name octave conventions differ between applications. Existing cue numbers 24–30 are preserved; the new effects continue from MIDI 31.

- 24: BLACKOUT
- 25: ALL LIGHTS ON
- 26: SYNC FLASH
- 27: UNISON
- 28: TWINKLE
- 29: SPARKLE
- 30: CONSTELLATION
- 31: SHIMMER
- 32: GLOW
- 33: FIREFLIES
- 34: ALTERNATE
- 35: BUILD
- 36: DROP

## Expanded effects

- **SHIMMER**: phones are spread across fast staggered groups, creating a rapid-looking crowd twinkle while the individual-phone flash ceiling remains enforced.
- **GLOW**: long synchronized ON/OFF holds.
- **FIREFLIES**: sparse deterministic phones glow for longer at different times.
- **ALTERNATE**: two invisible crowd halves swap ON and OFF.
- **BUILD**: participation grows from sparse to full across an eight-beat cycle.
- **DROP**: dark pattern beats followed by a synchronized crowd hit.

The audience application remains responsible for the final individual-phone flashlight safety ceiling and local command expiry.

## Safety / test status

CrowdLight Bridge is still a prototype. Before ProPresenter integration, first test installation and manual/SEND TEST CUE operation on a non-production Mac. Then create the dedicated IAC bus and test MIDI isolation on the actual ProPresenter Mac.

BLACKOUT remains the safest state.
