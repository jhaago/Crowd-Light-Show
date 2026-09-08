# CrowdLight Bridge

Native macOS bridge prototype for ProPresenter → CoreMIDI/IAC → Firebase → CrowdLight.

The source is currently stored in \`CrowdLightBridge-source.zip\`. A GitHub Actions workflow builds an ad-hoc-signed macOS app artifact automatically.

v0.1 targets macOS 11+ and deliberately uses no third-party libraries. External MIDI cues start disabled for safety. The app includes manual controls and Simulate Cue buttons so it can be tested on a Mac without ProPresenter.

Current default MIDI channel: 16.

Current cue map by MIDI note number:
- 24: BLACKOUT
- 25: ALL LIGHTS ON
- 26: SYNC FLASH
- 27: UNISON
- 28: TWINKLE
- 29: SPARKLE
- 30: CONSTELLATION

The MIDI note number is authoritative because note-name octave conventions vary between applications.
