import Compression
import Foundation

public enum ZipError: LocalizedError, Equatable {
    case notAnArchive
    /// The archive file itself couldn't be opened or read (no permission, removed, an I/O error).
    case unreadable
    case damaged
    case splitArchive
    case tooManyEntries
    case encrypted
    case unsupportedCompression(UInt16)
    case entryTooLarge(limit: UInt64)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive: "The file isn't a ZIP archive."
        case .unreadable: "The ZIP archive couldn't be read."
        case .damaged: "The ZIP archive is damaged."
        case .splitArchive: "The ZIP archive is split into several files, which isn't supported."
        case .tooManyEntries: "The ZIP archive has too many files."
        case .encrypted: "The file is password-protected."
        case let .unsupportedCompression(method): "The file uses a compression method that isn't supported (\(method))."
        case let .entryTooLarge(limit): "The file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(clamping: limit), countStyle: .memory))."
        }
    }
}

/// Reads a ZIP archive in place: the kind Finder's Compress, Windows' "Send to compressed folder", `zip` and most other
/// tools make (stored or deflated entries, ZIP64). Nothing is unpacked until asked for, one entry at a time.
///
/// File names are decoded the way the archive's maker meant them: UTF-8 when the archive says so (or the name is valid
/// UTF-8), otherwise the legacy code page it was most likely made with, such as GBK on Chinese Windows. See
/// `ZipFileNames`.
public final class ZipArchive {
    public struct Entry: Sendable, Hashable {
        /// Path inside the archive, "/"-separated, without empty, "." or ".." parts.
        public let path: String
        public let uncompressedSize: UInt64
        public let isDirectory: Bool
        public let isSymbolicLink: Bool
        public let isEncrypted: Bool
        /// The name is longer than any real file's: more than 1,024 bytes (macOS's and iOS's longest path), or a part of
        /// more than 255 characters (the most any file system allows a file name). A hostile archive; `path` may then be
        /// cut short.
        public let hasOverlongName: Bool
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let localHeaderOffset: UInt64

        public var fileName: String { path.split(separator: "/").last.map(String.init) ?? "" }
    }

    public let entries: [Entry]
    /// The code page legacy (non-UTF-8) file names were decoded with, if the archive has any.
    public let legacyNameEncoding: String.Encoding?

    private let handle: FileHandle
    private let fileSize: UInt64
    /// Bytes in front of the archive that its offsets don't count (a self-extractor stub).
    private let offsetShift: UInt64

    static let maxCentralDirectoryBytes: UInt64 = 128 * 1024 * 1024
    /// macOS's and iOS's PATH_MAX.
    static let maxNameBytes = 1_024
    /// NAME_MAX, in UTF-16 units as NTFS counts (APFS counts 255 UTF-8 bytes, fewer).
    static let maxComponentLength = 255

    /// `preferredLanguages` breaks ties when legacy file names read equally well in two code pages.
    public convenience init(contentsOf url: URL, maxEntries: Int = 200_000,
                            preferredLanguages: [String] = Locale.preferredLanguages) throws {
        var recordsRead = 0
        try self.init(contentsOf: url, maxEntries: maxEntries, preferredLanguages: preferredLanguages, recordsRead: &recordsRead)
    }

    /// `recordsRead` counts the central directory records read, whether or not the archive then turns out usable: what
    /// opening it cost. `checkCancelled` is called every few thousand records; what it throws stops opening.
    public init(contentsOf url: URL, maxEntries: Int, preferredLanguages: [String], recordsRead: inout Int,
                checkCancelled: () throws -> Void = {}) throws {
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipError.unreadable
        }
        do {
            fileSize = try handle.seekToEnd()
            let directory = try Self.locateCentralDirectory(handle: handle, fileSize: fileSize)
            // Every offset and size in an archive is untrusted: compare by subtraction so none can overflow.
            guard directory.offset <= fileSize, directory.size <= fileSize - directory.offset else { throw ZipError.damaged }
            // A count the directory is too small to hold (46 bytes a record) is damage, not a huge archive. (0xFFFF
            // may stand for "see the ZIP64 record" in an archive without one.) One it can hold that is past the limit is
            // too many files, however large the directory.
            guard directory.entryCount <= directory.size / 46 || directory.entryCount == 0xFFFF else { throw ZipError.damaged }
            guard min(directory.entryCount, directory.size / 46) <= UInt64(max(maxEntries, 0)) else { throw ZipError.tooManyEntries }
            guard directory.size <= Self.maxCentralDirectoryBytes else { throw ZipError.damaged }
            // A self-extractor's offsets don't count its stub: the directory then really ends where the end record starts.
            var shift: UInt64 = 0
            var bytes = try Self.read(handle, at: directory.offset, count: Int(directory.size))
            if bytes.count < 4 || Self.uint32(bytes, 0) != 0x0201_4B50, directory.end > directory.offset + directory.size {
                shift = directory.end - (directory.offset + directory.size)
                bytes = try Self.read(handle, at: directory.offset + shift, count: Int(directory.size))
            }
            offsetShift = shift
            let parsed = try Self.parseCentralDirectory(bytes, maxEntries: maxEntries, recordsRead: &recordsRead,
                                                        checkCancelled: checkCancelled)
            // The walk stops at the first record without a signature, so a damaged directory would otherwise lose
            // every entry after it without a word. (Archives with more than 65,535 entries but no ZIP64 record
            // keep the count modulo 65,536, or saturate it.)
            let count = UInt64(parsed.count)
            guard count == directory.entryCount || count & 0xFFFF == directory.entryCount || directory.entryCount == 0xFFFF
            else { throw ZipError.damaged }
            try Self.checkNoOverlap(parsed)
            let names = try ZipFileNames.decode(parsed.map(\.name), preferredLanguages: preferredLanguages,
                                                checkCancelled: checkCancelled)
            legacyNameEncoding = names.legacyEncoding
            entries = try zip(parsed, names.names).enumerated().map { index, pair in
                if index % 4_096 == 4_095 { try checkCancelled() }
                return pair.0.entry(named: pair.1)
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    /// Unpacks `entry` into a new file at `destination`, checking its size and checksum. `checkCancelled` is called
    /// between chunks; what it throws stops unpacking. Nothing is left behind if it fails.
    public func extract(_ entry: Entry, to destination: URL, maxBytes: UInt64,
                        checkCancelled: () throws -> Void = {}) throws {
        // Writing an empty file throws an error that says why it failed (a full disk), as createFile doesn't.
        try Data().write(to: destination, options: .withoutOverwriting)
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try withoutActuallyEscaping(checkCancelled) { checkCancelled in
                try stream(entry, maxBytes: maxBytes) { chunk in
                    try checkCancelled()
                    try output.write(contentsOf: chunk)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func contents(of entry: Entry, maxBytes: UInt64) throws -> Data {
        var data = Data()
        try stream(entry, maxBytes: maxBytes) { data.append($0) }
        return data
    }

    /// The first `count` bytes of `entry` (fewer if it's shorter), unpacking no more than that, to tell what it is.
    /// Its checksum isn't verified.
    public func prefix(of entry: Entry, count: Int) throws -> Data {
        struct Enough: Error {}
        var data = Data()
        do {
            try stream(entry, maxBytes: .max, verifying: false) { chunk in
                data.append(chunk.prefix(count - data.count))
                if data.count >= count { throw Enough() }
            }
        } catch is Enough {}
        return data
    }

    // MARK: Reading entries

    private static let chunkSize = 256 * 1024

    /// Throws the error extracting `entry` would fail with before reading any of its data (encrypted, unsupported
    /// compression, larger than `maxBytes`), so a caller can decide without unpacking anything.
    public func checkCanExtract(_ entry: Entry, maxBytes: UInt64) throws {
        guard !entry.isEncrypted else { throw ZipError.encrypted }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedCompression(entry.method) }
        guard entry.uncompressedSize <= maxBytes else { throw ZipError.entryTooLarge(limit: maxBytes) }
        if entry.method == 0, entry.compressedSize != entry.uncompressedSize { throw ZipError.damaged }
    }

    /// Hands `entry`'s bytes to `sink` in chunks. More bytes than the archive declared (a damaged entry, or a ZIP bomb
    /// lying about its size) stop it before they reach `sink`. The size and checksum are checked at the end, if
    /// `verifying`.
    func stream(_ entry: Entry, maxBytes: UInt64, verifying: Bool = true, to sink: @escaping (Data) throws -> Void) throws {
        try checkCanExtract(entry, maxBytes: maxBytes)

        // The local header repeats the name and has its own extra field, so its length is read rather than assumed.
        let (headerOffset, overflow) = entry.localHeaderOffset.addingReportingOverflow(offsetShift)
        guard !overflow, headerOffset <= fileSize else { throw ZipError.damaged }
        let header = try Self.read(handle, at: headerOffset, count: 30)
        guard header.count == 30, Self.uint32(header, 0) == 0x0403_4B50 else { throw ZipError.damaged }
        // headerOffset + 30 bytes were just read, so it is below fileSize and adding two 16-bit lengths can't overflow.
        var offset = headerOffset + 30 + UInt64(Self.uint16(header, 26)) + UInt64(Self.uint16(header, 28))
        guard offset <= fileSize, entry.compressedSize <= fileSize - offset else { throw ZipError.damaged }

        let expected = entry.uncompressedSize
        let progress = Progress()
        let emit: (Data) throws -> Void = { chunk in
            progress.written += UInt64(chunk.count)
            guard progress.written <= expected else { throw ZipError.damaged }
            progress.crc.update(chunk)
            try sink(chunk)
        }
        var remaining = entry.compressedSize
        do {
            let filter = entry.method == 8
                ? try OutputFilter(.decompress, using: .zlib) { chunk in if let chunk { try emit(chunk) } }
                : nil
            while remaining > 0 {
                let count = Int(min(remaining, UInt64(Self.chunkSize)))
                let chunk = try Self.read(handle, at: offset, count: count)
                guard chunk.count == count else { throw ZipError.damaged }
                if let filter { try filter.write(chunk) } else { try emit(chunk) }
                offset += UInt64(count)
                remaining -= UInt64(count)
            }
            try filter?.finalize()
        } catch is FilterError {
            throw ZipError.damaged
        }
        guard !verifying || (progress.written == expected && progress.crc.value == entry.crc32) else { throw ZipError.damaged }
    }

    private final class Progress {
        var written: UInt64 = 0
        var crc = CRC32()
    }

    // MARK: Central directory

    private struct CentralDirectory {
        let offset: UInt64
        let size: UInt64
        let entryCount: UInt64
        /// Where the directory should end: the start of the (ZIP64) end-of-central-directory record.
        let end: UInt64
    }

    private static func locateCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> CentralDirectory {
        // The end record is 22 bytes plus a comment of up to 64 KiB; the ZIP64 locator sits right before it.
        let tailLength = min(fileSize, UInt64(22 + 0xFFFF + 20))
        let tailStart = fileSize - tailLength
        let tail = try read(handle, at: tailStart, count: Int(tailLength))
        guard tail.count >= 22 else { throw ZipError.notAnArchive }
        // Search backwards; prefer a record whose comment runs exactly to the end of the file, in case the comment
        // itself contains the signature.
        var candidates: [Int] = []
        for index in stride(from: tail.count - 22, through: 0, by: -1) where uint32(tail, index) == 0x0605_4B50 {
            candidates.append(index)
        }
        guard let record = candidates.first(where: { $0 + 22 + Int(uint16(tail, $0 + 20)) == tail.count })
            ?? candidates.first(where: { $0 + 22 + Int(uint16(tail, $0 + 20)) <= tail.count })
        else { throw ZipError.notAnArchive }

        let disk = uint16(tail, record + 4), directoryDisk = uint16(tail, record + 6)
        var count = UInt64(uint16(tail, record + 10))
        var size = UInt64(uint32(tail, record + 12))
        var offset = UInt64(uint32(tail, record + 16))
        var end = tailStart + UInt64(record)

        // ZIP64: the locator points at a larger end record with 64-bit fields.
        if record >= 20, uint32(tail, record - 20) == 0x0706_4B50 {
            var zip64Offset = uint64(tail, record - 20 + 8)
            var zip64 = zip64Offset <= fileSize ? try read(handle, at: zip64Offset, count: 56) : Data()
            // A self-extractor's stub shifts everything, the locator's pointer too; the record sits right before it.
            let locator = tailStart + UInt64(record - 20)
            if (zip64.count != 56 || uint32(zip64, 0) != 0x0606_4B50), locator >= 56 {
                zip64Offset = locator - 56
                zip64 = try read(handle, at: zip64Offset, count: 56)
            }
            guard zip64.count == 56, uint32(zip64, 0) == 0x0606_4B50 else { throw ZipError.damaged }
            guard uint32(zip64, 16) == 0, uint32(zip64, 20) == 0 else { throw ZipError.splitArchive }
            count = uint64(zip64, 32)
            size = uint64(zip64, 40)
            offset = uint64(zip64, 48)
            end = zip64Offset
        } else if disk != 0 || directoryDisk != 0 {
            throw ZipError.splitArchive
        }
        return CentralDirectory(offset: offset, size: size, entryCount: count, end: end)
    }

    private struct RawEntry {
        let name: ZipFileNames.RawName
        let versionMadeBy: UInt16
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let externalAttributes: UInt32
        let localHeaderOffset: UInt64

        func entry(named decoded: String) -> Entry {
            let host = versionMadeBy >> 8
            let unixMode = (host == 3 || host == 19) ? (externalAttributes >> 16) & 0o170000 : 0
            let isDirectory = decoded.hasSuffix("/") || unixMode == 0o040000
                || (host == 0 && externalAttributes & 0x10 != 0 && uncompressedSize == 0)
            let components = decoded.split(separator: "/").filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            let path = components.joined(separator: "/")
            let overlong = name.bytes.count > ZipArchive.maxNameBytes || (name.unicodePath?.utf8.count ?? 0) > ZipArchive.maxNameBytes
                || components.contains { $0.utf16.count > ZipArchive.maxComponentLength }
            return Entry(path: path, uncompressedSize: uncompressedSize, isDirectory: isDirectory,
                         isSymbolicLink: unixMode == 0o120000, isEncrypted: flags & 0x41 != 0, hasOverlongName: overlong,
                         method: method, crc32: crc32, compressedSize: compressedSize, localHeaderOffset: localHeaderOffset)
        }
    }

    private static func parseCentralDirectory(_ bytes: Data, maxEntries: Int, recordsRead: inout Int,
                                              checkCancelled: () throws -> Void) throws -> [RawEntry] {
        var entries: [RawEntry] = []
        var position = 0
        while position + 46 <= bytes.count, uint32(bytes, position) == 0x0201_4B50 {
            guard entries.count < maxEntries else { throw ZipError.tooManyEntries }
            if entries.count % 4_096 == 4_095 { try checkCancelled() }
            recordsRead += 1
            let nameLength = Int(uint16(bytes, position + 28))
            let extraLength = Int(uint16(bytes, position + 30))
            let commentLength = Int(uint16(bytes, position + 32))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= bytes.count else { throw ZipError.damaged }
            let nameBytes = bytes.subdata(in: bytes.startIndex + nameStart..<bytes.startIndex + extraStart)

            var compressed = UInt64(uint32(bytes, position + 20))
            var uncompressed = UInt64(uint32(bytes, position + 24))
            var localOffset = UInt64(uint32(bytes, position + 42))
            var unicodePath: String?
            var nameChecksum: UInt32?
            // Extra fields: ZIP64 sizes (0x0001) and Info-ZIP's UTF-8 copy of the name (0x7075).
            var field = extraStart
            while field + 4 <= extraStart + extraLength {
                let id = uint16(bytes, field), size = Int(uint16(bytes, field + 2))
                let data = field + 4
                guard data + size <= extraStart + extraLength else { break }
                if id == 0x0001 {
                    // Only the fields saturated in the fixed header are present, in this order.
                    var cursor = data
                    func next64(_ value: inout UInt64) {
                        guard value == 0xFFFF_FFFF, cursor + 8 <= data + size else { return }
                        value = uint64(bytes, cursor)
                        cursor += 8
                    }
                    next64(&uncompressed)
                    next64(&compressed)
                    next64(&localOffset)
                } else if id == 0x7075, unicodePath == nil, size >= 5, bytes[bytes.startIndex + data] == 1 {
                    // Valid only while it matches the name it was made for (an older tool may have renamed the entry).
                    // The name's checksum is computed once however many such fields a record repeats.
                    let checksum = nameChecksum ?? CRC32.checksum(nameBytes)
                    nameChecksum = checksum
                    if uint32(bytes, data + 1) == checksum {
                        unicodePath = String(data: bytes.subdata(in: bytes.startIndex + data + 5..<bytes.startIndex + data + size),
                                             encoding: .utf8)
                    }
                }
                field = data + size
            }
            let flags = uint16(bytes, position + 8)
            let versionMadeBy = uint16(bytes, position + 4)
            entries.append(RawEntry(
                name: ZipFileNames.RawName(bytes: nameBytes, isMarkedUTF8: flags & 0x0800 != 0, unicodePath: unicodePath,
                                           madeOnUnix: [3, 19].contains(versionMadeBy >> 8)),
                versionMadeBy: versionMadeBy, flags: flags, method: uint16(bytes, position + 10),
                crc32: uint32(bytes, position + 16), compressedSize: compressed, uncompressedSize: uncompressed,
                externalAttributes: uint32(bytes, position + 38), localHeaderOffset: localOffset))
            position = next
        }
        return entries
    }

    /// Refuses entries whose data overlap or share a local header. Real archives never do; a ZIP bomb does, naming one
    /// small, highly compressed stream thousands of times so that each name costs a full inflate.
    private static func checkNoOverlap(_ entries: [RawEntry]) throws {
        let sorted = entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
        for (entry, next) in zip(sorted, sorted.dropFirst()) {
            // The local header is at least 30 bytes, followed (after its name) by the compressed data.
            let (end, overflow) = entry.localHeaderOffset.addingReportingOverflow(30)
            let (dataEnd, overflow2) = end.addingReportingOverflow(entry.compressedSize)
            guard !overflow, !overflow2, next.localHeaderOffset >= dataEnd else { throw ZipError.damaged }
        }
    }

    // MARK: Bytes

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        // lseek takes a signed offset: a larger one is a damaged archive, not a file that can't be opened.
        guard offset <= UInt64(Int64.max) else { throw ZipError.damaged }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw ZipError.unreadable
        }
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        let start = data.startIndex + offset
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(uint16(data, offset)) | UInt32(uint16(data, offset + 2)) << 16
    }

    private static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(uint32(data, offset)) | UInt64(uint32(data, offset + 4)) << 32
    }
}
