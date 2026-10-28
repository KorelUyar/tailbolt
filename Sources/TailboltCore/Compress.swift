import Foundation
#if canImport(Compression)
import Compression
#endif

/// Adaptive LZ4 (raw block format, so Linux/Windows ports can use liblz4). A chunk is compressed only
/// when a quick sample says it pays off — on a 20–100 MB/s tunnel, compressible data then moves
/// several times faster, while already-compressed media costs nothing but a 256 KB sample.
public enum LZ4 {
    public static let available: Bool = {
        #if canImport(Compression)
        return true
        #else
        return false
        #endif
    }()

    static let sampleSize = 256 << 10
    static let worthIt = 0.9            // sample must shrink below 90 %
    static let keepIt = 0.97            // whole chunk must shrink below 97 %, else send raw

    static let incompressibleExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "dmg", "jpg", "jpeg", "png", "gif", "heic", "heif", "webp",
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "mp3", "m4a", "aac", "flac", "ogg", "opus", "pdf", "ipa", "apk",
        "jar", "docx", "xlsx", "pptx", "pages", "numbers", "key", "iso", "br", "lz4", "lzma", "wim", "aar",
    ]

    public static func likelyIncompressible(path: String) -> Bool {
        incompressibleExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Returns the compressed size written to `dst` (capacity must be ≥ `bound(n)`), or 0 if not worth it.
    static func compress(_ src: UnsafeRawPointer, _ n: Int, into dst: UnsafeMutableRawPointer, capacity: Int) -> Int {
        #if canImport(Compression)
        if n > sampleSize {
            let sample = compression_encode_buffer(dst.assumingMemoryBound(to: UInt8.self), capacity,
                                                   src.assumingMemoryBound(to: UInt8.self), sampleSize, nil, COMPRESSION_LZ4_RAW)
            if sample == 0 || Double(sample) / Double(sampleSize) > worthIt { return 0 }
        }
        let out = compression_encode_buffer(dst.assumingMemoryBound(to: UInt8.self), capacity,
                                            src.assumingMemoryBound(to: UInt8.self), n, nil, COMPRESSION_LZ4_RAW)
        if out == 0 || Double(out) / Double(n) > keepIt { return 0 }
        return out
        #else
        return 0
        #endif
    }

    /// Decompresses exactly `expected` bytes into `dst`; returns false on any mismatch.
    static func decompress(_ src: UnsafeRawPointer, _ n: Int, into dst: UnsafeMutableRawPointer, expected: Int) -> Bool {
        #if canImport(Compression)
        let out = compression_decode_buffer(dst.assumingMemoryBound(to: UInt8.self), expected,
                                            src.assumingMemoryBound(to: UInt8.self), n, nil, COMPRESSION_LZ4_RAW)
        return out == expected
        #else
        return false
        #endif
    }

    /// Worst-case LZ4 output for `n` input bytes.
    static func bound(_ n: Int) -> Int { n + n / 255 + 64 }
}
