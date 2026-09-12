//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import Foundation

/// Receives audio frames from an RNS Link and delivers them to a pipeline Sink.
///
/// Python: `LXST.Network.LinkSource`
public final class LinkSource: RemoteSource {

    /// Link audio is received from.
    public let link: Link
    /// Handler signalling packets are forwarded to.
    public var signallingProxy: (any SignallingHandler)?

    /// Creates a source reading audio from `link`.
    public init(link: Link,
                signallingProxy: (any SignallingHandler)? = nil,
                sink: (any Sink)? = nil) {
        self.link             = link
        self.signallingProxy  = signallingProxy
        super.init()
        self.sink = sink
        setup()
    }

    private func setup() {
        link.onDataReceived = { [weak self] data, _ in
            self?.receive(data: data)
        }
    }

    // MARK: - Receive-path codec construction

    /// Build the codec for a wire header byte, already wired to the sink that plays the
    /// stream.
    ///
    /// Returns nil for a header byte no codec claims.
    ///
    /// The sink is attached **here**, not by the caller, because `decode` configures itself from
    /// it—Opus takes its output rate and channel count from the sink (Python `Opus.py:170,174`)
    /// and Codec2 resamples its fixed 8 kHz output to the sink's rate (`Codec2.py:115-117`). A
    /// codec that reaches its first frame with no sink attached decodes at its own default rate,
    /// which on this path is always 8 kHz whatever the sender chose (`bugs/017`). One function
    /// decides "new receive codec ⇒ attached sink", so a later codec type cannot be added
    /// without it.
    static func makeReceiveCodec(for headerByte: UInt8,
                                 sink: (any Sink)?,
                                 source: (any Source)?) -> (any Codec)? {
        let newCodec: any Codec
        switch headerByte {
        case codecNull:   newCodec = NullCodec()
        case codecRaw:    newCodec = RawCodec()
        case codecOpus:   newCodec = OpusCodec()
        case codecCodec2: newCodec = Codec2Codec()
        default: return nil
        }
        newCodec.sink   = sink
        newCodec.source = source
        return newCodec
    }

    // MARK: - Packet decoding

    private func receive(data: Data) {
        guard let unpacked = try? MsgPack.decode(data),
              case .map(let pairs) = unpacked else { return }

        var dict: [Int: MsgPack.Value] = [:]
        for (k, v) in pairs {
            // Guard the UInt64->Int narrowing: a wire key above Int.max would trap.
            if case .int(let n) = k, let key = Int(exactly: n) { dict[key] = v }
            if case .uint(let n) = k, let key = Int(exactly: n) { dict[key] = v }
        }

        // Handle frames field
        if let framesVal = dict[Int(fieldFrames)],
           case .bytes(let frameBytes) = framesVal, !frameBytes.isEmpty {

            let headerByte = frameBytes[frameBytes.startIndex]
            let payload    = Data(frameBytes.dropFirst())

            // Dynamic codec switching: replace codec if type changed
            if codec.map({ type(of: $0).headerByte != headerByte }) ?? true {
                if let newCodec = LinkSource.makeReceiveCodec(for: headerByte,
                                                              sink: sink, source: self) {
                    codec = newCodec
                    if let pipe = pipeline { pipe.codec = newCodec }
                }
            }

            guard let c = codec else { return }
            guard let frame = try? c.decode(payload) else { return }
            sink?.handleFrame(frame, from: self)
        }

        // Handle signalling field—decode the real integer signal values
        // (Python: LinkSource._packet defers to SignallingReceiver._packet for
        // FIELD_SIGNALLING). A scalar is wrapped in a single-element list.
        if let sigVal = dict[Int(fieldSignalling)] {
            let signals = SignallingReceiver.signalValues(from: sigVal)
            signallingProxy?.signallingReceived(signals, from: self)
        }
    }

    public override func start() { super.start() }
    public override func stop()  { super.stop() }
}
