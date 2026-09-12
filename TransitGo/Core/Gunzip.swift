import Foundation
import Compression

/// Minimal gzip (RFC 1952) decompressor. `URLSession` only auto-inflates when the server
/// sends `Content-Encoding: gzip`; some blob endpoints serve a raw `.gz` body as
/// `application/octet-stream`, so we strip the gzip envelope and raw-inflate ourselves.
enum Gunzip {
    static func decompress(_ input: Data) -> Data? {
        let bytes = [UInt8](input)
        guard bytes.count > 18,
              bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }

        let flags = bytes[3]
        var i = 10   // fixed header

        if flags & 0x04 != 0 {                       // FEXTRA
            guard i + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2 + xlen
        }
        if flags & 0x08 != 0 {                        // FNAME
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x10 != 0 {                        // FCOMMENT
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }               // FHCRC

        guard i < bytes.count - 8 else { return nil }
        let deflate = Array(bytes[i..<(bytes.count - 8)])

        let n = bytes.count
        let isize = Int(bytes[n - 4]) | (Int(bytes[n - 3]) << 8)
            | (Int(bytes[n - 2]) << 16) | (Int(bytes[n - 1]) << 24)
        var capacity = isize > 0 ? isize + 1024 : max(deflate.count * 20, 4_000_000)
        capacity = min(capacity, 64 * 1024 * 1024)

        var dst = [UInt8](repeating: 0, count: capacity)
        let written = deflate.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { out in
                compression_decode_buffer(out.baseAddress!, capacity,
                                          src.baseAddress!, deflate.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(dst[0..<written])
    }
}
