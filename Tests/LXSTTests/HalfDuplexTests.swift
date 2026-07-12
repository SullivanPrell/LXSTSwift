import XCTest
@testable import LXST

/// Tests for the half-duplex telephony mode + combined signalling ported from
/// Python LXST 0.5.0 (commits 1b77f0b "Added half-duplex mode", 5564cc2 "Allow
/// call mode signalling before answer", 61c2c2b "Combined signalling").
///
/// The signalling constants and wire encoding are the interop-critical surface:
/// a Python LXST 0.5.0 peer sends `PREFERRED_MODE + call_mode` composites and
/// combined `[PREFERRED_PROFILE+profile, PREFERRED_MODE+mode]` lists, and these
/// values must round-trip byte-for-byte.
final class HalfDuplexTests: XCTestCase {

    // MARK: - Signalling.PREFERRED_MODE constant

    func testPreferredModeConstant() {
        XCTAssertEqual(SIGNALLING_PREFERRED_MODE, 0xF0,
                       "Python: Signalling.PREFERRED_MODE = 0xF0")
    }

    /// Mode composites (0xF1/0xF2) must sit strictly below PREFERRED_PROFILE
    /// (0xFF) so the receive handler can distinguish them from profile composites.
    func testModeCompositesBelowProfileMarker() {
        XCTAssertLessThan(Int(SIGNALLING_PREFERRED_MODE) + Int(CallMode.halfDuplex.rawValue),
                          Int(SIGNALLING_PREFERRED_PROFILE),
                          "Mode composites must be < PREFERRED_PROFILE to avoid overlap")
    }

    // MARK: - CallMode enum (Python: Profiles.MODE_*)

    func testCallModeRawValues() {
        XCTAssertEqual(CallMode.fullDuplex.rawValue, 0x01, "Python: MODE_FULL_DUPLEX = 0x01")
        XCTAssertEqual(CallMode.halfDuplex.rawValue, 0x02, "Python: MODE_HALF_DUPLEX = 0x02")
    }

    func testCallModeDefaultIsFullDuplex() {
        XCTAssertEqual(CallMode.defaultMode, .fullDuplex,
                       "Python: Profiles.DEFAULT_MODE = MODE_FULL_DUPLEX")
    }

    func testCallModeAvailableOrder() {
        XCTAssertEqual(CallMode.available, [.fullDuplex, .halfDuplex],
                       "Python: Profiles.available_modes() = [FULL, HALF]")
    }

    func testCallModeNames() {
        XCTAssertEqual(CallMode.fullDuplex.name, "Full Duplex")
        XCTAssertEqual(CallMode.halfDuplex.name, "Half Duplex")
    }

    func testCallModeAbbreviations() {
        // Python preserves the "abbrevation" typo; the abbreviations themselves are FDX/HDX.
        XCTAssertEqual(CallMode.fullDuplex.abbreviation, "FDX")
        XCTAssertEqual(CallMode.halfDuplex.abbreviation, "HDX")
    }

    // MARK: - Combined signalling wire round-trip (Python: 61c2c2b)

    /// A combined `[PREFERRED_PROFILE+profile, PREFERRED_MODE+mode]` list must
    /// encode into one FIELD_SIGNALLING array and decode back to the same two
    /// composite ints — exactly what a Python 0.5.0 caller emits at ringing.
    func testCombinedProfileAndModeSignalRoundTrip() {
        let profileComposite = Int(SIGNALLING_PREFERRED_PROFILE) + Int(TelephonyProfile.qualityHigh.rawValue)
        let modeComposite    = Int(SIGNALLING_PREFERRED_MODE) + Int(CallMode.halfDuplex.rawValue)
        let data = SignallingReceiver.encodeSignals([profileComposite, modeComposite])
        let decoded = SignallingReceiver.decodeSignals(data)
        XCTAssertEqual(decoded, [profileComposite, modeComposite],
                       "Combined profile+mode signalling must round-trip as a 2-element list")
    }

    /// The decoded mode composite must map back to the correct CallMode.
    func testModeCompositeDecodesToMode() {
        for mode in CallMode.available {
            let composite = Int(SIGNALLING_PREFERRED_MODE) + Int(mode.rawValue)
            let data = SignallingReceiver.encodeSignals([composite])
            guard let decoded = SignallingReceiver.decodeSignals(data)?.first else {
                return XCTFail("mode composite failed to decode")
            }
            let modeRaw = decoded - Int(SIGNALLING_PREFERRED_MODE)
            XCTAssertEqual(CallMode(rawValue: UInt8(modeRaw)), mode,
                           "PREFERRED_MODE composite must decode back to \(mode)")
        }
    }

    // MARK: - SignallingReceiver.signal list overload (Python: 61c2c2b)

    /// The list-accepting `signal(_:to:)` overload must encode the whole list
    /// into a single FIELD_SIGNALLING array (not one packet per code).
    func testSignalListOverloadEncodesAllCodes() {
        let signals = [0x04, Int(SIGNALLING_PREFERRED_PROFILE) + 0x40,
                       Int(SIGNALLING_PREFERRED_MODE) + Int(CallMode.halfDuplex.rawValue)]
        let data = SignallingReceiver.encodeSignals(signals)
        XCTAssertEqual(SignallingReceiver.decodeSignals(data), signals,
                       "signal([...]) must carry every code in one packet")
    }

    // MARK: - Packetizer squelch (Python: 1b77f0b)

    func testPacketizerSquelchedDefaultsFalse() {
        let pkt = Packetizer()
        XCTAssertFalse(pkt.squelched, "Packetizer must start unsquelched")
    }

    func testPacketizerSquelchSetsFlag() {
        let pkt = Packetizer()
        pkt.squelch()
        XCTAssertTrue(pkt.squelched, "squelch() must set squelched = true")
    }

    func testPacketizerUnsquelchClearsFlag() {
        let pkt = Packetizer()
        pkt.squelch()
        pkt.unsquelch()
        XCTAssertFalse(pkt.squelched, "unsquelch() must set squelched = false")
    }

    // MARK: - Telephone mode state

    func testTelephoneActiveModeNilWhenIdle() {
        let phone = Telephone(identity: Identity(), transport: Transport())
        XCTAssertNil(phone.activeMode, "active_mode must be nil with no active call")
    }
}
