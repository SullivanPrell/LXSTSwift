import Foundation

/// Receives audio frames from an RNS Link and delivers them to a pipeline Sink.
///
/// Python: `LXST.Network.LinkSource`
public final class LinkSource: RemoteSource {

    public let link: Link
    public var signallingProxy: (any SignallingHandler)?

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

    // MARK: - Packet decoding

    private func receive(data: Data) {
        guard let unpacked = try? MsgPack.decode(data),
              case .map(let pairs) = unpacked else { return }

        var dict: [Int: MsgPack.Value] = [:]
        for (k, v) in pairs {
            if case .int(let n) = k { dict[Int(n)] = v }
            if case .uint(let n) = k { dict[Int(n)] = v }
        }

        // Handle frames field
        if let framesVal = dict[Int(FIELD_FRAMES)],
           case .bytes(let frameBytes) = framesVal, !frameBytes.isEmpty {

            let headerByte = frameBytes[frameBytes.startIndex]
            let payload    = Data(frameBytes.dropFirst())

            // Dynamic codec switching: replace codec if type changed
            if let newCodecType = codecType(for: headerByte) {
                if codec == nil || type(of: codec!).headerByte != headerByte {
                    // Instantiate the right codec type
                    let newCodec: any Codec
                    switch headerByte {
                    case CODEC_NULL:   newCodec = NullCodec()
                    case CODEC_RAW:    newCodec = RawCodec()
                    case CODEC_OPUS:   newCodec = OpusCodec()
                    case CODEC_CODEC2: newCodec = Codec2Codec()
                    default: return
                    }
                    _ = newCodecType  // suppress unused warning
                    codec = newCodec
                    codec?.sink = sink
                    codec?.source = self
                    if let pipe = pipeline { pipe.codec = newCodec }
                }
            }

            guard let c = codec else { return }
            guard let frame = try? c.decode(payload) else { return }
            sink?.handleFrame(frame, from: self)
        }

        // Handle signalling field — decode the real integer signal values
        // (Python: LinkSource._packet defers to SignallingReceiver._packet for
        // FIELD_SIGNALLING). A scalar is wrapped in a single-element list.
        if let sigVal = dict[Int(FIELD_SIGNALLING)] {
            let signals = SignallingReceiver.signalValues(from: sigVal)
            signallingProxy?.signallingReceived(signals, from: self)
        }
    }

    public override func start() { super.start() }
    public override func stop()  { super.stop() }
}
