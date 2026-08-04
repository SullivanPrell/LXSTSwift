import Foundation

/// The single dB → linear conversion seam for every gain site in LXST.
///
/// Python converts with the POWER-dB formula `10 ** (dB / 10)` and applies the
/// result directly to amplitude samples. That is nonstandard — the amplitude
/// convention would be `10 ** (dB / 20)` — but it is what the reference does at
/// every gain site, so it is authoritative for parity:
///   - Sources.py:180     `linear_gain(gain_db): return 10**(gain_db/10)`
///   - Mixer.py:102       `_mixing_gain`: `return 10**(self.gain/10)`
///   - Filters.py:187-188 AGC `target_linear`/`max_gain_linear = 10 ** (x / 10)`
///
/// Every Swift dB→linear conversion MUST route through `DBGain.linear`: three
/// live sites (LineSource.deliver, the Mixer mix loop, AGC.handleFrame) each
/// inlined their own `pow(10, dB/20)` and independently drifted to the
/// amplitude convention while a Python-matching helper sat unused.
enum DBGain {
    static func linear(_ gainDB: Double) -> Double { pow(10.0, gainDB / 10.0) }
    static func linear(_ gainDB: Float)  -> Float  { Float(linear(Double(gainDB))) }
}
