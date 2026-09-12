//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Speed formatting

/// Format a bitrate the way Python's `RNS.prettyspeed` does, so codec
/// descriptions read identically across implementations.
///
/// Python: `prettyspeed(num, suffix="b")` == `prettysize(num/8, suffix="b")+"ps"`,
/// and `prettysize` with suffix `"b"` multiplies by 8 again — so the value is
/// carried through unchanged and only the unit scaling applies. Units step by
/// 1000 (not 1024); the base unit prints with no decimals, all others with two.
func prettySpeed(_ bitsPerSecond: Double) -> String {
    let units = ["", "K", "M", "G", "T", "P", "E", "Z"]
    var num = bitsPerSecond
    for unit in units {
        if abs(num) < 1000.0 {
            return unit.isEmpty
                ? String(format: "%.0f %@bps", num, unit)
                : String(format: "%.2f %@bps", num, unit)
        }
        num /= 1000.0
    }
    return String(format: "%.2fYbps", num)
}

// MARK: - Codec descriptions
//
// Mirrors the `__str__` implementations added in LXST 0.5.0 (commit 7ba2b82).
// Purely cosmetic — these strings never travel on the wire.

extension NullCodec: CustomStringConvertible {
    public var description: String { "<LXST/NullCodec>" }
}

extension RawCodec: CustomStringConvertible {
    /// Python: `<LXST/Raw @ {prettyspeed(channels*bitdepth*48000)}>`
    public var description: String {
        let ch = channels ?? 1
        return "<LXST/Raw @ \(prettySpeed(Double(ch * bitDepth * 48000)))>"
    }
}

extension Codec2Codec: CustomStringConvertible {
    /// Python: `<LXST/Codec2 @ {prettyspeed(self.mode)}>` — the Codec2 mode
    /// constant *is* the bitrate in bits per second, and `Codec2Mode`'s raw
    /// value carries the same number.
    public var description: String {
        "<LXST/Codec2 @ \(prettySpeed(Double(mode.rawValue)))>"
    }
}

extension OpusCodec: CustomStringConvertible {
    /// Python: `<LXST/Opus @ {profile_name(self.profile)}>`
    public var description: String { "<LXST/Opus @ \(profile.displayName)>" }
}
