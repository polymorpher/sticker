import Compression
import Foundation
import StickerizeKit

/// Writes ZIP archives byte by byte, including the variations real tools produce (legacy-encoded names, Info-ZIP's
/// UTF-8 name field, data descriptors, ZIP64, a self-extractor stub) and damaged or hostile ones (lying sizes and
/// offsets, overlapping entries), so the reader can be tested against each without fixtures.
public struct TestZip {
    /// Which central-directory fields are saturated (0xFFFFFFFF) and carried in a ZIP64 extra field instead. APPNOTE
    /// 4.5.3: only those, in this order.
    public struct Zip64Fields: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let uncompressed = Zip64Fields(rawValue: 1)
        public static let compressed = Zip64Fields(rawValue: 2)
        public static let offset = Zip64Fields(rawValue: 4)
        public static let all: Zip64Fields = [.uncompressed, .compressed, .offset]
    }

    public struct Entry {
        public var name: [UInt8]
        public var data: Data
        public var deflate = true
        /// General-purpose flags: 0x0001 encrypted, 0x0008 data descriptor, 0x0800 UTF-8 name.
        public var flags: UInt16 = 0
        /// Overrides the compression method written (the data is still stored or deflated as `deflate` says).
        public var method: UInt16?
        /// Extra fields for the central directory, after any ZIP64 field.
        public var extra = Data()
        /// High byte: 0 MS-DOS, 3 Unix, 19 macOS.
        public var versionMadeBy: UInt16 = 20
        public var externalAttributes: UInt32 = 0
        public var crc: UInt32?
        /// Sizes and offset to declare in the central directory instead of the real ones.
        public var declaredSize: UInt64?
        public var declaredCompressedSize: UInt64?
        public var declaredOffset: UInt64?
        public var zip64Fields: Zip64Fields = []
        /// Writes only a central record for this entry, pointing at the data of the entry at this index (overlapping entries).
        public var sharesDataWith: Int?

        public var zip64: Bool {
            get { !zip64Fields.isEmpty }
            set { zip64Fields = newValue ? .all : [] }
        }

        public init(_ name: String, _ data: Data, deflate: Bool = true) {
            self.name = Array(name.utf8)
            self.data = data
            self.deflate = deflate
        }

        public init(rawName: [UInt8], _ data: Data, deflate: Bool = true) {
            name = rawName
            self.data = data
            self.deflate = deflate
        }

        public static func directory(_ name: String) -> Entry {
            Entry(name.hasSuffix("/") ? name : name + "/", Data(), deflate: false)
        }
    }

    public var entries: [Entry]
    /// Bytes in front of the archive that its offsets don't count, like a self-extractor's stub.
    public var prefix = Data()
    public var comment = Data()
    public var zip64End = false
    /// Central directory offset to write in the ZIP64 end record instead of the real one.
    public var zip64DirectoryOffset: UInt64?
    /// Entry count to write in the end record instead of the real one.
    public var declaredEntryCount: UInt16?
    /// Entry count to write in the ZIP64 end record instead of the real one.
    public var declaredZip64EntryCount: UInt64?
    /// Disk number written in the end record (non-zero: a split archive).
    public var diskNumber: UInt16 = 0

    public init(_ entries: [Entry]) {
        self.entries = entries
    }

    public func data() -> Data {
        var archive = Data()
        var central = Data()
        var offsets: [UInt64] = []
        var bodies: [Data] = []
        for entry in entries {
            let body = entry.deflate ? Self.deflate(entry.data) : entry.data
            bodies.append(body)
            let crc = entry.crc ?? CRC32.checksum(entry.data)
            let size = entry.declaredSize ?? UInt64(entry.data.count)
            let compressed = entry.declaredCompressedSize ?? UInt64(body.count)
            let method = entry.method ?? (entry.deflate ? 8 : 0)
            let descriptor = entry.flags & 0x0008 != 0
            let sizesIn64 = entry.zip64Fields.contains(.uncompressed) || entry.zip64Fields.contains(.compressed)

            var offset = UInt64(archive.count)
            if let shared = entry.sharesDataWith {
                offset = offsets[shared]
            } else {
                var zip64Local = Data()
                if sizesIn64 {
                    zip64Local.le16(0x0001); zip64Local.le16(16); zip64Local.le64(size); zip64Local.le64(compressed)
                }
                archive.le32(0x0403_4B50)
                archive.le16(entry.zip64 ? 45 : 20)
                archive.le16(entry.flags)
                archive.le16(method)
                archive.le16(0); archive.le16(0x21)
                archive.le32(descriptor ? 0 : crc)
                archive.le32(descriptor ? 0 : sizesIn64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: compressed))
                archive.le32(descriptor ? 0 : sizesIn64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: size))
                archive.le16(UInt16(entry.name.count))
                archive.le16(UInt16(zip64Local.count))
                archive.append(contentsOf: entry.name)
                archive.append(zip64Local)
                archive.append(body)
                if descriptor {
                    archive.le32(0x0807_4B50); archive.le32(crc)
                    archive.le32(UInt32(truncatingIfNeeded: compressed)); archive.le32(UInt32(truncatingIfNeeded: size))
                }
            }
            offsets.append(offset)
            let declaredOffset = entry.declaredOffset ?? offset

            var extra = Data()
            var fields = Data()
            if entry.zip64Fields.contains(.uncompressed) { fields.le64(size) }
            if entry.zip64Fields.contains(.compressed) { fields.le64(compressed) }
            if entry.zip64Fields.contains(.offset) { fields.le64(declaredOffset) }
            if !fields.isEmpty {
                extra.le16(0x0001); extra.le16(UInt16(fields.count)); extra.append(fields)
            }
            extra.append(entry.extra)
            central.le32(0x0201_4B50)
            central.le16(entry.versionMadeBy)
            central.le16(entry.zip64 ? 45 : 20)
            central.le16(entry.flags)
            central.le16(method)
            central.le16(0); central.le16(0x21)
            central.le32(crc)
            central.le32(entry.zip64Fields.contains(.compressed) ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: compressed))
            central.le32(entry.zip64Fields.contains(.uncompressed) ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: size))
            central.le16(UInt16(entry.name.count))
            central.le16(UInt16(extra.count))
            central.le16(0); central.le16(0); central.le16(0)
            central.le32(entry.externalAttributes)
            central.le32(entry.zip64Fields.contains(.offset) ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: declaredOffset))
            central.append(contentsOf: entry.name)
            central.append(extra)
        }
        let centralOffset = UInt64(archive.count)
        archive.append(central)
        let count = declaredEntryCount ?? UInt16(truncatingIfNeeded: entries.count)
        if zip64End {
            let recordOffset = UInt64(archive.count)
            archive.le32(0x0606_4B50); archive.le64(44); archive.le16(45); archive.le16(45)
            archive.le32(0); archive.le32(0)
            archive.le64(declaredZip64EntryCount ?? UInt64(count)); archive.le64(declaredZip64EntryCount ?? UInt64(count))
            archive.le64(UInt64(central.count)); archive.le64(zip64DirectoryOffset ?? centralOffset)
            archive.le32(0x0706_4B50); archive.le32(0); archive.le64(recordOffset); archive.le32(1)
        }
        archive.le32(0x0605_4B50)
        archive.le16(diskNumber); archive.le16(diskNumber)
        archive.le16(zip64End ? 0xFFFF : count); archive.le16(zip64End ? 0xFFFF : count)
        archive.le32(zip64End ? 0xFFFF_FFFF : UInt32(central.count))
        archive.le32(zip64End ? 0xFFFF_FFFF : UInt32(centralOffset))
        archive.le16(UInt16(comment.count))
        archive.append(comment)
        return prefix + archive
    }

    @discardableResult
    public func write(to url: URL) throws -> URL {
        try data().write(to: url)
        return url
    }

    /// Info-ZIP's Unicode Path extra field (0x7075): the UTF-8 name, valid for the raw name whose CRC it carries.
    public static func unicodePathField(_ name: String, forRawName raw: [UInt8]) -> Data {
        var field = Data()
        let utf8 = Array(name.utf8)
        field.le16(0x7075)
        field.le16(UInt16(5 + utf8.count))
        field.append(1)
        field.le32(CRC32.checksum(raw))
        field.append(contentsOf: utf8)
        return field
    }

    public static func bytes(_ text: String, _ encoding: CFStringEncodings) -> [UInt8] {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        return Array(text.data(using: encoding)!)
    }

    static func deflate(_ data: Data) -> Data {
        var output = Data()
        let filter = try! OutputFilter(.compress, using: .zlib) { if let chunk = $0 { output.append(chunk) } }
        try! filter.write(data)
        try! filter.finalize()
        return output
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 0xFFFF)); le16(UInt16(value >> 16)) }
    mutating func le64(_ value: UInt64) { le32(UInt32(value & 0xFFFF_FFFF)); le32(UInt32(value >> 32)) }
}
