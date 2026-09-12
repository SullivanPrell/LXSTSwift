//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

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
    /// Maximum frames buffered before playback.
    ///
    /// Python: `LineSink.MAX_FRAMES = 6`
    public static let maxFrames:    Int = 6
    /// Frames buffered before playback starts.
    ///
    /// Python: `LineSink.AUTOSTART_MIN = 1`
    public static let autoStartMin: Int = 1
    /// Frames of silence after which playback stops.
    ///
    /// Python: `LineSink.FRAME_TIMEOUT = 8`
    public static let frameTimeout: Int = 8

    /// Whether frames are decoded on arrival.
    public var autodigest: Bool  = true
    /// Whether playback runs in low-latency mode.
    public var lowLatency: Bool  = false

    private var wantsLowLatency: Bool = false

    /// Switches playback to low-latency mode.
    ///
    /// Python: `LineSink.enable_low_latency()`
    public func enableLowLatency() {
        wantsLowLatency = true
        lowLatency = true
    }

    private var backend: (any AudioBackend)?
    private var player:  (any AudioPlayer)?

    /// Test hook: whether a player is currently held.
    ///
    /// Used to assert that a
    /// failed channel-map rebuild does not leave the sink silent.
    var currentPlayerForTesting: (any AudioPlayer)? { player }

    /// Creates a sink playing on `device`.
    ///
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
    /// stream is running—a Bluetooth headset switching profile, or a USB
    /// interface being re-plugged, does this.
    ///
    /// Python (LXST 0.5.0, commit 621d496) re-reads `self.backend.device.channels`
    /// in its playback loop and adopts it, so the per-frame
    /// `frame[:, 0:self.channels]` truncation stays correct. Swift truncates in
    /// `AVAudioPlayerAdapter.play` against the *player's* format instead, and
    /// that format is fixed at `startPlayback`—so adopting the new count here
    /// also means rebuilding the player, or the sink keeps feeding a player
    /// built for the old geometry.
    ///
    /// `channels` is only committed once the rebuild succeeds, and a failed
    /// rebuild falls back to a player at the previous geometry. Committing the
    /// new count unconditionally meant a `startPlayback` that threw (an
    /// AVAudioEngine route change still in flight is exactly when that happens)
    /// left `player == nil` while the guard below reported "no change" forever—permanent
    /// one-way silence for the rest of the call. Python cannot hit
    /// that: it never touches the player at all.
    private func adoptDeviceChannelMapIfChanged() {
        guard let backend else { return }
        let deviceChannels = backend.channelCount
        // `channels == nil` means "not yet adopted", which must trigger the
        // adopt path rather than short-circuit it—`LineSink.init` does not set
        // `channels`, so nil is the normal production state and treating it as
        // "already matches" made this whole method unreachable outside tests.
        guard deviceChannels > 0, deviceChannels != channels else { return }

        Reticulum.log("Underlying device for LineSink re-configured channel map mid-stream (from \(channels.map(String.init) ?? "nil") to \(deviceChannels))",
                      level: .warning)

        // Only rebuild a player that actually exists; before start() there is
        // nothing to rebuild and adopting the count is enough.
        guard player != nil else {
            channels = deviceChannels
            return
        }

        let previousChannels = channels
        player?.flush()
        backend.stopPlayback()
        if let replacement = try? backend.startPlayback(sampleRate: sampleRate,
                                                        channelCount: deviceChannels) {
            player = replacement
            channels = deviceChannels
        } else {
            // The restart failed (an AVAudioEngine route change still in flight
            // does this). Come back up at the PREVIOUS geometry rather than
            // leaving `player` nil, and leave `channels` untouched so the next
            // frame retries the adopt. Committing the new count here would make
            // the guard above report "no change" forever and the sink would stay
            // silent for the rest of the call.
            Reticulum.log("Could not restart playback at \(deviceChannels) channels; falling back to \(previousChannels.map(String.init) ?? "1")",
                          level: .warning)
            player = try? backend.startPlayback(sampleRate: sampleRate,
                                                channelCount: previousChannels ?? 1)
        }
    }

    public override func start() {
        // Adopt the device's channel map up front, as Python does in
        // `LineSink.__init__` (`self.channels = self.backend.device.channels`).
        // Without this `channels` stays nil for the sink's whole life and the
        // mid-stream recovery above has no baseline to compare against.
        if channels == nil, let deviceChannels = backend?.channelCount, deviceChannels > 0 {
            channels = deviceChannels
        }
        player = try? backend?.startPlayback(sampleRate: sampleRate, channelCount: channels ?? 1)
    }

    public override func stop() {
        player?.flush()
        backend?.stopPlayback()
        player = nil
    }
}
