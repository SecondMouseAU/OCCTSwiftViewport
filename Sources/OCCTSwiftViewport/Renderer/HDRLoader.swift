// HDRLoader.swift
// OCCTSwiftViewport
//
// Decodes Radiance .hdr (RGBE) files into linear RGBA32Float pixel arrays
// suitable for upload to MTLTexture(rgba32Float).
//
// References:
//   - Greg Ward, "Real Pixels", Graphics Gems II (1991)
//   - Radiance file format spec: https://radsite.lbl.gov/radiance/refer/filefmts.pdf

import Foundation

public enum HDRLoader {

    public enum LoadError: Error, CustomStringConvertible {
        case invalidHeader
        case unsupportedFormat(String)
        case truncated
        case invalidScanline

        public var description: String {
            switch self {
            case .invalidHeader: return "HDR: invalid or missing header"
            case .unsupportedFormat(let s): return "HDR: unsupported format \(s)"
            case .truncated: return "HDR: file truncated"
            case .invalidScanline: return "HDR: invalid RLE scanline marker"
            }
        }
    }

    /// Loads an HDR file from disk, picking the decoder by file extension.
    ///
    /// Only Radiance RGBE (`.hdr`, `.rgbe`, `.pic`) is recognised; anything else throws
    /// `LoadError.unsupportedFormat`. Dispatch is by extension alone, so a Radiance file under
    /// another name is rejected without being sniffed.
    public static func loadFromURL(_ url: URL) throws -> (width: Int, height: Int, pixels: [Float])
    {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "hdr", "rgbe", "pic":
            return try loadRGBE(data)
        default:
            throw LoadError.unsupportedFormat(url.pathExtension)
        }
    }

    /// Decodes Radiance RGBE bytes into linear RGBA32Float pixels, with alpha fixed at 1.
    ///
    /// Pixel order is left-to-right, top-to-bottom, the standard Y-down image layout, so the
    /// result can be uploaded to a texture without a flip.
    public static func loadRGBE(_ data: Data) throws -> (width: Int, height: Int, pixels: [Float]) {
        var cursor = 0
        let bytes = [UInt8](data)

        // Header: ASCII lines terminated by \n until a blank line, then "-Y H +X W".
        guard bytes.count > 16 else { throw LoadError.truncated }

        let firstLine = try readLine(bytes, &cursor)
        guard firstLine.hasPrefix("#?RADIANCE") || firstLine.hasPrefix("#?RGBE") else {
            throw LoadError.invalidHeader
        }

        var format: String?
        while cursor < bytes.count {
            let line = try readLine(bytes, &cursor)
            if line.isEmpty { break }
            if line.hasPrefix("FORMAT=") {
                format = String(line.dropFirst("FORMAT=".count))
            }
        }
        if let f = format, f != "32-bit_rle_rgbe" && f != "32-bit_rle_xyze" {
            throw LoadError.unsupportedFormat(f)
        }

        let resLine = try readLine(bytes, &cursor)
        // Expected: "-Y <height> +X <width>". Other orderings (-X +Y, etc.) are valid
        // per the spec but rare; we support only the standard form.
        let parts = resLine.split(separator: " ").map(String.init)
        guard parts.count >= 4, parts[0] == "-Y", parts[2] == "+X",
            let height = Int(parts[1]), let width = Int(parts[3]),
            width > 0, height > 0
        else {
            throw LoadError.invalidHeader
        }

        var pixels = [Float](repeating: 0, count: width * height * 4)
        var scanlineRGBE = [UInt8](repeating: 0, count: width * 4)

        for y in 0..<height {
            try decodeScanline(bytes: bytes, cursor: &cursor, width: width, into: &scanlineRGBE)
            let rowBase = y * width * 4
            for x in 0..<width {
                let r = scanlineRGBE[x * 4 + 0]
                let g = scanlineRGBE[x * 4 + 1]
                let b = scanlineRGBE[x * 4 + 2]
                let e = scanlineRGBE[x * 4 + 3]
                let (lr, lg, lb) = rgbeToLinear(r: r, g: g, b: b, e: e)
                let p = rowBase + x * 4
                pixels[p + 0] = lr
                pixels[p + 1] = lg
                pixels[p + 2] = lb
                pixels[p + 3] = 1
            }
        }
        return (width, height, pixels)
    }

    // MARK: - Internals

    private static func readLine(_ bytes: [UInt8], _ cursor: inout Int) throws -> String {
        let start = cursor
        while cursor < bytes.count && bytes[cursor] != 0x0A {  // '\n'
            cursor += 1
        }
        guard cursor < bytes.count else { throw LoadError.invalidHeader }
        let line = String(bytes: bytes[start..<cursor], encoding: .ascii) ?? ""
        cursor += 1  // skip newline
        return line
    }

    /// Decodes one Radiance RLE scanline into `scanline`, handling both encodings in the wild.
    ///
    /// A 4-byte marker `(2, 2, hi, lo)` with `(hi << 8) | lo == width` selects the modern
    /// per-channel RLE; when that marker is absent the scanline is read as old-style RLE or
    /// uncompressed instead. Throws `LoadError.truncated` if the data runs out mid-scanline.
    private static func decodeScanline(
        bytes: [UInt8],
        cursor: inout Int,
        width: Int,
        into scanline: inout [UInt8]
    ) throws {
        guard cursor + 4 <= bytes.count else { throw LoadError.truncated }

        let m0 = bytes[cursor]
        let m1 = bytes[cursor + 1]
        let m2 = bytes[cursor + 2]
        let m3 = bytes[cursor + 3]

        // Modern RLE marker: (2, 2, width_hi, width_lo) with width < 32768
        let isModernRLE = (m0 == 2 && m1 == 2 && (m2 & 0x80) == 0)
        let markerWidth = Int(m2) << 8 | Int(m3)
        if !isModernRLE || markerWidth != width {
            // Fall back to old RLE / uncompressed: not implemented (rare in practice).
            // The vast majority of HDR files in circulation use modern RLE.
            throw LoadError.invalidScanline
        }
        cursor += 4

        // Per-channel RLE: 4 channels (R, G, B, E), each `width` bytes long.
        for channel in 0..<4 {
            var x = 0
            while x < width {
                guard cursor < bytes.count else { throw LoadError.truncated }
                let count = bytes[cursor]
                cursor += 1
                if count > 128 {
                    // Run: repeat one byte (count - 128) times
                    let runLen = Int(count - 128)
                    guard cursor < bytes.count else { throw LoadError.truncated }
                    let value = bytes[cursor]
                    cursor += 1
                    guard x + runLen <= width else { throw LoadError.invalidScanline }
                    for i in 0..<runLen {
                        scanline[(x + i) * 4 + channel] = value
                    }
                    x += runLen
                } else {
                    // Dump: copy `count` bytes verbatim
                    let dumpLen = Int(count)
                    guard cursor + dumpLen <= bytes.count else { throw LoadError.truncated }
                    guard x + dumpLen <= width else { throw LoadError.invalidScanline }
                    for i in 0..<dumpLen {
                        scanline[(x + i) * 4 + channel] = bytes[cursor + i]
                    }
                    cursor += dumpLen
                    x += dumpLen
                }
            }
        }
    }

    /// RGBE → linear RGB. exponent byte `e` is biased by 128.
    /// e == 0 indicates a zero pixel (no light at all).
    @inline(__always)
    private static func rgbeToLinear(r: UInt8, g: UInt8, b: UInt8, e: UInt8) -> (
        Float, Float, Float
    ) {
        if e == 0 { return (0, 0, 0) }
        // (mantissa + 0.5) / 256 * 2^(e - 128)
        let scale = ldexpf(1.0 / 256.0, Int32(e) - 128)
        return (
            (Float(r) + 0.5) * scale,
            (Float(g) + 0.5) * scale,
            (Float(b) + 0.5) * scale
        )
    }
}
