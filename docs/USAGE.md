# Using LXSTSwift

LXSTSwift has two layers: a high-level **Telephone** session manager for calls,
and the lower-level **Pipeline** for arbitrary audio streaming. Both run on a
live ReticulumSwift stack.

## Telephony

`Telephone` owns a delivery destination, handles signalling (ring / answer /
busy / reject / end), and manages the call audio path end to end.

```swift
let phone = Telephone(identity: identity, transport: stack.transport,
                      allowed: .allowAll)
phone.announce()

phone.setRingingCallback     { caller in /* show incoming UI */ }
phone.setEstablishedCallback { _ in /* connected */ }
phone.setEndedCallback       { _ in /* cleanup */ }

phone.call(identity: peer, profile: .voice)   // outbound
_ = phone.answer(identity: peer)              // accept inbound
phone.hangup()
```

- **Call admission**: `setAllowed(.allowAll / .allowList / …)` and
  `setBlocked([...])` gate who may call.
- **Audio control**: `muteTransmit()` / `muteReceive()`,
  `setTransmitGain()` / `setReceiveGain()`.
- **Profiles**: `TelephonyProfile` selects the codec/bitrate trade-off for a call.

## The pipeline

A `Pipeline` connects a `Source` → `Codec` → `Sink`:

```swift
let pipeline = try Pipeline(source: source, codec: codec, sink: sink)
pipeline.start()
pipeline.stop()
pipeline.release()     // break references; required to avoid retain cycles
```

Assigning `pipeline.codec = …` switches codecs mid-stream.

### Sources

| Type | Description |
|------|-------------|
| `LineSource` | Microphone via AVAudioEngine |
| `ToneSource` | Sine-wave generator (`frequency:`) |
| `OpusFileSource` | Play back an Opus file |
| `Loopback` | Source + Sink that feeds itself (testing) |
| `LinkSource` | Audio arriving over an RNS `Link` (the remote end of a call) |

### Sinks

| Type | Description |
|------|-------------|
| `LineSink` | Speaker via AVAudioEngine |
| `OpusFileSink` | Record to an Opus file |
| `Packetizer` | Encode + send frames over an RNS `Link` (the network sink) |
| `Mixer` | Additive multi-source mixing (also a Source) |

### Codecs

| Type | Wire type | Notes |
|------|-----------|-------|
| `RawCodec` | `0x00` | Uncompressed PCM |
| `OpusCodec` | `0x01` | Opus via AVAudioConverter; `OpusProfile` selects bitrate |
| `Codec2Codec` | `0x02` | Very-low-bitrate speech (codec2) |
| `NullCodec` | `0xFF` | Pass-through |

### Filters

`HighPass`, `LowPass`, `BandPass`, and `AGC` (automatic gain control) implement
the `Filter` protocol and can be inserted into the audio path.

## Streaming over the network

To send audio to a peer, the sink is a `Packetizer` bound to an RNS `Link`; the
receiver runs a `LinkSource`. `Telephone` wires this up for you; build it
manually only for custom streaming topologies. See [SPEC.md](../SPEC.md) §5 for
the network layer and §3 for the wire protocol.

## Interop

LXSTSwift frames are wire-compatible with Python LXST, so a Swift node and a
Python node can hold a call. For testing against Python, see ReticulumSwift's
[INTEROP guide](https://github.com/SullivanPrell/ReticulumSwift/blob/main/docs/INTEROP.md).
