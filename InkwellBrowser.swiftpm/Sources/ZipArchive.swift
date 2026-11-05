import Foundation
import Compression

/// A small, dependency-free reader for .zip, .crx (Chrome) and .xpi (Firefox) extension packages.
/// iOS has no public unzip API, so this handles the two compression methods extensions use
/// (stored and deflate) via Apple's Compression framework.
enum ZipArchive {
    enum ZipError: LocalizedError {
        case notAnArchive
        case unsupportedCRXVersion(Int)
        case unsupportedCompression(Int)
        case encrypted
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive: return "This file isn't a .zip, .crx or .xpi extension package."
            case .unsupportedCRXVersion(let v): return "Unsupported Chrome package version (CRX\(v))."
            case .unsupportedCompression(let m): return "The archive uses an unsupported compression method (\(m))."
            case .encrypted: return "Encrypted archives aren't supported."
            case .corrupt(let detail): return "The archive is damaged (\(detail))."
            }
        }
    }

    static func extract(_ data: Data, to destination: URL) throws {
        var bytes = [UInt8](data)
        bytes = try stripCRXHeader(bytes)

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path

        let eocd = try findEndOfCentralDirectory(bytes)
        let entryCount = try u16(bytes, eocd + 10)
        var p = try u32(bytes, eocd + 16)

        for _ in 0..<entryCount {
            guard try u32(bytes, p) == 0x0201_4B50 else { throw ZipError.corrupt("bad central directory") }
            let flags = try u16(bytes, p + 8)
            let method = try u16(bytes, p + 10)
            let compressedSize = try u32(bytes, p + 20)
            let uncompressedSize = try u32(bytes, p + 24)
            let nameLength = try u16(bytes, p + 28)
            let extraLength = try u16(bytes, p + 30)
            let commentLength = try u16(bytes, p + 32)
            let localHeaderOffset = try u32(bytes, p + 42)
            guard p + 46 + nameLength <= bytes.count else { throw ZipError.corrupt("name out of range") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength

            if flags & 1 != 0 { throw ZipError.encrypted }

            // Skip macOS resource forks and refuse anything that escapes the destination.
            let components = name.split(separator: "/").map(String.init)
            if components.first == "__MACOSX" || components.isEmpty { continue }
            if components.contains("..") { throw ZipError.corrupt("unsafe path \(name)") }

            let target = destination.appendingPathComponent(components.joined(separator: "/"))
            guard target.standardizedFileURL.path.hasPrefix(root) else { throw ZipError.corrupt("unsafe path \(name)") }

            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            guard try u32(bytes, localHeaderOffset) == 0x0403_4B50 else { throw ZipError.corrupt("bad local header") }
            let localNameLength = try u16(bytes, localHeaderOffset + 26)
            let localExtraLength = try u16(bytes, localHeaderOffset + 28)
            let start = localHeaderOffset + 30 + localNameLength + localExtraLength
            guard start + compressedSize <= bytes.count else { throw ZipError.corrupt("data out of range") }
            let compressed = bytes[start..<(start + compressedSize)]

            let output: Data
            switch method {
            case 0: output = Data(compressed)
            case 8: output = try inflate(compressed, expectedSize: uncompressedSize)
            default: throw ZipError.unsupportedCompression(method)
            }

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try output.write(to: target)
        }
    }

    // MARK: - Internals

    /// Chrome packages are a zip with a signed header in front ("Cr24").
    private static func stripCRXHeader(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count > 16, bytes[0] == 0x43, bytes[1] == 0x72, bytes[2] == 0x32, bytes[3] == 0x34 else {
            return bytes
        }
        let version = try u32(bytes, 4)
        let zipStart: Int
        switch version {
        case 3: zipStart = try 12 + u32(bytes, 8)
        case 2: zipStart = try 16 + u32(bytes, 8) + u32(bytes, 12)
        default: throw ZipError.unsupportedCRXVersion(version)
        }
        guard zipStart < bytes.count else { throw ZipError.corrupt("truncated CRX") }
        return Array(bytes[zipStart...])
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw ZipError.notAnArchive }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var i = bytes.count - 22
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        throw ZipError.notAnArchive
    }

    private static func inflate(_ source: ArraySlice<UInt8>, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        guard !source.isEmpty else { throw ZipError.corrupt("empty deflate stream") }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = source.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951) — exactly what zip uses.
                compression_decode_buffer(dst.baseAddress!, expectedSize, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupt("inflate failed") }
        return Data(destination)
    }

    private static func u16(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= b.count else { throw ZipError.corrupt("read past end") }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= b.count else { throw ZipError.corrupt("read past end") }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
}
