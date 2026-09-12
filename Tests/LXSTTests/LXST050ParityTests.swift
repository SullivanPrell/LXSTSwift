//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import XCTest

@testable import LXST

/// Parity tests for LXST 0.5.0 codec string formatters (Python commit 7ba2b82)
/// and mid-stream channel-map recovery (commit 621d496).
final class LXST050ParityTests: XCTestCase {

  // MARK: - Opus profile names

  func testOpusProfileDisplayNamesMatchPython() {
    let expected: [OpusProfile: String] = [
      .voiceLow: "Voice, Low",
      .voiceMedium: "Voice, Medium",
      .voiceHigh: "Voice, High",
      .voiceMax: "Voice, Max",
      .audioMin: "Audio, Min",
      .audioLow: "Audio, Low",
      .audioMedium: "Audio, Medium",
      .audioHigh: "Audio, High",
      .audioMax: "Audio, Max",
    ]
    for profile in OpusProfile.allCases {
      XCTAssertEqual(
        profile.displayName, expected[profile],
        "profile \(profile) must match Python's Opus.profile_name")
    }
  }

  // MARK: - prettySpeed

  func testPrettySpeedMatchesPythonFormatting() {
    // Python's prettysize: base unit has no decimals, higher units two,
    // and the scale steps by 1000 rather than 1024.
    XCTAssertEqual(prettySpeed(700), "700 bps")
    XCTAssertEqual(prettySpeed(3200), "3.20 Kbps")
    XCTAssertEqual(prettySpeed(1_536_000), "1.54 Mbps")
  }

  // MARK: - Codec descriptions

  func testCodecDescriptionsMatchPythonFormat() {
    XCTAssertEqual(NullCodec().description, "<LXST/NullCodec>")
    XCTAssertEqual(OpusCodec(profile: .voiceLow).description, "<LXST/Opus @ Voice, Low>")
    XCTAssertEqual(Codec2Codec(mode: .mode3200).description, "<LXST/Codec2 @ 3.20 Kbps>")

    // Raw: channels * bitdepth * 48000 → 1 * 16 * 48000 = 768000 bps
    let raw = RawCodec()
    raw.channels = 1
    raw.bitDepth = 16
    XCTAssertEqual(raw.description, "<LXST/Raw @ 768.00 Kbps>")
  }

  // MARK: - Mid-stream channel-map recovery

  /// A backend whose channel count can change after playback has started,
  /// standing in for a headset switching profile mid-call.
  private final class RemappingBackend: AudioBackend {
    var sampleRate: Double = 48000
    var channelCount: Int
    var bitDepth: Int = 32
    private(set) var playbackStarts: [Int] = []
    private(set) var stopCount = 0

    /// Makes the next startPlayback after the initial one throw, standing in
    /// for AVAudioEngine refusing to start during an in-flight route change.
    var failNextStartAfterFirst = false

    init(channelCount: Int) { self.channelCount = channelCount }

    struct StartFailure: Error {}

    func startCapture(framesPerBuffer: Int, handler: @escaping (AudioFrame) -> Void) throws {}
    func stopCapture() {}
    func startPlayback(sampleRate: Double, channelCount: Int) throws -> any AudioPlayer {
      if failNextStartAfterFirst, !playbackStarts.isEmpty {
        failNextStartAfterFirst = false
        throw StartFailure()
      }
      playbackStarts.append(channelCount)
      return NoopPlayer()
    }
    func stopPlayback() { stopCount += 1 }

    final class NoopPlayer: AudioPlayer {
      func play(_ frame: AudioFrame) {}
      func flush() {}
    }
  }

  func testLineSinkAdoptsDeviceChannelMapChange() {
    let backend = RemappingBackend(channelCount: 1)
    let sink = LineSink(backend: backend)
    // Deliberately NOT setting sink.channels: production code never does,
    // and hand-setting it was what made the earlier version of this test
    // pass against a recovery path that could not fire in a real call.
    sink.start()
    XCTAssertEqual(sink.channels, 1, "start() must adopt the device's channel map")
    XCTAssertEqual(backend.playbackStarts, [1], "playback starts at the initial channel count")

    // Device re-negotiates to stereo mid-stream.
    backend.channelCount = 2
    sink.handleFrame(AudioFrame(samples: [0], channelCount: 1, sampleRate: 48000), from: nil)

    XCTAssertEqual(
      sink.channels, 2,
      "the sink must adopt the device's new channel map instead of staying stale")
    XCTAssertEqual(
      backend.playbackStarts, [1, 2],
      "playback must be rebuilt at the new channel count, or audio stays broken")
    XCTAssertEqual(backend.stopCount, 1)
  }

  /// A failed restart must not leave the sink permanently silent.
  func testLineSinkKeepsPlayingWhenRestartFails() {
    let backend = RemappingBackend(channelCount: 1)
    backend.failNextStartAfterFirst = true
    let sink = LineSink(backend: backend)
    sink.start()

    backend.channelCount = 2
    sink.handleFrame(AudioFrame(samples: [0], channelCount: 1, sampleRate: 48000), from: nil)

    XCTAssertEqual(
      sink.channels, 1,
      "a failed rebuild must not commit the new channel count, or the retry is skipped forever")
    XCTAssertNotNil(
      sink.currentPlayerForTesting,
      "a failed rebuild must fall back to a player at the old geometry, not go silent")

    // The next frame retries and succeeds.
    sink.handleFrame(AudioFrame(samples: [0], channelCount: 1, sampleRate: 48000), from: nil)
    XCTAssertEqual(sink.channels, 2, "the retry must succeed once the backend recovers")
  }

  func testLineSinkDoesNotRestartWhenChannelMapIsStable() {
    let backend = RemappingBackend(channelCount: 2)
    let sink = LineSink(backend: backend)
    sink.start()

    for _ in 0..<5 {
      sink.handleFrame(AudioFrame(samples: [0], channelCount: 2, sampleRate: 48000), from: nil)
    }
    XCTAssertEqual(
      backend.playbackStarts, [2],
      "a stable channel map must not cause a playback restart per frame")
    XCTAssertEqual(backend.stopCount, 0)
  }
}
