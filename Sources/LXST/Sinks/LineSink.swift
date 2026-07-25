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
        adoptDeviceChannelMapIfChanged()
        player?.play(frame)
    }

    /// Recover when the underlying device re-negotiates its channel map while a
    /// stream is running — a Bluetooth headset switching profile, or a USB
    /// interface being re-plugged, will do this.
    ///
    /// Python (LXST 0.5.0, commit 621d496) simply re-reads
    /// `self.backend.device.channels` in its playback loop and adopts it, so the
    /// per-frame `frame[:, 0:self.channels]` truncation stays correct. Swift has
    /// no such truncation: the channel count is baked into the `AudioPlayer` at
    /// `startPlayback`. So adopting the new count here also means rebuilding the
    /// player, otherwise the sink would keep pushing frames at the stale
    /// geometry and playback would stay broken — the outcome the upstream fix
    /// exists to prevent.
    private func adoptDeviceChannelMapIfChanged() {
        guard let backend else { return }
        let deviceChannels = backend.channelCount
        guard deviceChannels > 0, deviceChannels != (channels ?? deviceChannels) else { return }

        Reticulum.log("Underlying device for LineSink re-configured channel map mid-stream (from \(channels.map(String.init) ?? "nil") to \(deviceChannels))",
                      level: .warning)
        channels = deviceChannels
        player?.flush()
        backend.stopPlayback()
        player = try? backend.startPlayback(sampleRate: sampleRate, channelCount: deviceChannels)
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
