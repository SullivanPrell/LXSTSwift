# Changelog

All notable changes to LXSTSwift are documented here. This project follows
[Semantic Versioning](https://semver.org).

## [Unreleased]—LXST 0.5.3 parity

Catches the port up to Python LXST 0.5.3.

### Added

- **Loudspeaker routing on a call**—`Telephone.enableLoudspeaker(_:)`,
  `disableLoudspeaker(_:)`, `loudspeakerOn` and `loudspeakerDevice`. Switching
  rebuilds the receive sink and its pipeline on the other device and restarts the
  mixer, and does so only when the setting changed (`Telephony.py:551-559`,
  `:676-688`). The flag clears with the mute flags when a call ends.
- **`AGC.paused`**, with `Telephone.pauseAGC(_:)` and `resumeAGC(_:)` driven from
  `squelchTransmit` and `unsquelchTransmit`, so a half-duplex call no longer spends
  its squelched stretch winding the gain up against the noise floor
  (`Filters.py:189`, `:202`; `Telephony.py:561-570`, `:777-778`).
- **`Telephone.disableRemoteModeFollow()`**, after which a mode switch signalled by
  the peer is ignored and the local side keeps control (`Telephony.py:591-599`).
- **Gain on `OpusFileSource` and `FilePlayer`**, in decibels through the same
  power-dB seam as every other gain site (`Sources.py:291-292`, `:384`;
  `Players.py:13`, `:28-35`).
- `LineSink.device` records the route the sink was built for. Selecting the device
  belongs to the injected `AudioBackend`.

### Fixed

- **A stop immediately followed by a start could leave two mix loops running on one
  `Mixer`.** `stop()` only clears the run flag, so the loop runs on until it next
  reads it, while `start()` spawned a second thread; a 500-iteration restart storm
  reached 501 concurrent loops. `mixerJob` now returns when a loop is already
  running, as `if self.mixer_lock.locked(): return` does upstream (`Mixer.py:105`).
  Switching a call's playback device is exactly that stop-then-start.

### Audited, not ported

- `LineSink.streaming`, `wait_for_frames()` and the underrun sleep (`Sinks.py:148`,
  `:190-195`, `:229`), and `Telephone.__update_output_buffer_targets`
  (`Telephony.py:660-669`): there is no frame deque or playback loop here to starve.
  `LineSink.handleFrame` hands each frame straight to an `AVAudioPlayerNode`, which
  does the buffering.
- Moving `codec.encode` inside the `can_receive` guard, under a try/except
  (`Sources.py:271-277`, `:393-398`): the encode already sits inside the sink, in
  `Packetizer.handleFrame`'s `do`/`catch`, and `Mixer.handleFrame` enforces the same
  per-source limit that `can_receive` reports.
- `Pipeline`'s added `source._sink = sink` for a `Mixer` source (`Pipeline.py:29`):
  the setter it bypasses assigns that same field, and the line above it already ran
  `self.source.sink = sink`. Pinned by a test.
- The `EchoSuppressor` try/except (`Filters.py:874-876`) and the `RNS.sl()` log
  gates: `log10` cannot throw in Swift, and `Reticulum.log` already checks the level.
- The 0.5 s ringtone debounce (`Telephony.py:701`) and
  `Platforms/linux/soundcard.py`: this port has no ringer pipeline and no Linux
  backend.

### Known limitation

`FilePlayer` holds `gain`, `path`, `loop` and the running flag, but builds no
pipeline, so nothing reads the gain. Python's `FilePlayer` wires
`OpusFileSource` → `Raw` → `Loopback` → `LineSink` (`Players.py:22-24`, `:75`).

## [1.3.0]—sample-rate handling and the dB gain convention

### Fixed

- **All three live dB→linear gain sites used the amplitude convention
  `10^(dB/20)`; Python uses the power-dB formula `10^(dB/10)` at every gain
  site** (`Sources.py:180`, `Mixer.py:102`, `Filters.py:187-188`—nonstandard,
  but authoritative for parity). The Python-matching helper
  `LineSource.linearGain` existed but was dead code: its only callers were
  helper-only tests, while `LineSource.deliver`, the `Mixer` mix loop and
  `AGC.handleFrame` each inlined their own `pow(10, dB/20)`. Consequence: the
  AGC in the default call transmit chain (`AGC(targetLevel: -15)`,
  Telephony.swift:993 / Python Telephony.py:711) normalized transmitted mic
  audio to RMS `10^(-0.75)` ≈ 0.178 instead of Python's `10^(-1.5)` ≈ 0.0316—~5.6x
  louder payload audio by default—and any nonzero configured gain
  applied the square root of Python's multiplier (10 dB → ×3.16 instead of
  ×10). All conversions now route through a single internal seam
  (`DBGain.linear`), so the convention cannot drift per-site again; new tests
  drive frames through the live paths against hardcoded Python-derived sample
  values. Wire format untouched—payload sample values only.

## [1.2.0]—LXST 0.5.0 parity and LineSink channel-map recovery

Catches the port up to Python LXST 0.5.0.

### Added

- Codec description formatters—`prettySpeed(_:)` matching Python's 1000-step
  `prettysize`, and `CustomStringConvertible` on `NullCodec`, `RawCodec`,
  `Codec2Codec` and `OpusCodec`.

### Fixed

The mid-stream channel-map adopt—what a Bluetooth headset switching profile,
or a USB interface being re-plugged, triggers—could never run, and would have
lost the player if it had:

- `channels` is nil on a freshly constructed `LineSink`, and the guard read nil
  as already matching, so the method short-circuited outside tests. `start()`
  now adopts the device's channel count up front, as Python does in
  `LineSink.__init__`.
- Adopting the new count without rebuilding the player left the sink feeding a
  player built for the old geometry: Swift truncates against the *player's*
  format in `AVAudioPlayerAdapter.play` rather than per frame as Python does,
  and that format is fixed at `startPlayback`. The player is now rebuilt—flush,
  stop, start.
- A `startPlayback` that threw—which is exactly what an in-flight
  AVAudioEngine route change produces—left `player` nil while the guard
  reported "no change" forever: permanent one-way silence for the rest of the
  call. The new count is committed only once the rebuild succeeds, and a failed
  rebuild falls back to the previous geometry so the next frame retries.

### Known limitation

On Apple platforms the recovery is still effectively dormant:
`AVAudioEngineBackend.channelCount` is only written in `init`/`startCapture`,
and a `LineSink`'s backend never captures—so nothing updates the value the
guard compares against. Closing that needs an `AVAudioSession` route-change
observer, which is not in this release.

## [1.1.0]–[1.1.4]

Released without changelog entries; see the GitHub releases for those tags.

## [1.0.0]—initial public release

First public release of LXSTSwift—a Swift port of
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
- **Telephony**: the `Telephone` primitive—announce, place/answer/reject/hang
  up calls, mute/gain control, and call-admission lists.
- **Network**: packetize/transmit and receive audio over RNS links.

Covered by 245 unit tests (~58% line coverage; audio-hardware paths run
on-device). Built on ReticulumSwift 1.0.0. Bundles prebuilt codec2 (LGPL v2.1)
and opus (BSD) binaries.
