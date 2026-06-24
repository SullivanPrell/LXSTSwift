import Foundation

// MARK: - Sink protocol

/// A destination for audio frames in an LXST pipeline.
/// Python: `LXST.Sinks.Sink`
public protocol Sink: AnyObject {
    var channels:    Int?   { get }
    var sampleRate:  Double { get }

    /// Receive and process an audio frame.
    /// Python: `Sink.handle_frame(frame, source, decoded=False)`
    func handleFrame(_ frame: AudioFrame, from source: (any Source)?)

    /// Whether this sink can accept a frame from `source`.
    /// Python: `Sink.can_receive(from_source=None) -> True`
    func canReceive(from source: (any Source)?) -> Bool

    func start()
    func stop()
    /// Release sink resources and stop.
    /// Python: `Sink.release()` (commit 2730af9)
    func release()
}

// MARK: - Default implementations

public extension Sink {
    func start()   {}
    func stop()    {}
    func release() { stop() }
    func canReceive(from source: (any Source)?) -> Bool { true }
}

// MARK: - LocalSink base class

/// Base for sinks that deliver audio to local hardware or files.
/// Python: `LXST.Sinks.LocalSink`
open class LocalSink: Sink {
    public var channels:   Int?   = nil
    public var sampleRate: Double = 48000

    public init() {}

    open func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {}
    open func start() {}
    open func stop()  {}
}

// MARK: - RemoteSink base class

/// Base for sinks that send audio over the network.
/// Python: `LXST.Sinks.RemoteSink`
open class RemoteSink: Sink {
    public var channels:   Int?   = nil
    public var sampleRate: Double = 48000

    public init() {}

    open func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {}
    open func start() {}
    open func stop()  {}
}
