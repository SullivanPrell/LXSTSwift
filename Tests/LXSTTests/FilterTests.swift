import XCTest
@testable import LXST

/// Tests for Filter constants and protocol conformance.
final class FilterTests: XCTestCase {

    // MARK: - AGC default constants (Python: AGC default params)

    func testAGCDefaultTargetLevel() {
        XCTAssertEqual(AGC.defaultTargetLevel,  -12.0,  accuracy: 0.001)
    }
    func testAGCDefaultMaxGain() {
        XCTAssertEqual(AGC.defaultMaxGain,       12.0,  accuracy: 0.001)
    }
    func testAGCDefaultAttackTime() {
        XCTAssertEqual(AGC.defaultAttackTime,    0.0001, accuracy: 1e-6)
    }
    func testAGCDefaultReleaseTime() {
        XCTAssertEqual(AGC.defaultReleaseTime,   0.002,  accuracy: 1e-6)
    }
    func testAGCDefaultHoldTime() {
        XCTAssertEqual(AGC.defaultHoldTime,      0.001,  accuracy: 1e-6)
    }

    // MARK: - Filter protocol conformance

    func testHighPassConformsToFilter() {
        let f: any Filter = HighPass(cut: 100)
        XCTAssertNotNil(f)
        XCTAssertEqual((f as! HighPass).cut, 100)
    }

    func testLowPassConformsToFilter() {
        let f: any Filter = LowPass(cut: 8000)
        XCTAssertNotNil(f)
        XCTAssertEqual((f as! LowPass).cut, 8000)
    }

    func testBandPassConformsToFilter() {
        let f = BandPass(lowCut: 25, highCut: 24000)
        XCTAssertEqual(f.lowCut,  25.0)
        XCTAssertEqual(f.highCut, 24000.0)
    }

    // MARK: - Filter output frame has same channel count and sample rate

    func testHighPassPreservesDimensions() {
        let hp = HighPass(cut: 300)
        let frame = AudioFrame(samples: [Float](repeating: 0.1, count: 48),
                               channelCount: 1, sampleRate: 48000)
        let out = hp.handleFrame(frame)
        XCTAssertEqual(out.channelCount, frame.channelCount)
        XCTAssertEqual(out.sampleRate,   frame.sampleRate)
        XCTAssertEqual(out.samples.count, frame.samples.count)
    }

    func testLowPassPreservesDimensions() {
        let lp  = LowPass(cut: 5000)
        let frame = AudioFrame(samples: [Float](repeating: 0.1, count: 32),
                               channelCount: 1, sampleRate: 48000)
        let out = lp.handleFrame(frame)
        XCTAssertEqual(out.samples.count, frame.samples.count)
    }

    func testAGCProcessesSilentFrameWithoutCrash() {
        let agc   = AGC()
        let frame = AudioFrame.silence(sampleCount: 256, channelCount: 1, sampleRate: 48000)
        let out   = agc.handleFrame(frame)
        XCTAssertEqual(out.samples.count, 256)
    }
}
