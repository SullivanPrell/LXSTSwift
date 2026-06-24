import Foundation

// MARK: - LXSTDestination

/// A destination that can receive LXST packets — either an RNS Link or Destination.
/// Python: `type(self.destination) == RNS.Link` check in `Packetizer.handle_frame`
public protocol LXSTDestination: AnyObject {}
extension Link:        LXSTDestination {}
extension Destination: LXSTDestination {}

// MARK: - Packetizer

/// Packs encoded audio frames into RNS Packets and sends them to a destination.
///
/// Wire format:
///   1. `codec_header_byte + encoded_bytes` → frame_bytes
///   2. `{FIELD_FRAMES: frame_bytes}` → msgpack dict
///   3. `RNS.Packet(destination, msgpack_data)` → sent
///
/// Python: `LXST.Network.Packetizer`
public final class Packetizer: RemoteSink {

    /// The destination to send packets to (RNS.Link or RNS.Destination).
    public var destination: (any LXSTDestination)?

    /// The upstream source, used to look up the active codec type.
    /// Python: `Packetizer.source`
    public weak var source: (any Source)?

    /// True after a transmit failure. Python: `transmit_failure`
    public private(set) var transmitFailure: Bool = false

    /// Called on transmit failure. Python: `failure_callback`
    public var onFailure: (() -> Void)?

    /// Python: `def __init__(self, destination, failure_callback=None)`
    public init(destination: (any LXSTDestination)? = nil,
                onFailure: (() -> Void)? = nil) {
        self.destination = destination
        self.onFailure   = onFailure
    }

    // MARK: - Sink: encode and transmit

    /// Python: `Packetizer.handle_frame(frame, source=None)`
    public override func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        guard let dest = destination else { return }

        // Determine codec from the source
        let codec = source?.codec ?? self.source?.codec
        let headerByte = codec.map { type(of: $0).headerByte } ?? CODEC_NULL

        do {
            let encoded = try codec?.encode(frame) ?? {
                // Null codec: serialise as float32
                var d = Data(capacity: frame.samples.count * 4)
                for var v in frame.samples { d.append(Data(bytes: &v, count: 4)) }
                return d
            }()

            // Prepend codec header byte
            var frameBytes = Data([headerByte])
            frameBytes.append(encoded)

            // Msgpack: {FIELD_FRAMES: frameBytes}
            let packetData = MsgPack.encode(.map([
                (.int(Int64(FIELD_FRAMES)), .bytes(frameBytes))
            ]))

            if let link = dest as? Link {
                guard link.status == .active else { return }
                try link.send(packetData)
            } else if dest is Destination {
                // Destination sending requires an injected Transport — not yet wired
                return
            } else { return }

        } catch {
            transmitFailure = true
            onFailure?()
        }
    }

    public override func start() {}
    public override func stop()  {}
}
