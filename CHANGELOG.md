# Changelog

All notable changes to LXSTSwift are documented here. This project follows
[Semantic Versioning](https://semver.org).

## [1.0.0] — Initial public release

First public release of LXSTSwift — a Swift port of
[LXST](https://github.com/markqvist/LXST) (Lightweight Extensible Signal
Transport), wire-compatible with the Python reference (LXST 0.4.6).

### Highlights

- **Real audio I/O** via AVAudioEngine (microphone capture, speaker playback).
- **Codecs**: Opus (AVAudioConverter), Codec2 (very-low-bitrate speech), Raw PCM,
  and Null pass-through.
- **Pipeline**: `Source → Codec → Sink` with mid-stream codec switching and
  explicit `release()` (no retain cycles).
- **Sources / sinks**: microphone, tone, Opus file, loopback, link-source;
  speaker, Opus file, packetizer, and an additive mixer.
- **Filters**: high-pass, low-pass, band-pass, and AGC.
- **Telephony**: the `Telephone` primitive — announce, place/answer/reject/hang
  up calls, mute/gain control, and call-admission lists.
- **Network**: packetize/transmit and receive audio over RNS links.

245 unit tests, 0 failures. Built on ReticulumSwift 1.0.0. Bundles prebuilt
codec2 (LGPL v2.1) and opus (BSD) binaries committed directly.
