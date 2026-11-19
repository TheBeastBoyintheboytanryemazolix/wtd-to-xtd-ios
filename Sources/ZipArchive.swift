import Foundation
import Compression

struct ZipEntry {
    let name: String
    let data: [UInt8]
}

/// Minimal zip reader (stored + deflate) and writer (stored). No zip64, no encryption.
enum ZipArchive {
    private static func rd16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
    private static func rd32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func inflateRaw(_ src: [UInt8], expected: Int) throws -> [UInt8] {
        if expected == 0 { return [] }
        guard !src.isEmpty else { throw ConvertError.message("Corrupt zip entry.") }
        var dst = [UInt8](repeating: 0, count: expected)
        let n = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, expected, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expected else { throw ConvertError.message("Corrupt zip entry (bad deflate data).") }
        return dst
    }

    static func read(_ bytes: [UInt8]) throws -> [ZipEntry] {
        guard bytes.count >= 22 else { throw ConvertError.message("Not a zip file.") }
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65535)
        while i >= lowest {
            if rd32(bytes, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ConvertError.message("Not a zip file (no end-of-directory record).") }
        let total = rd16(bytes, eocd + 10)
        let cdOffset = Int(rd32(bytes, eocd + 16))
        if total == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            throw ConvertError.message("Zip64 archives are not supported.")
        }
        var p = cdOffset
        var entries = [ZipEntry]()
        for _ in 0..<total {
            guard p + 46 <= bytes.count, rd32(bytes, p) == 0x0201_4B50 else {
                throw ConvertError.message("Corrupt zip directory.")
            }
            let flags = rd16(bytes, p + 8)
            let method = rd16(bytes, p + 10)
            let comp = Int(rd32(bytes, p + 20))
            let uncomp = Int(rd32(bytes, p + 24))
            let nl = rd16(bytes, p + 28), el = rd16(bytes, p + 30), cl = rd16(bytes, p + 32)
            let lho = Int(rd32(bytes, p + 42))
            guard p + 46 + nl <= bytes.count else { throw ConvertError.message("Corrupt zip directory.") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nl)], as: UTF8.self)
            p += 46 + nl + el + cl
            if name.hasSuffix("/") { continue }
            if flags & 1 != 0 { throw ConvertError.message("Encrypted zip files are not supported.") }
            if comp == 0xFFFF_FFFF || uncomp == 0xFFFF_FFFF || lho == 0xFFFF_FFFF {
                throw ConvertError.message("Zip64 archives are not supported.")
            }
            guard lho + 30 <= bytes.count, rd32(bytes, lho) == 0x0403_4B50 else {
                throw ConvertError.message("Corrupt zip entry header.")
            }
            let start = lho + 30 + rd16(bytes, lho + 26) + rd16(bytes, lho + 28)
            guard start + comp <= bytes.count else { throw ConvertError.message("Zip entry is truncated.") }
            let raw = Array(bytes[start..<(start + comp)])
            let data: [UInt8]
            switch method {
            case 0: data = raw
            case 8: data = try inflateRaw(raw, expected: uncomp)
            default: throw ConvertError.message("Unsupported zip compression method \(method).")
            }
            entries.append(ZipEntry(name: name, data: data))
        }
        return entries
    }

    // MARK: writer

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ d: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    static func write(_ entries: [ZipEntry]) throws -> [UInt8] {
        func le16(_ a: inout [UInt8], _ v: Int) { a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ a: inout [UInt8], _ v: UInt32) {
            for s in stride(from: 0, to: 32, by: 8) { a.append(UInt8((v >> UInt32(s)) & 0xFF)) }
        }
        var out = [UInt8](), central = [UInt8]()
        for e in entries {
            let name = Array(e.name.utf8)
            guard e.data.count < 0xFFFF_FFFF, out.count < 0xFFFF_FFFF - e.data.count - 1024 else {
                throw ConvertError.message("Output zip would exceed 4 GB.")
            }
            let crc = crc32(e.data)
            let offset = out.count
            le32(&out, 0x0403_4B50); le16(&out, 20); le16(&out, 0x0800); le16(&out, 0)
            le16(&out, 0); le16(&out, 0x0021)                       // time 00:00, date 1980-01-01
            le32(&out, crc); le32(&out, UInt32(e.data.count)); le32(&out, UInt32(e.data.count))
            le16(&out, name.count); le16(&out, 0)
            out += name; out += e.data

            le32(&central, 0x0201_4B50); le16(&central, 20); le16(&central, 20)
            le16(&central, 0x0800); le16(&central, 0)
            le16(&central, 0); le16(&central, 0x0021)
            le32(&central, crc); le32(&central, UInt32(e.data.count)); le32(&central, UInt32(e.data.count))
            le16(&central, name.count); le16(&central, 0); le16(&central, 0)
            le16(&central, 0); le16(&central, 0); le32(&central, 0)
            le32(&central, UInt32(offset))
            central += name
        }
        let cdOffset = out.count
        out += central
        le32(&out, 0x0605_4B50); le16(&out, 0); le16(&out, 0)
        le16(&out, entries.count); le16(&out, entries.count)
        le32(&out, UInt32(central.count)); le32(&out, UInt32(cdOffset)); le16(&out, 0)
        return out
    }
}
