# Changelog

All notable changes to LXSTSwift are documented here. This project follows
[Semantic Versioning](https://semver.org).

## [1.2.0] — LXST 0.5.0 parity and LineSink channel-map recovery

Catches the port up to Python LXST 0.5.0.

### Added

- Codec description formatters — `prettySpeed(_:)` matching Python's 1000-step
  `prettysize`, and `CustomStringConvertible` on `NullCodec`, `RawCodec`,
  `Codec2Codec` and `OpusCodec`.

### Fixed

The mid-stream channel-map adopt — what a Bluetooth headset switching profile,
or a USB interface being re-plugged, triggers — could never run, and would have
lost the player if it had:

- `channels` is nil on a freshly constructed `LineSink`, and the guard read nil
  as "already matches", so the method short-circuited outside tests. `start()`
  now adopts the device's channel count up front, as Python does in
  `LineSink.__init__`.
- Adopting the new count without rebuilding the player left the sink feeding a
  player built for the old geometry: Swift truncates against the *player's*
  format in `AVAudioPlayerAdapter.play` rather than per frame as Python does,
  and that format is fixed at `startPlayback`. The player is now rebuilt —
  flush, stop, start.
- A `startPlayback` that threw — which is exactly what an in-flight
  AVAudioEngine route change produces — left `player` nil while the guard
  reported "no change" forever: permanent one-way silence for the rest of the
  call. The new count is committed only once the rebuild succeeds, and a failed
  rebuild falls back to the previous geometry so the next frame retries.

### Known limitation

On Apple platforms the recovery is still effectively dormant:
`AVAudioEngineBackend.channelCount` is only written in `init`/`startCapture`,
and a `LineSink`'s backend never captures — so nothing updates the value the
guard compares against. Closing that needs an `AVAudioSession` route-change
observer, which is not in this release.

## [1.1.0] – [1.1.4]

Released without changelog entries; see the GitHub releases for those tags.

## [1.0.0] — Initial public release

First public release of LXSTSwift — a Swift port of
[LXST](https://github.com/markqvist/LXST) (Lightweight Extensible Signal
Transport), wire-compatible with the Python reference (LXST 0.4.6).

### Highlights

- **Audio I/O** via AVAudioEngine (microphone capture, speaker playback).
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

Covered by 245 unit tests (~58% line coverage; audio-hardware paths run
on-device). Built on ReticulumSwift 1.0.0. Bundles prebuilt codec2 (LGPL v2.1)
and opus (BSD) binaries.
