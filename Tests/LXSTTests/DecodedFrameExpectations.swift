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

// MARK: - The post-condition shared by `bugs/017` and `bugs/018`

/// Assert that a decoded frame is playable by the sink it was decoded for.
///
/// `017` (Opus decodes at the codec profile's rate) and `018` (Codec2 omits the reference's
/// 8 kHz → sink resample and relabels the samples instead) are the same contract broken in two
/// unrelated code paths. Their fixes cannot be shared — Opus can be told to decode at any rate
/// (`Opus.py:170,174`), Codec2 is fixed at 8 kHz and must convert on the way out
/// (`Codec2.py:115-117`) — so what is shared is this post-condition (design D4).
///
/// **The precondition is the point.** Every decode test in this package used to leave
/// `codec.sink` nil, so the codec's own rate was simultaneously the decode rate and the reported
/// rate: the two quantities being compared were one quantity, and no rate defect of any kind
/// could surface. This helper therefore *fails* when the sink's rate equals the codec's, so a
/// future edit that reverts to that construction reports itself instead of quietly becoming
/// vacuous.
///
/// - Parameters:
///   - frame:      the frame returned by `decode`
///   - sink:       the sink attached to the codec at decode time
///   - codecRate:  the codec's own rate — the rate a broken decoder would produce
///   - durationMs: the duration the encoded payload represents, known independently of both rates
///   - file:       the file the assertion is reported against
///   - line:       the line the assertion is reported against
func assertDecoded(_ frame: AudioFrame,
                   playableBy sink: any Sink,
                   codecRate: Double,
                   durationMs: Double,
                   file: StaticString = #filePath,
                   line: UInt = #line) {
    XCTAssertNotEqual(sink.sampleRate, codecRate,
                      """
                      this assertion cannot observe anything when the sink's rate equals the \
                      codec's — that is the construction that hid bugs/017 and bugs/018. Attach \
                      a sink at a differing rate.
                      """,
                      file: file, line: line)

    // Computed from the sink's rate and the payload's duration, so a decoder that returns the
    // codec's own sample count cannot satisfy it — and a decoder that returns the codec's
    // samples carrying the sink's rate as a *label* cannot either.
    let expected = Int((sink.sampleRate * durationMs / 1000).rounded())
    XCTAssertEqual(Double(frame.sampleCount), Double(expected), accuracy: 1,
                   """
                   \(durationMs) ms at the sink's \(sink.sampleRate) Hz is \(expected) samples \
                   per channel; the frame carries \(frame.sampleCount). \
                   \(Int((codecRate * durationMs / 1000).rounded())) would be the codec's own \
                   rate, i.e. no conversion happened.
                   """,
                   file: file, line: line)

    XCTAssertEqual(frame.sampleRate, sink.sampleRate,
                   "a frame handed to a \(sink.sampleRate) Hz sink must declare that rate",
                   file: file, line: line)

    // Python gates the channel adaptation the same way (`Opus.py:169` — `if self.sink and
    // self.sink.channels`), so a sink that declares nothing imposes nothing.
    if let sinkChannels = sink.channels {
        XCTAssertEqual(frame.channelCount, sinkChannels,
                       "a frame handed to a \(sinkChannels)-channel sink must carry that many",
                       file: file, line: line)
    }
}

/// Assert that a converted frame carries signal across its whole length.
///
/// A sample-count assertion alone is satisfied by padding: `bugs/018`'s worked example is "3200
/// real samples at the head, 16000 samples of silence", which has exactly the right length and
/// exactly the right declared rate. Comparing the tail's energy to the head's is what separates
/// a resample from a pad; it needs no second decode, which matters because libcodec2's synthesis
/// uses randomised phase for unvoiced frames and is not reproducible sample-for-sample.
func assertEnergyIsSpreadAcrossTheFrame(_ frame: AudioFrame,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
    func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
    }
    let quarter = frame.samples.count / 4
    guard quarter > 0 else { return XCTFail("frame too short to inspect", file: file, line: line) }

    // Measured against the LOUDEST quarter, not the first: a codec with encoder lookahead —
    // Opus has about 6.5 ms of it — leaves the head of a short frame genuinely near-silent, so
    // comparing the tail to the head would fail on correct output.
    let loudest = (0..<4).map { q in
        rms(frame.samples[(q * quarter) ..< min((q + 1) * quarter, frame.samples.count)])
    }.max() ?? 0
    let tail = rms(frame.samples[(frame.samples.count - quarter)...])
    XCTAssertGreaterThan(loudest, 0.01, "the source signal must carry real energy",
                         file: file, line: line)
    XCTAssertGreaterThan(tail, loudest * 0.25,
                         """
                         the last quarter is near-silent (rms \(tail) against the loudest \
                         quarter's \(loudest)) — the frame was padded to length, not converted.
                         """,
                         file: file, line: line)
}

// MARK: - Test double

/// A sink that carries nothing but a rate and a channel count.
///
/// Deliberately **not** a `LocalSink` subclass. The receive path's real sink is a `Mixer`
/// (`Telephony.swift:1039` hands `receiveMixer` to `LinkSource`, which assigns it to the codec),
/// and `Mixer` conforms to `Sink` directly. A double that subclassed `LocalSink` would agree with
/// the pre-fix `(sink as? LocalSink)?.sampleRate` narrowing in both codecs and so would never
/// exercise the configuration a real call actually uses.
final class RateSink: Sink {
    let channels:   Int?
    let sampleRate: Double
    private(set) var received: [AudioFrame] = []

    init(sampleRate: Double, channels: Int? = nil) {
        self.sampleRate = sampleRate
        self.channels   = channels
    }

    func handleFrame(_ frame: AudioFrame, from source: (any Source)?) { received.append(frame) }
}
