#if canImport(AVFAudio)
import AVFAudio
#endif
import Foundation

/// Speaker/playback sink using AVAudioEngine (or mock backend).
///
/// Python: `LXST.Sinks.LineSink`
/// Params: autodigest (default true), low_latency (default false)
public final class LineSink: LocalSink {
    // MARK: - Python class constants
    /// Python: `LineSink.MAX_FRAMES = 6`
    public static let maxFrames:    Int = 6
    /// Python: `LineSink.AUTOSTART_MIN = 1`
    public static let autoStartMin: Int = 1
    /// Python: `LineSink.FRAME_TIMEOUT = 8`
    public static let frameTimeout: Int = 8

    public var autodigest: Bool  = true
    public var lowLatency: Bool  = false

    private var wantsLowLatency: Bool = false

    /// Python: `LineSink.enable_low_latency()`
    public func enableLowLatency() {
        wantsLowLatency = true
        lowLatency = true
    }

    private var backend: (any AudioBackend)?
    private var player:  (any AudioPlayer)?

    /// Python: `LineSink.__init__(preferred_device=None, autodigest=True, low_latency=False)`
    public init(device: String? = nil,
                autodigest: Bool = true,
                lowLatency: Bool = false,
                backend: (any AudioBackend)? = nil) {
        super.init()
        self.autodigest  = autodigest
        self.lowLatency  = lowLatency
        self.backend     = backend
    }

    public override func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        player?.play(frame)
    }

    public override func start() {
        player = try? backend?.startPlayback(sampleRate: sampleRate, channelCount: channels ?? 1)
    }

    public override func stop() {
        player?.flush()
        backend?.stopPlayback()
        player = nil
    }
}
