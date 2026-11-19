import Foundation
import Compression

// Converts a PC RAGE texture dictionary (.wtd, RSC5 v8) into an Xbox 360 one (.xtd, RSC5 v7).
// Supports DXT1 / DXT3 / DXT5 2D textures. Only the top mip level is written.

enum ConvertError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

struct ConversionOutput {
    var bytes: [UInt8]
    var notes: [String]
}

private extension Array where Element == UInt8 {
    func u16(_ o: Int) -> Int { Int(self[o]) | (Int(self[o + 1]) << 8) }
    func u32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | (UInt32(self[o + 1]) << 8) | (UInt32(self[o + 2]) << 16) | (UInt32(self[o + 3]) << 24)
    }
    mutating func putBE16(_ o: Int, _ v: Int) {
        self[o] = UInt8((v >> 8) & 0xFF); self[o + 1] = UInt8(v & 0xFF)
    }
    mutating func putBE32(_ o: Int, _ v: UInt32) {
        self[o] = UInt8((v >> 24) & 0xFF); self[o + 1] = UInt8((v >> 16) & 0xFF)
        self[o + 2] = UInt8((v >> 8) & 0xFF); self[o + 3] = UInt8(v & 0xFF)
    }
    mutating func putLE16(_ o: Int, _ v: Int) {
        self[o] = UInt8(v & 0xFF); self[o + 1] = UInt8((v >> 8) & 0xFF)
    }
    mutating func putLE32(_ o: Int, _ v: UInt32) {
        self[o] = UInt8(v & 0xFF); self[o + 1] = UInt8((v >> 8) & 0xFF)
        self[o + 2] = UInt8((v >> 16) & 0xFF); self[o + 3] = UInt8((v >> 24) & 0xFF)
    }
}

enum WTDConverter {
    static let virtBase: UInt32 = 0x5000_0000
    static let physBase: UInt32 = 0x6000_0000
    // Xbox 360 vtable words, copied verbatim (not byte swapped) from a real .xtd.
    static let dictVTable: [UInt8] = [0x0C, 0x83, 0x61, 0x00]
    static let texVTable: [UInt8] = [0x9C, 0x1A, 0x63, 0x00]

    // fourcc -> (GPU texture format, bytes per 4x4 block)
    static func format(_ fourcc: [UInt8]) -> (gpu: UInt32, block: Int)? {
        switch String(decoding: fourcc, as: UTF8.self) {
        case "DXT1": return (18, 8)
        case "DXT3": return (19, 16)
        case "DXT5": return (20, 16)
        default: return nil
        }
    }

    struct Tex {
        var name: [UInt8]
        var w: Int, h: Int
        var fourcc: [UInt8]
        var levels: Int
        var floats: [UInt8]
        var physOffset: Int
        var a: Int, b: Int
    }

    // MARK: resource flags

    static func segmentSize(_ v: UInt32) -> Int {
        let mant = Int(v & 0x7FF)
        let shift = Int((v >> 11) & 0xF)
        return mant << (shift + 8)
    }

    static func encodeSize(_ needIn: Int) throws -> (flags: UInt32, size: Int) {
        let need = max(4096, ((needIn + 4095) / 4096) * 4096)
        var shift = 15
        while shift >= 0 {
            let unit = 1 << (shift + 8)
            let m = (need + unit - 1) / unit
            if m >= 16 && m <= 0x7FF { return (UInt32(m | (shift << 11)), m * unit) }
            shift -= 1
        }
        throw ConvertError.message("Texture data is too large for an RSC5 resource.")
    }

    // MARK: zlib

    static func inflate(_ src: [UInt8], expected: Int) throws -> [UInt8] {
        guard src.count > 6, src[0] & 0x0F == 8 else {
            throw ConvertError.message("Body is not a zlib stream.")
        }
        let raw = Array(src[2..<(src.count - 4)])          // strip zlib header + adler32
        var dst = [UInt8](repeating: 0, count: expected)
        let n = raw.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, expected, s.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expected else {
            throw ConvertError.message("Decompressed \(n) bytes, expected \(expected).")
        }
        return dst
    }

    // MARK: Xbox 360 texture tiling

    static func tiledOuter(_ y: Int, _ width: Int, _ logBpp: Int) -> Int {
        let macro = ((y >> 5) * (width >> 5)) << (logBpp + 7)
        let micro = ((y & 6) << 2) << logBpp
        return macro + ((micro & ~0xF) << 1) + (micro & 0xF) + ((y & 8) << (3 + logBpp)) + ((y & 1) << 4)
    }

    static func tiledInner(_ x: Int, _ y: Int, _ logBpp: Int, _ base: Int) -> Int {
        let macro = (x >> 5) << (logBpp + 7)
        let micro = (x & 7) << logBpp
        let off = base + (macro + ((micro & ~0xF) << 1) + (micro & 0xF))
        return ((off & ~0x1FF) << 3) + ((off & 0x1C0) << 2) + (off & 0x3F)
            + ((y & 16) << 7) + (((((y & 8) >> 2) + (x >> 3)) & 3) << 6)
    }

    /// Tiles linear blocks and swaps every 16-bit word (Xbox "8in16" endianness).
    static func tileAndSwap(_ src: ArraySlice<UInt8>, bw: Int, bh: Int, blockSize: Int) -> [UInt8] {
        let logBpp = blockSize == 8 ? 3 : 4
        let aw = (bw + 31) / 32 * 32
        let ah = (bh + 31) / 32 * 32
        var out = [UInt8](repeating: 0, count: aw * ah * blockSize)
        let s0 = src.startIndex
        for y in 0..<bh {
            let outer = tiledOuter(y, aw, logBpp)
            for x in 0..<bw {
                let d = tiledInner(x, y, logBpp, outer)
                let s = s0 + (y * bw + x) * blockSize
                var i = 0
                while i < blockSize {
                    out[d + i] = src[s + i + 1]
                    out[d + i + 1] = src[s + i]
                    i += 2
                }
            }
        }
        return out
    }

    // MARK: LZX (Xbox framing), stored blocks only

    static func lzxStored(_ data: [UInt8]) throws -> [UInt8] {
        let n = data.count
        guard n < (1 << 24) else { throw ConvertError.message("Resource too large.") }
        let frame = 32768
        let hdr = UInt32(3 << 28) | (UInt32(n) << 4)        // E8 bit 0, block type 3, 24-bit size
        var first = [UInt8](repeating: 0, count: 16)
        first.putLE16(0, Int(hdr >> 16))
        first.putLE16(2, Int(hdr & 0xFFFF))
        for r in 0..<3 { first.putLE32(4 + r * 4, 1) }      // R0,R1,R2 = 1
        var out = [UInt8]()
        out.reserveCapacity(n + 64)
        var pos = 0
        while pos < n {
            let end = min(pos + frame, n)
            var payload = pos == 0 ? first : []
            payload.append(contentsOf: data[pos..<end])
            if end == n && (n & 1) == 1 { payload.append(0) }
            if end - pos == frame {
                out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
            } else {
                out.append(0xFF)
                out.append(UInt8((end - pos) >> 8)); out.append(UInt8((end - pos) & 0xFF))
                out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
            }
            out.append(contentsOf: payload)
            pos = end
        }
        return out
    }

    // MARK: main entry

    static func convert(_ file: [UInt8]) throws -> ConversionOutput {
        guard file.count > 20, Array(file[0..<4]) == [0x52, 0x53, 0x43, 0x05] else {
            throw ConvertError.message("Not an RSC5 resource file.")
        }
        guard file.u32(4) == 8 else {
            throw ConvertError.message("Not a PC (version 8) texture dictionary.")
        }
        let flags = file.u32(8)
        let virtSize = segmentSize(flags & 0x7FFF)
        let physSize = segmentSize((flags >> 15) & 0x7FFF)
        let body = try inflate(Array(file[12...]), expected: virtSize + physSize)
        let v = Array(body[0..<virtSize])
        let p = Array(body[virtSize...])

        func vptr(_ x: UInt32) throws -> Int {
            guard x >> 28 == 5 else { throw ConvertError.message("Unexpected pointer in file.") }
            return Int(x & 0x0FFF_FFFF)
        }
        let hashOff = try vptr(v.u32(0x10)); let count = v.u16(0x14)
        let texArr = try vptr(v.u32(0x18)); let count2 = v.u16(0x1C)
        guard count == count2, count > 0 else { throw ConvertError.message("Empty or malformed dictionary.") }

        var hashes = [UInt32]()
        var texs = [Tex]()
        var notes = [String]()
        for i in 0..<count {
            hashes.append(v.u32(hashOff + 4 * i))
            let t = try vptr(v.u32(texArr + 4 * i))
            let nameOff = try vptr(v.u32(t + 0x14))
            guard let end = v[nameOff...].firstIndex(of: 0) else { throw ConvertError.message("Bad texture name.") }
            let pp = v.u32(t + 0x48)
            guard pp >> 28 == 6 else { throw ConvertError.message("Unexpected pixel pointer.") }
            let tex = Tex(name: Array(v[nameOff..<end]), w: v.u16(t + 0x1C), h: v.u16(t + 0x1E),
                          fourcc: Array(v[(t + 0x20)..<(t + 0x24)]), levels: Int(v[t + 0x27]),
                          floats: Array(v[(t + 0x28)..<(t + 0x40)]), physOffset: Int(pp & 0x0FFF_FFFF),
                          a: v.u16(t + 0x08), b: v.u16(t + 0x0A))
            guard format(tex.fourcc) != nil else {
                throw ConvertError.message("Unsupported pixel format \(String(decoding: tex.fourcc, as: UTF8.self)) in \(String(decoding: tex.name, as: UTF8.self)). Only DXT1/DXT3/DXT5 are supported.")
            }
            if tex.levels > 1 {
                notes.append("\(String(decoding: tex.name, as: UTF8.self)): \(tex.levels - 1) smaller mip level(s) dropped.")
            }
            texs.append(tex)
        }

        func align(_ n: Int, _ a: Int) -> Int { (n + a - 1) / a * a }
        let n = texs.count
        var off = 0x230
        let texOff = (0..<n).map { 0x230 + 0x80 * $0 }
        off += 0x80 * n
        var nameOff = [Int]()
        for t in texs { nameOff.append(off); off += align(t.name.count + 1, 16) }
        let hashArr = off; off += align(4 * n, 16)
        let ptrArr = off; off += align(4 * n, 16)
        let (vFlags, vSz) = try encodeSize(off)

        // physical segment
        var phys = [UInt8]()
        var physOffsets = [Int](); var alignedW = [Int]()
        for t in texs {
            let f = format(t.fourcc)!
            let bw = max(1, (t.w + 3) / 4), bh = max(1, (t.h + 3) / 4)
            let len = bw * bh * f.block
            guard t.physOffset + len <= p.count else { throw ConvertError.message("Pixel data is truncated.") }
            physOffsets.append(phys.count)
            phys.append(contentsOf: tileAndSwap(p[t.physOffset..<(t.physOffset + len)], bw: bw, bh: bh, blockSize: f.block))
            phys.append(contentsOf: [UInt8](repeating: 0, count: align(phys.count, 4096) - phys.count))
            alignedW.append((bw + 31) / 32 * 32)
        }
        let (pFlags, pSz) = try encodeSize(phys.count)
        phys.append(contentsOf: [UInt8](repeating: 0, count: pSz - phys.count))

        // virtual segment
        var V = [UInt8](repeating: 0xCD, count: vSz)
        V.replaceSubrange(0..<4, with: dictVTable)
        V.putBE32(4, virtBase + 0x20); V.putBE32(8, 0); V.putBE32(0xC, 1)
        V.putBE32(0x10, virtBase + UInt32(hashArr)); V.putBE16(0x14, n); V.putBE16(0x16, n)
        V.putBE32(0x18, virtBase + UInt32(ptrArr)); V.putBE16(0x1C, n); V.putBE16(0x1E, n)
        V.putBE32(0x20, 0)
        for (i, t) in texs.enumerated() {
            let T = texOff[i], D = T + 0x40
            for k in 0..<0x40 { V[T + k] = 0xCD; V[D + k] = 0xCD }
            V.replaceSubrange(T..<(T + 4), with: texVTable)
            V.putBE32(T + 4, 0); V.putBE16(T + 8, t.a); V.putBE16(T + 0xA, t.b)
            V.putBE32(T + 0xC, 0); V.putBE32(T + 0x10, 0)
            V.putBE32(T + 0x14, virtBase + UInt32(nameOff[i]))
            V.putBE32(T + 0x18, virtBase + UInt32(D))
            V.putBE16(T + 0x1C, t.w); V.putBE16(T + 0x1E, t.h)
            V.replaceSubrange((T + 0x20)..<(T + 0x24), with: [0, 0, 0, 1])
            for k in 0..<6 {                                   // 6 floats, byte-swap each
                for j in 0..<4 { V[T + 0x24 + k * 4 + j] = t.floats[k * 4 + 3 - j] }
            }
            let gpu = format(t.fourcc)!.gpu
            let pitch = alignedW[i] * 4 / 32
            let ptr = physBase + UInt32(physOffsets[i])
            V.putBE32(D + 0x00, 0x0020_0003); V.putBE32(D + 0x04, 1)
            V.putBE32(D + 0x08, 0); V.putBE32(D + 0x0C, 0); V.putBE32(D + 0x10, 0)
            V.putBE32(D + 0x14, 0xFFFF_0000); V.putBE32(D + 0x18, 0xFFFF_0000)
            V.putBE32(D + 0x1C, (1 << 31) | (UInt32(pitch) << 22) | 2)
            V.putBE32(D + 0x20, (ptr & 0xFFFF_F000) | (1 << 6) | gpu)
            V.putBE32(D + 0x24, UInt32(t.w - 1) | (UInt32(t.h - 1) << 13))
            V.putBE32(D + 0x28, 0x0D10); V.putBE32(D + 0x2C, 0); V.putBE32(D + 0x30, 0x200)
            V.replaceSubrange(nameOff[i]..<(nameOff[i] + t.name.count), with: t.name)
            V[nameOff[i] + t.name.count] = 0
            V.putBE32(ptrArr + 4 * i, virtBase + UInt32(T))
            V.putBE32(hashArr + 4 * i, hashes[i])
        }

        let packed = try lzxStored(V + phys)
        var outFile: [UInt8] = [0x52, 0x53, 0x43, 0x05, 7, 0, 0, 0, 0, 0, 0, 0]
        outFile.putLE32(8, vFlags | (pFlags << 15) | 0xC000_0000)
        var tail = [UInt8](repeating: 0, count: 8)
        tail.putBE32(0, 0x0FF5_12EF); tail.putBE32(4, UInt32(packed.count))
        outFile += tail
        outFile += packed
        return ConversionOutput(bytes: outFile, notes: notes)
    }
}
