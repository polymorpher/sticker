import Foundation
@testable import StickerizeKit
import StickerizeTestSupport
import XCTest

final class ZipArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = TestImages.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Reading

    func testReadsStoredAndDeflatedEntriesAndDirectories() throws {
        let text = Data(String(repeating: "sticker ", count: 5000).utf8)
        let archive = try open(TestZip([
            .directory("stickers"),
            TestZip.Entry("stickers/a.txt", text),
            TestZip.Entry("stickers/b.bin", Data([1, 2, 3]), deflate: false),
        ]))
        XCTAssertEqual(archive.entries.map(\.path), ["stickers", "stickers/a.txt", "stickers/b.bin"])
        XCTAssertEqual(archive.entries.map(\.isDirectory), [true, false, false])
        XCTAssertEqual(archive.entries[1].fileName, "a.txt")
        XCTAssertEqual(archive.entries[1].uncompressedSize, UInt64(text.count))
        XCTAssertEqual(try archive.contents(of: archive.entries[1], maxBytes: .max), text)
        XCTAssertEqual(try archive.contents(of: archive.entries[2], maxBytes: .max), Data([1, 2, 3]))

        let unpacked = directory.appendingPathComponent("a.txt")
        try archive.extract(archive.entries[1], to: unpacked, maxBytes: .max)
        XCTAssertEqual(try Data(contentsOf: unpacked), text)
    }

    func testReadsZIP64DataDescriptorsAndSelfExtractorStubs() throws {
        let payload = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var zip64 = TestZip.Entry("big.bin", payload)
        zip64.zip64 = true
        var described = TestZip.Entry("streamed.bin", payload)
        described.flags = 0x0008
        var zip = TestZip([zip64, described])
        zip.zip64End = true
        let archive = try open(zip)
        XCTAssertEqual(try archive.entries.map { try archive.contents(of: $0, maxBytes: .max) }, [payload, payload])

        // A self-extractor's stub in front, with offsets that don't count it.
        var stubbed = TestZip([TestZip.Entry("a.bin", payload), TestZip.Entry("b.bin", Data("b".utf8))])
        stubbed.prefix = Data(repeating: 0x90, count: 4096)
        stubbed.comment = Data("archive comment".utf8)
        let shifted = try open(stubbed)
        XCTAssertEqual(try shifted.contents(of: shifted.entries[0], maxBytes: .max), payload)
        XCTAssertEqual(try shifted.contents(of: shifted.entries[1], maxBytes: .max), Data("b".utf8))
    }

    func testCommentContainingTheEndSignatureDoesNotConfuseTheReader() throws {
        var zip = TestZip([TestZip.Entry("a.txt", Data("a".utf8))])
        zip.comment = Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0, count: 30)
        let archive = try open(zip)
        XCTAssertEqual(archive.entries.map(\.path), ["a.txt"])
        XCTAssertEqual(try archive.contents(of: archive.entries[0], maxBytes: .max), Data("a".utf8))
    }

    func testPathsAreCleanedUp() throws {
        let archive = try open(TestZip([
            TestZip.Entry("./a/../b\\c.png", Data("x".utf8)),
            TestZip.Entry("/abs//d.png", Data("y".utf8)),
        ]))
        XCTAssertEqual(archive.entries.map(\.path), ["a/b/c.png", "abs/d.png"])
    }

    func testSymlinksAndDOSFoldersAreRecognized() throws {
        var link = TestZip.Entry("link.png", Data("target.png".utf8), deflate: false)
        link.versionMadeBy = 3 << 8 | 30
        link.externalAttributes = UInt32(0o120755) << 16
        var folder = TestZip.Entry("Folder", Data(), deflate: false)
        folder.externalAttributes = 0x10
        let archive = try open(TestZip([link, folder]))
        XCTAssertEqual(archive.entries.map(\.isSymbolicLink), [true, false])
        XCTAssertEqual(archive.entries.map(\.isDirectory), [false, true])
    }

    // MARK: Refusing

    func testDamagedEntriesAreRefusedAndLeaveNothingBehind() throws {
        let payload = Data(String(repeating: "damaged? ", count: 2000).utf8)
        var badChecksum = TestZip.Entry("crc.txt", payload)
        badChecksum.crc = 0xDEAD_BEEF
        // A ZIP bomb's trick: declare a small size and inflate to much more.
        var bomb = TestZip.Entry("bomb.txt", Data(repeating: 0, count: 10_000_000))
        bomb.declaredSize = 1000
        let archive = try open(TestZip([badChecksum, bomb]))
        for entry in archive.entries {
            let target = directory.appendingPathComponent(entry.fileName)
            XCTAssertThrowsError(try archive.extract(entry, to: target, maxBytes: .max)) { error in
                XCTAssertEqual(error as? ZipError, .damaged, entry.path)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), entry.path)
        }

        // Corrupted in the middle of the deflated data, and cut off before the central directory.
        var corrupted = try TestZip([TestZip.Entry("t.txt", payload)]).data()
        let middle = 30 + "t.txt".utf8.count + 20
        for index in middle..<middle + 8 { corrupted[index] ^= 0xA5 }
        let corruptedURL = directory.appendingPathComponent("corrupted.zip")
        try corrupted.write(to: corruptedURL)
        let damaged = try ZipArchive(contentsOf: corruptedURL)
        XCTAssertThrowsError(try damaged.contents(of: damaged.entries[0], maxBytes: .max)) {
            XCTAssertEqual($0 as? ZipError, .damaged)
        }
        let cutURL = directory.appendingPathComponent("cut.zip")
        try corrupted.prefix(corrupted.count / 2).write(to: cutURL)
        XCTAssertThrowsError(try ZipArchive(contentsOf: cutURL)) { XCTAssertEqual($0 as? ZipError, .notAnArchive) }
    }

    func testEncryptedUnsupportedAndOversizedEntriesAreRefused() throws {
        var encrypted = TestZip.Entry("secret.png", Data("x".utf8))
        encrypted.flags = 0x0001
        var bzip2 = TestZip.Entry("bz.png", Data("x".utf8), deflate: false)
        bzip2.method = 12
        let large = TestZip.Entry("large.png", Data(repeating: 1, count: 5000))
        let archive = try open(TestZip([encrypted, bzip2, large]))
        XCTAssertTrue(archive.entries[0].isEncrypted)
        XCTAssertThrowsError(try archive.contents(of: archive.entries[0], maxBytes: .max)) {
            XCTAssertEqual($0 as? ZipError, .encrypted)
        }
        XCTAssertThrowsError(try archive.contents(of: archive.entries[1], maxBytes: .max)) {
            XCTAssertEqual($0 as? ZipError, .unsupportedCompression(12))
        }
        XCTAssertThrowsError(try archive.contents(of: archive.entries[2], maxBytes: 4999)) {
            XCTAssertEqual($0 as? ZipError, .entryTooLarge(limit: 4999))
        }
    }

    func testNotAnArchiveSplitAndTooManyEntries() throws {
        let notZip = directory.appendingPathComponent("not.zip")
        try Data(repeating: 7, count: 100).write(to: notZip)
        XCTAssertThrowsError(try ZipArchive(contentsOf: notZip)) { XCTAssertEqual($0 as? ZipError, .notAnArchive) }

        var split = TestZip([TestZip.Entry("a.txt", Data("a".utf8))])
        split.diskNumber = 1
        XCTAssertThrowsError(try open(split)) { XCTAssertEqual($0 as? ZipError, .splitArchive) }

        let many = TestZip((0..<10).map { TestZip.Entry("\($0).txt", Data()) })
        let url = try many.write(to: directory.appendingPathComponent("many.zip"))
        XCTAssertThrowsError(try ZipArchive(contentsOf: url, maxEntries: 9)) { XCTAssertEqual($0 as? ZipError, .tooManyEntries) }
        XCTAssertEqual(try ZipArchive(contentsOf: url, maxEntries: 10).entries.count, 10)
    }

    /// A count the directory is too small to hold is damage, which skips one archive, not "too many files", which
    /// ends the whole search.
    func testACountTheDirectoryCantHoldIsDamage() throws {
        var zip64 = TestZip([TestZip.Entry("x.png", Data(repeating: 1, count: 10))])
        zip64.zip64End = true
        zip64.declaredZip64EntryCount = 300_000
        XCTAssertThrowsError(try open(zip64)) { XCTAssertEqual($0 as? ZipError, .damaged) }
        var classic = TestZip([TestZip.Entry("x.png", Data(repeating: 1, count: 10))])
        classic.declaredEntryCount = 60_000
        let url = try classic.write(to: directory.appendingPathComponent("count.zip"))
        XCTAssertThrowsError(try ZipArchive(contentsOf: url, maxEntries: 50_000)) { XCTAssertEqual($0 as? ZipError, .damaged) }
    }

    /// Opening an archive of many records can be stopped; unpacking stops between chunks.
    func testOpeningAndUnpackingCanBeCancelled() throws {
        struct Stop: Error {}
        let many = try TestZip((0..<10_000).map { TestZip.Entry("\($0).txt", Data(), deflate: false) })
            .write(to: directory.appendingPathComponent("many.zip"))
        var records = 0
        XCTAssertThrowsError(try ZipArchive(contentsOf: many, maxEntries: 200_000, preferredLanguages: ["en-US"],
                                            recordsRead: &records, checkCancelled: { throw Stop() })) { XCTAssertTrue($0 is Stop) }
        XCTAssertLessThan(records, 10_000)

        // Fewer records than the directory walk checks at, but enough names to decode that decoding checks.
        let legacy = try TestZip((0..<3_000).map { TestZip.Entry(rawName: TestZip.bytes("开心\($0).png", .GB_18030_2000), Data(), deflate: false) })
            .write(to: directory.appendingPathComponent("legacy.zip"))
        records = 0
        XCTAssertThrowsError(try ZipArchive(contentsOf: legacy, maxEntries: 200_000, preferredLanguages: ["en-US"],
                                            recordsRead: &records, checkCancelled: { throw Stop() })) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(records, 3_000, "stopped while decoding names")

        let archive = try open(TestZip([TestZip.Entry("big.bin", Data(repeating: 3, count: 1_000_000), deflate: false)]))
        let target = directory.appendingPathComponent("big.bin")
        var chunks = 0
        XCTAssertThrowsError(try archive.extract(archive.entries[0], to: target, maxBytes: .max) {
            chunks += 1
            if chunks == 2 { throw Stop() }
        })
        XCTAssertEqual(chunks, 2, "stopped at the second of four chunks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// Names longer than macOS allows are judged on the raw record, before marks are capped and "./" dropped.
    func testOverlongNamesAreJudgedOnTheRawName() throws {
        let names = ["a" + String(repeating: "\u{301}", count: 600) + "b.png", String(repeating: "./", count: 600) + "z.png",
                     String(repeating: "a", count: 1_100) + ".png", "ok.png"]
        let archive = try open(TestZip(names.map { name in
            var entry = TestZip.Entry(name, Data("x".utf8))
            entry.flags = 0x0800
            return entry
        }))
        XCTAssertEqual(archive.entries.map(\.hasOverlongName), [true, true, true, false])
        // A file name (one part of the path) longer than any file system takes.
        let parts = try open(TestZip([TestZip.Entry("folder/" + String(repeating: "猫", count: 256) + ".png", Data("x".utf8)),
                                      TestZip.Entry("folder/" + String(repeating: "猫", count: 200) + ".png", Data("x".utf8))].map { entry in
            var entry = entry
            entry.flags = 0x0800
            return entry
        }))
        XCTAssertEqual(parts.entries.map(\.hasOverlongName), [true, false])
    }

    /// An archive with more records than the limit is too many files, however large its directory, not damaged: a
    /// sparse file whose end record claims 20 records in a 140 MB directory.
    func testTooManyFilesIsSaidBeforeTheDirectorySize() throws {
        let size = 140 * 1024 * 1024
        let url = directory.appendingPathComponent("huge.zip")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: UInt64(size))
        var end = Data()
        for value: UInt32 in [0x0605_4B50] { withUnsafeBytes(of: value.littleEndian) { end.append(contentsOf: $0) } }
        for value: UInt16 in [0, 0, 20, 20] { withUnsafeBytes(of: value.littleEndian) { end.append(contentsOf: $0) } }
        for value: UInt32 in [UInt32(size), 0] { withUnsafeBytes(of: value.littleEndian) { end.append(contentsOf: $0) } }
        end.append(contentsOf: [0, 0])
        try handle.write(contentsOf: end)
        try handle.close()
        XCTAssertThrowsError(try ZipArchive(contentsOf: url, maxEntries: 19)) { XCTAssertEqual($0 as? ZipError, .tooManyEntries) }
        XCTAssertThrowsError(try ZipArchive(contentsOf: url, maxEntries: 20)) { XCTAssertEqual($0 as? ZipError, .damaged) }
    }

    /// Opening checks for a stop every 4,096 records while reading the directory and building the entries, and every
    /// 1,000 names while decoding them.
    func testOpeningChecksForAStopThroughout() throws {
        let many = try TestZip((0..<5_000).map { TestZip.Entry("\($0).txt", Data(), deflate: false) })
            .write(to: directory.appendingPathComponent("checks.zip"))
        var records = 0, calls = 0
        _ = try ZipArchive(contentsOf: many, maxEntries: 200_000, preferredLanguages: ["en-US"], recordsRead: &records,
                           checkCancelled: { calls += 1 })
        XCTAssertEqual(calls, 1 + 5 + 1, "the directory, the names, the entries")
    }

    // MARK: Hostile archives

    /// Every size and offset is untrusted. Ones near the top of the 64-bit range must fail as damaged archives, not
    /// overflow (Swift traps) or reach lseek (which can't take offsets past 2^63).
    func testHostileSizesAndOffsetsAreDamagedNotCrashes() throws {
        let payload = Data(repeating: 7, count: 100)
        var hugeCompressed = TestZip.Entry("a.png", payload)
        hugeCompressed.zip64Fields = [.compressed]
        hugeCompressed.declaredCompressedSize = .max
        var hugeOffset = TestZip.Entry("b.png", payload)
        hugeOffset.zip64Fields = [.offset]
        hugeOffset.declaredOffset = .max - 3
        var pastLseek = TestZip.Entry("c.png", payload)
        pastLseek.zip64Fields = [.offset]
        pastLseek.declaredOffset = 1 << 63
        for entry in [hugeCompressed, hugeOffset, pastLseek] {
            // With a self-extractor's stub, so the offset is also shifted.
            var zip = TestZip([entry])
            zip.prefix = Data(repeating: 0x90, count: 16)
            let archive = try open(zip)
            XCTAssertThrowsError(try archive.contents(of: archive.entries[0], maxBytes: .max), String(decoding: entry.name, as: UTF8.self)) {
                XCTAssertEqual($0 as? ZipError, .damaged)
            }
        }

        var hugeDirectory = TestZip([TestZip.Entry("d.png", payload)])
        hugeDirectory.zip64End = true
        for offset: UInt64 in [.max - 4, 1 << 63, 1 << 40] {
            hugeDirectory.zip64DirectoryOffset = offset
            XCTAssertThrowsError(try open(hugeDirectory), "\(offset)") { XCTAssertEqual($0 as? ZipError, .damaged) }
        }
    }

    /// The ZIP64 locator's own pointer to its end record, if past the file (or past what lseek takes), is recovered from
    /// where the record must be: right before the locator.
    func testAHugeZIP64LocatorPointerIsRecovered() throws {
        var zip = TestZip([TestZip.Entry("a.png", Data("a".utf8))])
        zip.zip64End = true
        for pointer: UInt64 in [.max - 3, 1 << 63, 1 << 40] {
            var data = zip.data()
            let field = data.count - 22 - 20 + 8 // the locator's 8-byte offset, before the 22-byte end record
            for byte in 0..<8 { data[field + byte] = UInt8(truncatingIfNeeded: pointer >> (8 * UInt64(byte))) }
            let url = directory.appendingPathComponent("locator.zip")
            try data.write(to: url)
            let archive = try ZipArchive(contentsOf: url, preferredLanguages: ["en-US"])
            XCTAssertEqual(try archive.contents(of: archive.entries[0], maxBytes: .max), Data("a".utf8), "\(pointer)")
        }
    }

    /// Made on macOS or Linux, a backslash is part of the name; made on Windows, it separates folders.
    func testBackslashesByTheArchivesHost() throws {
        var unix = TestZip.Entry("(\\_:).gif", Data("x".utf8))
        unix.versionMadeBy = 3 << 8 | 30
        var windows = TestZip.Entry("folder\\file.gif", Data("y".utf8))
        windows.versionMadeBy = 20
        var mac = TestZip.Entry("(\\o/).gif", Data("z".utf8))
        mac.versionMadeBy = 19 << 8 | 30 // OS X
        let archive = try open(TestZip([unix, windows, mac]))
        XCTAssertEqual(archive.entries.map(\.path), ["(\\_:).gif", "folder/file.gif", "(\\o/).gif"])
    }

    /// A ZIP bomb's other trick: many names for one small, highly compressed stream, each name a full inflate.
    func testOverlappingEntriesAreRefused() throws {
        let payload = Data(repeating: 0, count: 100_000)
        var copy = TestZip.Entry("copy.png", payload)
        copy.sharesDataWith = 0
        XCTAssertThrowsError(try open(TestZip([TestZip.Entry("first.png", payload), copy]))) {
            XCTAssertEqual($0 as? ZipError, .damaged)
        }
        // Pointing inside another entry's data.
        var inside = TestZip.Entry("inside.png", Data("x".utf8), deflate: false)
        inside.declaredOffset = 40
        XCTAssertThrowsError(try open(TestZip([TestZip.Entry("big.png", payload, deflate: false), inside]))) {
            XCTAssertEqual($0 as? ZipError, .damaged)
        }
    }

    /// The walk stops at the first record without a signature: an end record promising more entries means the rest
    /// of the directory was lost, which must not pass silently.
    func testFewerEntriesThanTheEndRecordSaysIsDamaged() throws {
        var zip = TestZip([TestZip.Entry("a.png", Data("a".utf8)), TestZip.Entry("b.png", Data("b".utf8))])
        zip.declaredEntryCount = 3
        XCTAssertThrowsError(try open(zip)) { XCTAssertEqual($0 as? ZipError, .damaged) }
    }

    func testZIP64WithASelfExtractorStub() throws {
        let payload = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        var entry = TestZip.Entry("big.bin", payload)
        entry.zip64 = true
        var zip = TestZip([TestZip.Entry("first.txt", Data("first".utf8)), entry])
        zip.zip64End = true
        zip.prefix = Data(repeating: 0x4D, count: 2048)
        let archive = try open(zip)
        XCTAssertEqual(archive.entries.map(\.path), ["first.txt", "big.bin"])
        XCTAssertEqual(try archive.contents(of: archive.entries[1], maxBytes: .max), payload)
    }

    /// APPNOTE 4.5.3: a ZIP64 field holds only the values saturated in the fixed header, in order.
    func testPartialZIP64FieldsAreReadInOrder() throws {
        let first = Data("first entry, so the second one's offset isn't zero".utf8)
        let payload = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        for fields: TestZip.Zip64Fields in [[.offset], [.compressed], [.uncompressed], [.uncompressed, .offset], [.compressed, .offset]] {
            var entry = TestZip.Entry("second.bin", payload)
            entry.zip64Fields = fields
            let archive = try open(TestZip([TestZip.Entry("first.txt", first), entry]))
            XCTAssertEqual(try archive.contents(of: archive.entries[1], maxBytes: .max), payload, "\(fields.rawValue)")
            XCTAssertEqual(try archive.contents(of: archive.entries[0], maxBytes: .max), first)
        }
    }

    /// The bytes a bomb inflates past its declared size never reach the caller, and the inflating stops there.
    func testInflatingPastTheDeclaredSizeStopsBeforeTheSink() throws {
        var bomb = TestZip.Entry("bomb.txt", Data(repeating: 0, count: 10_000_000))
        bomb.declaredSize = 1000
        let archive = try open(TestZip([bomb]))
        let counter = Counter()
        XCTAssertThrowsError(try archive.stream(archive.entries[0], maxBytes: .max) { counter.bytes += $0.count }) {
            XCTAssertEqual($0 as? ZipError, .damaged)
        }
        XCTAssertLessThanOrEqual(counter.bytes, 1000)
    }

    // MARK: File names

    /// Names as Windows writes them on each system, without a UTF-8 flag, decoded for a user whose language is English.
    func testLegacyEncodedNamesAreRecognized() throws {
        let cases: [(names: [String], encoding: CFStringEncodings)] = [
            (["微信表情包_导出/1_50_组/开心.gif", "微信表情包_导出/51_100_组/狗头.png", "导出信息/使用说明.txt"], .GB_18030_2000),
            (["開心.gif", "貓咪表情/哈哈哈.png"], .big5_HKSCS_1999),
            (["猫のスタンプ/ねこ.png", "ありがとう.gif"], .dosJapanese),
            // Hangul alone would tie with GB2312 hanzi; this much text gives it away.
            (["고양이/안녕하세요.png", "감사합니다.gif"], .dosKorean),
            (["Müller/café.png", "über.gif"], .dosLatinUS),
        ]
        for (names, encoding) in cases {
            let raw = names.map { TestZip.bytes($0, encoding) }
            XCTAssertEqual(ZipFileNames.decode(raw.map(rawName), preferredLanguages: ["en-US"]).names, names, "\(encoding)")
            let archive = try open(TestZip(raw.map { TestZip.Entry(rawName: $0, Data("x".utf8)) }))
            XCTAssertEqual(archive.entries.map(\.path), names, "\(encoding)")
            XCTAssertNotNil(archive.legacyNameEncoding)
        }
    }

    /// One name at a time is the hard case: little text to go on. Everyday sticker names, each alone in an archive.
    func testShortNamesAloneAreRecognized() {
        let cases: [(names: [String], encoding: CFStringEncodings)] = [
            (["开心", "哈哈哈", "狗头", "捂脸", "加油", "晚安", "谢谢老板", "微笑", "无语", "吃瓜", "摸鱼", "打工人", "好的",
              "收到", "点赞", "抱抱", "生气", "委屈", "震惊", "笑哭"], .GB_18030_2000),
            (["ねこ", "おはよう", "ありがとう", "猫のスタンプ", "お疲れ様", "いいね", "ワロタ"], .dosJapanese),
            (["고양이", "안녕하세요", "감사합니다", "좋아요", "화이팅"], .dosKorean),
            (["über", "café", "niño", "Müller", "naïve", "smörgåsbord"], .dosLatinUS),
        ]
        for (names, encoding) in cases {
            let languages = switch encoding {
            case .dosJapanese: ["ja-JP", "en-US"]
            case .dosKorean: ["ko-KR"]
            case .GB_18030_2000: ["en-US", "zh-Hans-CN", "ja-JP"]
            default: ["en-US", "de-DE"]
            }
            for name in names {
                for language in languages {
                    let raw = rawName(TestZip.bytes(name + ".gif", encoding))
                    XCTAssertEqual(ZipFileNames.decode([raw], preferredLanguages: [language]).names, [name + ".gif"], "\(encoding) \(language)")
                }
            }
        }
        // Traditional Chinese names, decoded for a user who reads it.
        for name in ["開心", "哈哈哈", "狗頭", "加油", "晚安", "謝謝老闆", "微笑", "無語", "吃瓜", "讚", "抱抱", "生氣", "委屈", "震驚", "笑哭"] {
            let raw = rawName(TestZip.bytes(name + ".png", .big5_HKSCS_1999))
            XCTAssertEqual(ZipFileNames.decode([raw], preferredLanguages: ["zh-Hant-TW"]).names, [name + ".png"])
        }
    }

    func testUTF8MarkersWinAndUnmarkedUTF8IsUTF8() throws {
        // Flag bit 11.
        var flagged = TestZip.Entry("表情/开心.gif", Data("x".utf8))
        flagged.flags = 0x0800
        // Info-ZIP's UTF-8 field next to a GBK name; and a stale one (made for another name) that must be ignored.
        let gbk = TestZip.bytes("狗头.png", .GB_18030_2000)
        var withField = TestZip.Entry(rawName: gbk, Data("x".utf8))
        withField.extra = TestZip.unicodePathField("狗头.png", forRawName: gbk)
        var stale = TestZip.Entry(rawName: TestZip.bytes("捂脸.png", .GB_18030_2000), Data("x".utf8))
        stale.extra = TestZip.unicodePathField("wrong.png", forRawName: gbk)
        // Finder's Compress writes UTF-8 without the flag, and macOS file names are decomposed (NFD).
        let decomposed = TestZip.Entry("Pokémon/ポケモン.png".decomposedStringWithCanonicalMapping, Data("x".utf8))
        let archive = try open(TestZip([flagged, withField, stale, decomposed]))
        XCTAssertEqual(archive.entries.map(\.path), ["表情/开心.gif", "狗头.png", "捂脸.png", "Pokémon/ポケモン.png"])
        XCTAssertEqual(archive.entries[3].path.unicodeScalars.count, "Pokémon/ポケモン.png".unicodeScalars.count, "precomposed")
    }

    /// A record may repeat Info-ZIP's UTF-8 field thousands of times; the name's checksum is computed once, not once
    /// per field (4 records of 60 KB names would otherwise checksum 1.7 GB).
    func testRepeatedUnicodePathFieldsAreCheap() throws {
        let field: [UInt8] = [0x75, 0x70, 5, 0, 1, 0, 0, 0, 0] // a UTF-8 path field whose checksum matches nothing
        let entries = (0..<4).map { index -> TestZip.Entry in
            var entry = TestZip.Entry(rawName: Array(repeating: UInt8(ascii: "a"), count: 60_000) + Array("\(index).png".utf8), Data())
            entry.extra = Data(Array(repeating: field, count: 7281).joined())
            return entry
        }
        let started = Date()
        let archive = try open(TestZip(entries))
        XCTAssertEqual(archive.entries.count, 4)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testGBKThatIsAlsoValidUTF8StaysChineseAndRealUTF8StaysUTF8() {
        // 微笑 in GBK is CE A2 D0 A6, which is also valid UTF-8 (an unassigned Greek code point and Ц).
        XCTAssertNotNil(String(bytes: TestZip.bytes("微笑", .GB_18030_2000), encoding: .utf8))
        let names = ["微笑.gif", "开心.gif"].map { rawName(TestZip.bytes($0, .GB_18030_2000)) }
        XCTAssertEqual(ZipFileNames.decode(names, preferredLanguages: ["en-US"]).names, ["微笑.gif", "开心.gif"])
        XCTAssertEqual(ZipFileNames.decode([names[0]], preferredLanguages: ["en-US"]).names, ["微笑.gif"])
        // Genuine UTF-8 without the flag, in scripts a GBK reading could also cover.
        for name in ["вино.png", "Ελληνικά.gif", "кот/Привет.png", "猫のスタンプ.gif", "고양이.png", "😀 party.gif"] {
            XCTAssertEqual(ZipFileNames.decode([rawName(Array(name.utf8))], preferredLanguages: ["en-US"]).names, [name])
        }
    }

    func testTiesGoToTheUsersLanguage() {
        // KS X 1001 Hangul is also valid, common-looking GB2312: a short name goes by the user's language.
        let korean = rawName(TestZip.bytes("고양이.png", .EUC_KR))
        XCTAssertEqual(ZipFileNames.decode([korean], preferredLanguages: ["ko-KR"]).names, ["고양이.png"])
        let chinese = rawName(TestZip.bytes("呵呵.png", .GB_18030_2000))
        XCTAssertEqual(ZipFileNames.decode([chinese], preferredLanguages: ["en-US"]).names, ["呵呵.png"])
        XCTAssertEqual(ZipFileNames.order(for: ["en-US"]), [.gb18030, .westernDOS, .big5, .shiftJIS, .korean, .cyrillicDOS],
                       "WeChat collections come from Chinese Windows")
        XCTAssertEqual(ZipFileNames.order(for: ["zh-Hant-HK"]).first, .big5)
        XCTAssertEqual(ZipFileNames.order(for: ["zh-TW"]).first, .big5)
        XCTAssertEqual(ZipFileNames.order(for: ["zh-Hans-CN"]).first, .gb18030)
        XCTAssertEqual(ZipFileNames.order(for: ["ja"]).first, .shiftJIS)
    }

    func testCRC32MatchesKnownValues() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        var pieces = CRC32()
        pieces.update(Data("1234".utf8))
        pieces.update(Data("56789".utf8))
        XCTAssertEqual(pieces.value, 0xCBF4_3926)
    }

    // MARK: Helpers

    private final class Counter {
        var bytes = 0
    }

    /// Opens `zip` as an English-speaking user would, whatever this machine's language.
    private func open(_ zip: TestZip) throws -> ZipArchive {
        let url = directory.appendingPathComponent("\(UUID().uuidString).zip")
        try zip.write(to: url)
        return try ZipArchive(contentsOf: url, preferredLanguages: ["en-US"])
    }

    private func rawName(_ bytes: [UInt8]) -> ZipFileNames.RawName {
        ZipFileNames.RawName(bytes: Data(bytes), isMarkedUTF8: false, unicodePath: nil)
    }
}
