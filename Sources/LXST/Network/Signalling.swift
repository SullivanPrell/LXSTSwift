import Foundation

// MARK: - SignallingHandler protocol

/// Receives inband signalling events from a `SignallingReceiver`.
///
/// Signals are plain integers, mirroring Python where a signal is either a
/// status code (`0x00`–`0x06`) or the composite `PREFERRED_PROFILE + profile`
/// (e.g. `0xFF + 0x40 = 0x13F`) — which exceeds a single byte, so `Int` (not
/// `UInt8`) is required for the value to round-trip.
/// Python: `SignallingReceiver.proxy`
public protocol SignallingHandler: AnyObject {
    func signallingReceived(_ signals: [Int], from source: (any Source)?)
}

// MARK: - SignallingReceiver

/// Manages inband signalling on a Link — sending and receiving signal events.
///
/// Python: `LXST.Network.SignallingReceiver`
/// Open so that `Telephone` can inherit from it (Python: `class Telephone(SignallingReceiver)`).
open class SignallingReceiver {
    public var proxy: (any SignallingHandler)?

    /// Python: `def __init__(self, proxy=None)`
    public init(proxy: (any SignallingHandler)? = nil) {
        self.proxy = proxy
    }

    /// Register a packet callback on `source` (an RNS Link) to handle signalling.
    /// Python: `handle_signalling_from(source)`
    public func handleSignallingFrom(source: Link) {
        source.onDataReceived = { [weak self] data, _ in
            self?.processSignallingData(data, from: nil)
        }
    }

    /// Send a signal to `destination`.
    ///
    /// Python:
    /// ```
    /// signalling_data = {FIELD_SIGNALLING:[signal]}
    /// RNS.Packet(destination, mp.packb(signalling_data), create_receipt=False).send()
    /// ```
    /// We msgpack-encode the real signal list and transmit it over the link, so
    /// the payload is encrypted with the link key and routed by transport.
    public func signal(_ signal: Int, to destination: any LXSTDestination, immediate: Bool = true) {
        guard immediate else { return }  // non-immediate scheduling TBD (Python has the same TODO)
        let signallingData = Self.encodeSignals([signal])
        if let link = destination as? Link {
            try? link.send(signallingData)
        }
    }

    /// Propagate received signals to proxy.
    /// Python: `signalling_received(signals, source)`
    /// Open so `Telephone` can override it.
    open func signallingReceived(_ signals: [Int], from source: (any Source)?) {
        proxy?.signallingReceived(signals, from: source)
    }

    // MARK: - Wire codec

    /// Encode `{FIELD_SIGNALLING: [signal, ...]}` as msgpack — the exact payload
    /// Python builds via `mp.packb({FIELD_SIGNALLING:[signal]})`.
    static func encodeSignals(_ signals: [Int]) -> Data {
        MsgPack.encode(.map([
            (.int(Int64(FIELD_SIGNALLING)), .array(signals.map { .int(Int64($0)) }))
        ]))
    }

    /// Decode the integer signal list from a received packet. Returns nil if the
    /// packet carries no `FIELD_SIGNALLING` field. A scalar value is wrapped in a
    /// single-element list (Python: `if type(signalling)==list ... else [signalling]`).
    static func decodeSignals(_ data: Data) -> [Int]? {
        guard let unpacked = try? MsgPack.decode(data),
              case .map(let pairs) = unpacked else { return nil }
        for (k, v) in pairs {
            let key: Int
            switch k {
            case .int(let n):  key = Int(n)
            case .uint(let n): key = Int(n)
            default: continue
            }
            guard key == Int(FIELD_SIGNALLING) else { continue }
            return signalValues(from: v)
        }
        return nil
    }

    /// Extract integer signal values from a msgpack value that is either an array
    /// of ints or a single scalar int.
    static func signalValues(from value: MsgPack.Value) -> [Int] {
        switch value {
        case .array(let arr):
            return arr.compactMap { intValue(from: $0) }
        default:
            if let n = intValue(from: value) { return [n] }
            return []
        }
    }

    private static func intValue(from value: MsgPack.Value) -> Int? {
        switch value {
        case .int(let n):  return Int(n)
        case .uint(let n): return Int(n)
        default:           return nil
        }
    }

    // MARK: - Internal

    /// Decode a received signalling packet and dispatch to `signallingReceived`.
    /// Split out from the Link callback so the wire-decode path is testable
    /// without a live Link. Python: `SignallingReceiver._packet`.
    func processSignallingData(_ data: Data, from source: (any Source)?) {
        guard let signals = Self.decodeSignals(data) else { return }
        signallingReceived(signals, from: source)
    }
}
