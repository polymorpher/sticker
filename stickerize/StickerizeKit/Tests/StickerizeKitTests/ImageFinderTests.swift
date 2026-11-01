import Foundation
import StickerizeKit
import StickerizeTestSupport
import UniformTypeIdentifiers
import XCTest

final class ImageFinderTests: XCTestCase {
    private var directory: URL!
    private var work: URL!
    private let png = TestImages.encode(TestImages.halves(width: 16, height: 16), type: .png)
    private let gif = TestImages.encode(TestImages.halves(width: 16, height: 16), type: .gif)
    private let jpeg = TestImages.encode(TestImages.halves(width: 16, height: 16), type: .jpeg)

    override func setUpWithError() throws {
        directory = TestImages.temporaryDirectory()
        work = directory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Finding

    func testFindsImagesInSubfoldersAndArchivesWithinArchives() throws {
        let innermost = TestZip([TestZip.Entry("deep.jpg", jpeg)]).data()
        let inner = TestZip([
            TestZip.Entry("x/3.png", png),
            TestZip.Entry("innermost.zip", innermost, deflate: false),
            TestZip.Entry("__MACOSX/x/._3.png", Data("resource fork".utf8)),
            TestZip.Entry(".DS_Store", Data([0, 0, 0, 1])),
        ]).data()
        let input = directory.appendingPathComponent("in", isDirectory: true)
        try write(png, to: input.appendingPathComponent("a/1.png"))
        try write(gif, to: input.appendingPathComponent("b/sub/10.gif"))
        try write(gif, to: input.appendingPathComponent("b/sub/9.gif"))
        try write(png, to: input.appendingPathComponent("b/.hidden.png"))
        try write(jpeg, to: input.appendingPathComponent("b/000051")) // recognized by its contents
        try write(png, to: input.appendingPathComponent("b/x.apng")) // an extension no app declares
        try write(Data("notes".utf8), to: input.appendingPathComponent("notes.txt"))
        try write(Data("plain".utf8), to: input.appendingPathComponent("README")) // no extension, not an image
        try FileManager.default.createDirectory(at: input.appendingPathComponent("folder.gif"), withIntermediateDirectories: true)
        try write(inner, to: input.appendingPathComponent("more.zip"))

        let result = try ImageFinder.find(in: input, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["a/1.png", "b/000051", "b/sub/9.gif", "b/sub/10.gif", "b/x.apng",
                                                   "more.zip/innermost.zip/deep.jpg", "more.zip/x/3.png"])
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(result.otherFiles, 2)
        XCTAssertFalse(result.reachedImageLimit)
        XCTAssertEqual(result.images.map(\.fileName), ["1.png", "000051", "9.gif", "10.gif", "x.apng", "deep.jpg", "3.png"])
        // Folder images are used in place; archive images are unpacked into the work folder, nested archives removed.
        XCTAssertEqual(result.images[0].url.lastPathComponent, "1.png")
        XCTAssertEqual(try Data(contentsOf: result.images[5].url), jpeg)
        XCTAssertEqual(try Data(contentsOf: result.images[6].url), png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).count, 2, "only the two unpacked images")
    }

    func testArchivePathsNeverEscapeTheWorkFolder() throws {
        let archive = try TestZip([
            TestZip.Entry("../../escape.png", png),
            TestZip.Entry("/etc/absolute.png", png),
        ]).write(to: directory.appendingPathComponent("hostile.zip"))
        let result = try ImageFinder.find(in: archive, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["escape.png", "etc/absolute.png"])
        for image in result.images {
            XCTAssertEqual(image.url.deletingLastPathComponent().standardizedFileURL, work.standardizedFileURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.png").path))
    }

    func testRecognizesFilesByContentAndGivesThemAnExtension() throws {
        let pdf = TestImages.pdf(size: CGSize(width: 50, height: 50))
        let archive = try TestZip([
            TestZip.Entry("000123", gif),
            TestZip.Entry("document", pdf),
            TestZip.Entry("animated.apng", png),
            TestZip.Entry("data.bin", Data(repeating: 9, count: 100)),
        ]).write(to: directory.appendingPathComponent("mixed.zip"))

        let images = try ImageFinder.find(in: archive, workDirectory: work)
        XCTAssertEqual(images.images.map(\.path), ["000123", "animated.apng"])
        XCTAssertEqual(images.images.map { $0.url.pathExtension }, ["gif", "png"])
        XCTAssertEqual(images.otherFiles, 2)

        let withPDFs = try ImageFinder.find(in: archive, workDirectory: work, includingPDFs: true)
        XCTAssertEqual(withPDFs.images.map(\.path), ["000123", "animated.apng", "document"])
        XCTAssertEqual(withPDFs.images[2].url.pathExtension, "pdf")
    }

    /// Declared image types ImageIO can't decode (SVG, Illustrator) aren't images here: no failure to report.
    func testImagesImageIOCantDecodeAreOtherFiles() throws {
        let archive = try TestZip([
            TestZip.Entry("logo.svg", Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)),
            TestZip.Entry("art.ai", Data("%PDF-1.4 illustrator".utf8)),
            TestZip.Entry("ok.png", png),
        ]).write(to: directory.appendingPathComponent("design.zip"))
        let result = try ImageFinder.find(in: archive, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["ok.png"])
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(result.otherFiles, 2)
    }

    /// Procreate, Krita and Sketch files, Office documents and .jar are ZIPs of something else, with previews inside
    /// that aren't stickers. Only plain ZIP archives (or bare files that turn out to be one) are opened.
    func testZIPBasedDocumentsAreNotOpened() throws {
        let preview = TestZip([TestZip.Entry("QuickLook/Thumbnail.png", png)]).data()
        let archive = try TestZip([
            TestZip.Entry("drawing.procreate", preview),
            TestZip.Entry("painting.kra", preview),
            TestZip.Entry("letter.docx", preview),
            TestZip.Entry("tool.jar", preview),
            TestZip.Entry("download", preview), // no extension: a ZIP saved bare
        ]).write(to: directory.appendingPathComponent("docs.zip"))
        let result = try ImageFinder.find(in: archive, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["download/QuickLook/Thumbnail.png"])
        XCTAssertEqual(result.otherFiles, 4)

        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try write(preview, to: folder.appendingPathComponent("drawing.procreate"))
        try write(png, to: folder.appendingPathComponent("cat.png"))
        XCTAssertEqual(try ImageFinder.find(in: folder, workDirectory: work).images.map(\.path), ["cat.png"])
    }

    /// The caller decided it's an archive (by its contents); `find` must agree, whatever the extension says.
    func testAZIPSavedUnderAnotherExtensionIsSearched() throws {
        for name in ["stickers.bin", "stickers.png", "stickers"] {
            let archive = try TestZip([TestZip.Entry("a.png", png)]).write(to: directory.appendingPathComponent(name))
            XCTAssertTrue(ImageFinder.isArchive(archive), name)
            XCTAssertEqual(try ImageFinder.find(in: archive, workDirectory: work).images.map(\.path), ["a.png"], name)
        }
    }

    func testSymlinksInFoldersAndArchives() throws {
        let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
        try write(png, to: elsewhere.appendingPathComponent("target.png"))
        try write(png, to: elsewhere.appendingPathComponent("sub/inside.png"))
        let zip = try TestZip([TestZip.Entry("zipped.png", png)]).write(to: elsewhere.appendingPathComponent("target.zip"))
        let input = directory.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(at: input.appendingPathComponent("link.png"), withDestinationURL: elsewhere.appendingPathComponent("target.png"))
        try fileManager.createSymbolicLink(at: input.appendingPathComponent("folder"), withDestinationURL: elsewhere.appendingPathComponent("sub"))
        try fileManager.createSymbolicLink(at: input.appendingPathComponent("link.zip"), withDestinationURL: zip)
        let result = try ImageFinder.find(in: input, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["link.png", "link.zip/zipped.png"], "linked folders aren't entered")

        // A symlink stored in an archive is a path, not an image.
        var link = TestZip.Entry("link.png", Data("target.png".utf8), deflate: false)
        link.versionMadeBy = 3 << 8 | 30
        link.externalAttributes = UInt32(0o120755) << 16
        let archive = try TestZip([link, TestZip.Entry("real.png", png)]).write(to: directory.appendingPathComponent("links.zip"))
        XCTAssertEqual(try ImageFinder.find(in: archive, workDirectory: work).images.map(\.path), ["real.png"])
    }

    // MARK: What can't be used

    func testUnusableEntriesAreReportedAndTheRestStillFound() throws {
        var encrypted = TestZip.Entry("locked.png", png)
        encrypted.flags = 0x0001
        // WeChat's files have no extension: a password-protected one is still reported, not taken for a non-image.
        var encryptedBare = TestZip.Entry("3f2a9c0d8e7b6a5f", gif)
        encryptedBare.flags = 0x0001
        var damaged = TestZip.Entry("damaged.gif", gif)
        damaged.crc = 0
        // Recognized as a GIF from its first bytes, so its damage is reported too.
        var damagedBare = TestZip.Entry("mystery", gif)
        damagedBare.crc = 0
        let archive = try TestZip([
            TestZip.Entry("good.png", png), encrypted, encryptedBare, damaged, damagedBare,
            TestZip.Entry("broken.zip", Data("not a zip".utf8)),
        ]).write(to: directory.appendingPathComponent("partly.zip"))

        let result = try ImageFinder.find(in: archive, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["good.png"])
        let reasons = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.path, $0.reason) })
        XCTAssertEqual(reasons, [
            "3f2a9c0d8e7b6a5f": ZipError.encrypted.errorDescription!, "locked.png": ZipError.encrypted.errorDescription!,
            "damaged.gif": ZipError.damaged.errorDescription!, "mystery": ZipError.damaged.errorDescription!,
            "broken.zip": ZipError.notAnArchive.errorDescription!,
        ])
        XCTAssertEqual(result.skipped.map(\.path), ["3f2a9c0d8e7b6a5f", "broken.zip", "damaged.gif", "locked.png", "mystery"],
                       "in name order")
        XCTAssertEqual(result.otherFiles, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).count, 1, "nothing left of the failures")
    }

    /// Files of unknown type are told apart from their first bytes, so a large non-image (a RAR archive, a Procreate
    /// file) isn't unpacked or charged to the budget at all.
    func testUnknownFilesAreRecognizedBeforeUnpacking() throws {
        let big = Data(repeating: 0x52, count: 300_000) // "RRR…": no known format
        let procreate = TestZip([TestZip.Entry("QuickLook/Thumbnail.png", png)]).data()
        let archive = try TestZip([
            TestZip.Entry("sources.rar", big), TestZip.Entry("drawing.procreate", procreate),
            TestZip.Entry("cat", gif), TestZip.Entry("dog.png", png),
        ]).write(to: directory.appendingPathComponent("mixed.zip"))
        var limits = ImageFinder.Limits()
        limits.maxTotalBytes = 3 * 4096 // too little for sources.rar, plenty for the two images
        let result = try ImageFinder.find(in: archive, workDirectory: work, limits: limits)
        XCTAssertEqual(result.images.map(\.path), ["cat", "dog.png"])
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(result.otherFiles, 2)
        XCTAssertEqual(result.unpackedBytes, 2 * 4096, "only the images were unpacked")
    }

    func testAnUnreadableArchiveInAFolderIsSkippedNotFatal() throws {
        let folder = directory.appendingPathComponent("perm", isDirectory: true)
        try write(png, to: folder.appendingPathComponent("a.png"))
        let locked = try TestZip([TestZip.Entry("b.png", png)]).write(to: folder.appendingPathComponent("locked.zip"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let result = try ImageFinder.find(in: folder, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["a.png"])
        XCTAssertEqual(result.skipped.map(\.path), ["locked.zip"])
        XCTAssertEqual(result.skipped.first?.reason, ZipError.unreadable.errorDescription)
    }

    // MARK: Limits

    func testNestingAndPerFileLimits() throws {
        // Nested four deep with a limit of three.
        var nested = TestZip([TestZip.Entry("bottom.png", png)]).data()
        for level in (1...3).reversed() {
            nested = TestZip([TestZip.Entry("level\(level).zip", nested, deflate: false), TestZip.Entry("\(level).png", png)]).data()
        }
        let deep = try write(nested, to: directory.appendingPathComponent("deep.zip"))
        var limits = ImageFinder.Limits()
        limits.maxNesting = 3
        let result = try ImageFinder.find(in: deep, workDirectory: work, limits: limits)
        XCTAssertEqual(result.images.map(\.path), ["1.png", "level1.zip/2.png", "level1.zip/level2.zip/3.png"])
        XCTAssertEqual(result.skipped.map(\.path), ["level1.zip/level2.zip/level3.zip"])

        let big = TestZip.Entry("big.png", Data(repeating: 1, count: 3000))
        let sized = try TestZip([TestZip.Entry("a.png", png), big]).write(to: directory.appendingPathComponent("sized.zip"))
        limits = ImageFinder.Limits()
        limits.maxFileBytes = 2000
        XCTAssertEqual(try ImageFinder.find(in: sized, workDirectory: work, limits: limits).skipped.map(\.path), ["big.png"])
    }

    /// The total is charged before unpacking, at least a disk block per file, across nested archives, whether or not
    /// the entry turns out usable.
    func testTheTotalSizeBudgetCoversEveryEntryAcrossArchives() throws {
        var damaged = TestZip.Entry("c-damaged.png", png)
        damaged.crc = 0
        let inner = TestZip([TestZip.Entry("e.png", png), TestZip.Entry("f.png", png)]).data()
        let archive = try TestZip([TestZip.Entry("a.png", png), TestZip.Entry("b.png", png), damaged,
                                   TestZip.Entry("d-inner.zip", inner, deflate: false), TestZip.Entry("g.png", png)])
            .write(to: directory.appendingPathComponent("budget.zip"))
        var limits = ImageFinder.Limits()
        // a, b, c-damaged, d-inner.zip and e: 4 KB each. Then nothing fits.
        limits.maxTotalBytes = 5 * 4096
        let result = try ImageFinder.find(in: archive, workDirectory: work, limits: limits)
        XCTAssertEqual(result.images.map(\.path), ["a.png", "b.png", "d-inner.zip/e.png"])
        XCTAssertEqual(result.skipped.map(\.path), ["c-damaged.png"])
        XCTAssertEqual(result.skipped[0].reason, ZipError.damaged.errorDescription)
        XCTAssertEqual(result.leftOutAtByteLimit, 2, "f and g: the rest, not a fault of theirs")
        XCTAssertEqual(result.firstLeftOutAtByteLimit, "d-inner.zip/f.png")
        XCTAssertEqual(result.unpackedBytes, 5 * 4096)
    }

    /// One import may span several searches (files picked together): what is left of the limits carries over.
    func testLimitsCarryOverBetweenSearches() throws {
        let archive = try TestZip([TestZip.Entry("a.png", png), TestZip.Entry("b.png", png), .directory("folder")])
            .write(to: directory.appendingPathComponent("two.zip"))
        let limits = ImageFinder.Limits()
        let result = try ImageFinder.find(in: archive, workDirectory: work, limits: limits)
        XCTAssertEqual(result.archiveEntries, 3)
        let remaining = limits.remaining(after: result)
        XCTAssertEqual(remaining.maxImages, limits.maxImages - 2)
        XCTAssertEqual(remaining.maxTotalBytes, limits.maxTotalBytes - 2 * 4096)
        XCTAssertEqual(remaining.maxEntries, limits.maxEntries - 3)
        var small = ImageFinder.Limits()
        small.maxEntries = 4
        XCTAssertThrowsError(try ImageFinder.find(in: archive, workDirectory: work, limits: small.remaining(after: result))) {
            XCTAssertEqual($0 as? ImageFinder.FinderError, .tooManyFiles(1))
        }
    }

    /// An archive that fails after reading its directory counts the records it read, so a pile of damaged archives can't
    /// each cost the whole allowance. One that isn't a ZIP at all (a download cut short, a RAR named .zip) costs nothing.
    func testDamagedArchivesCountTowardTheEntryLimit() throws {
        var damaged = TestZip((0..<40).map { TestZip.Entry.directory("d\($0)") })
        damaged.declaredEntryCount = 3 // the end record disagrees with the directory
        let folder = directory.appendingPathComponent("damaged", isDirectory: true)
        for index in 0..<3 { try write(damaged.data(), to: folder.appendingPathComponent("bad\(index).zip")) }
        try write(TestZip([TestZip.Entry("ok.png", png)]).data(), to: folder.appendingPathComponent("z.zip"))
        var limits = ImageFinder.Limits()
        limits.maxEntries = 100 // 40 + 40 records read, then the third goes over
        XCTAssertThrowsError(try ImageFinder.find(in: folder, workDirectory: work, limits: limits)) {
            XCTAssertEqual($0 as? ImageFinder.FinderError, .tooManyFiles(100))
        }

        let junk = directory.appendingPathComponent("junk", isDirectory: true)
        try write(Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }), to: junk.appendingPathComponent("a-broken.zip"))
        try write(TestZip([TestZip.Entry("sticker.png", png)]).data(), to: junk.appendingPathComponent("b-good.zip"))
        try write(png, to: junk.appendingPathComponent("c.png"))
        limits.maxEntries = 50
        let result = try ImageFinder.find(in: junk, workDirectory: work, limits: limits)
        XCTAssertEqual(result.images.map(\.path), ["b-good.zip/sticker.png", "c.png"])
        XCTAssertEqual(result.skipped.map(\.path), ["a-broken.zip"])
        XCTAssertEqual(result.archiveEntries, 1)
    }

    /// Skips for a limit are told apart from damage; writing failures name the entry, not the temporary file.
    func testLimitSkipsAndWriteFailures() throws {
        var damaged = TestZip.Entry("damaged.png", png)
        damaged.crc = 0
        let deep = TestZip([TestZip.Entry("inner.zip", TestZip([TestZip.Entry("x.png", png)]).data(), deflate: false)]).data()
        let archive = try TestZip([TestZip.Entry("big.png", Data(repeating: 1, count: 3000)), damaged,
                                   TestZip.Entry("deep.zip", deep, deflate: false), TestZip.Entry("ok.png", png)])
            .write(to: directory.appendingPathComponent("limits.zip"))
        var limits = ImageFinder.Limits()
        limits.maxFileBytes = 2000
        limits.maxNesting = 2
        let result = try ImageFinder.find(in: archive, workDirectory: work, limits: limits)
        XCTAssertEqual(result.skipped.map(\.path), ["big.png", "damaged.png", "deep.zip/inner.zip"])
        XCTAssertEqual(result.skipped.map(\.exceedsLimit), [true, false, true])

        let readOnly = directory.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        XCTAssertThrowsError(try ImageFinder.find(in: archive, workDirectory: readOnly)) { error in
            guard case let .cannotUnpack(path, reason) = error as? ImageFinder.FinderError else { return XCTFail("\(error)") }
            XCTAssertEqual(path, "big.png", "the first entry unpacked")
            XCTAssertFalse(reason.contains(".zip") || reason.contains(".png"), reason)
        }
    }

    /// A file without an extension that can't be read is reported, not taken for a non-image.
    func testUnreadableFilesWithoutExtensionAreReported() throws {
        let folder = directory.appendingPathComponent("bare", isDirectory: true)
        let bare = try write(png, to: folder.appendingPathComponent("3f2a9c0d"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bare.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bare.path) }
        let result = try ImageFinder.find(in: folder, workDirectory: work)
        XCTAssertEqual(result.skipped.map(\.path), ["3f2a9c0d"])
        XCTAssertEqual(result.otherFiles, 0)
    }

    /// Names longer than any real file's are refused, however they are padded (combining marks, "./"), and quickly:
    /// tens of thousands of marks would make every later comparison of the name slow. Hidden ones stay unmentioned.
    func testOverlongNamesAreRefusedQuickly() throws {
        let marks = "a" + String(repeating: "\u{301}\u{316}", count: 16_000)
        var names = (0..<50).map { marks + "\($0).png" }
        names += ["a" + String(repeating: "\u{301}", count: 600) + "b.png", String(repeating: "./", count: 600) + "z.png",
                  "__MACOSX/" + String(repeating: "m", count: 1_100) + ".png", "ok.png"]
        let entries = names.map { name -> TestZip.Entry in
            var entry = TestZip.Entry(name, png)
            entry.flags = 0x0800
            return entry
        }
        let archive = try TestZip(entries).write(to: directory.appendingPathComponent("marks.zip"))
        let started = Date()
        let result = try ImageFinder.find(in: archive, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["ok.png"])
        XCTAssertEqual(result.skipped.count, 52)
        XCTAssertFalse(result.skipped.contains { $0.path.hasPrefix("__MACOSX") })
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Opening a large archive can be stopped: the search hands its check to the archive reader, checks while leaving
    /// out folders and hidden files, and while sorting the names.
    func testOpeningALargeArchiveCanBeStopped() throws {
        // Folders aren't files to look at, and 3,000 records are fewer than the search's own walk checks at: only
        // decoding their names, inside the archive reader, checks.
        let folders = try TestZip((0..<3_000).map { TestZip.Entry.directory("f\($0)") })
            .write(to: directory.appendingPathComponent("folders.zip"))
        var calls = 0
        _ = try ImageFinder.find(in: folders, workDirectory: work, checkCancelled: { calls += 1 })
        XCTAssertGreaterThan(calls, 0)
        // 5,000 folders: the archive reader's 7 checks, then one while leaving them out; nothing to sort or look at.
        let manyFolders = try TestZip((0..<5_000).map { TestZip.Entry.directory("d\($0)") })
            .write(to: directory.appendingPathComponent("many-folders.zip"))
        calls = 0
        _ = try ImageFinder.find(in: manyFolders, workDirectory: work, checkCancelled: { calls += 1 })
        XCTAssertEqual(calls, 7 + 1)
        // 5,000 files in shuffled order: those 8, one per file, and some while sorting them.
        let files = try TestZip((0..<5_000).map { TestZip.Entry("\($0 * 7919 % 5_000).txt", Data(), deflate: false) })
            .write(to: directory.appendingPathComponent("files.zip"))
        calls = 0
        _ = try ImageFinder.find(in: files, workDirectory: work, checkCancelled: { calls += 1 })
        XCTAssertGreaterThan(calls, 8 + 5_000 + 5, "checked while sorting")
        calls = 0
        XCTAssertThrowsError(try ImageFinder.find(in: files, workDirectory: work, checkCancelled: {
            calls += 1
            if calls == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
    }

    /// Paths from an archive are shown shortened, and without control characters a terminal would act on.
    func testPathsAreShownSafely() {
        XCTAssertEqual(ImageFinder.displayPath("猫/ok.png"), "猫/ok.png")
        XCTAssertEqual(ImageFinder.displayPath("\u{1B}]0;title\u{07}\u{1B}[2Jevil\u{202E}gnp.png"), "\u{FFFD}]0;title\u{FFFD}\u{FFFD}[2Jevil\u{FFFD}gnp.png")
        let long = ImageFinder.displayPath(String(repeating: "a", count: 300) + ".png")
        XCTAssertEqual(long.unicodeScalars.count, 151)
        XCTAssertTrue(long.hasSuffix("a.png") && long.contains("…"))
    }

    /// A folder that can't be opened is reported, not passed over; the folder searched itself failing ends the search.
    func testUnreadableFoldersAreReported() throws {
        let folder = directory.appendingPathComponent("sub-in", isDirectory: true)
        try write(png, to: folder.appendingPathComponent("a.png"))
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try write(png, to: locked.appendingPathComponent("1.png"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let result = try ImageFinder.find(in: folder, workDirectory: work)
        XCTAssertEqual(result.images.map(\.path), ["a.png"])
        XCTAssertEqual(result.skipped.map(\.path), ["locked"])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try ImageFinder.find(in: folder, workDirectory: work))
    }

    /// Past the byte budget everything after is left out, loose files and later archives too, so "from X on" holds.
    func testTheByteBudgetLeavesOutATailOfTheOrderFound() throws {
        let folder = directory.appendingPathComponent("tail-in", isDirectory: true)
        try write(TestZip([TestZip.Entry("1.png", png), TestZip.Entry("2.png", png), TestZip.Entry("3.png", png)]).data(),
                  to: folder.appendingPathComponent("a.zip"))
        try write(png, to: folder.appendingPathComponent("b.png"))
        try write(TestZip([TestZip.Entry("x.png", png)]).data(), to: folder.appendingPathComponent("c.zip"))
        try write(png, to: folder.appendingPathComponent("d.png"))
        var limits = ImageFinder.Limits()
        limits.maxTotalBytes = 2 * 4096
        let result = try ImageFinder.find(in: folder, workDirectory: work, limits: limits)
        XCTAssertEqual(result.images.map(\.path), ["a.zip/1.png", "a.zip/2.png"])
        XCTAssertEqual(result.leftOutAtByteLimit, 4, "a.zip/3.png, b.png, c.zip and d.png")
        XCTAssertEqual(result.firstLeftOutAtByteLimit, "a.zip/3.png")
    }

    /// An AVIF image sequence without an extension: ImageIO reads it as "public.avis", a type the system doesn't
    /// declare.
    func testAnAVIFSequenceWithoutAnExtensionIsAnImage() throws {
        let avis = Data(base64Encoded: "AAAALGZ0eXBhdmlzAAAAAGF2aWZhdmlzbXNmMWlzbzhtaWYxbWlhZk1BMUEAAADrbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAOcGl0bQAAAAAAAQAAAB5pbG9jAAAAAEQAAAEAAQAAAAEAAAPlAAAAKQAAAChpaW5mAAAAAAABAAAAGmluZmUCAAAAAAEAAGF2MDFDb2xvcgAAAABqaXBycAAAAEtpcGNvAAAAFGlzcGUAAAAAAAAAEAAAABAAAAAQcGl4aQAAAAADCAgIAAAADGF2MUOBIAAAAAAAE2NvbHJuY2x4AAEADQAGgAAAABdpcG1hAAAAAAAAAAEAAQQBAoMEAAACxm1vb3YAAAB4bXZoZAEAAAAAAAAA5wtPywAAAADnC0/LAAAACv//////////AAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAJGdHJhawAAAGh0a2hkAQAAAQAAAADnC0/LAAAAAOcLT8sAAAABAAAAAP//////////AAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAQAAAAEAAAAAAALGVkdHMAAAAkZWxzdAEAAAEAAAABAAAAAAAAAAIAAAAAAAAAAAABAAAAAAGqbWRpYQAAACxtZGhkAQAAAAAAAADnC0/LAAAAAOcLT8sAAAAKAAAAAAAAAAJVxAAAAAAAIWhkbHIAAAAAAAAAAHBpY3QAAAAAAAAAAAAAAAAAAAABVW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAARVzdGJsAAAAlXN0c2QAAAAAAAAAAQAAAIVhdjAxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABCkFPTSBDb2RpbmcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAADGF2MUOBIAAAAAAAE2NvbHJuY2x4AAEADQAGgAAAABBjY3N0AAAAAHwAAAAAAAAYc3R0cwAAAAAAAAABAAAAAgAAAAEAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAIAAAABAAAAHHN0c3oAAAAAAAAAAAAAAAIAAAApAAAAPgAAABRzdGNvAAAAAAAAAAEAAAPlAAAAFHN0c3MAAAAAAAAAAQAAAAEAAABvbWRhdBIACgwgAAABn/m18kBDQaQyFxAAqgAggggkEEg5UJ82XrDPzEqslZnAEgAyOjADgID9+HqoAOOOOJBAKAACEpyIwNx1hs+4HiMF5//HhMnix2OM9n8goTgdedXYvswdGMQpsBmHfho=")!
        let folder = directory.appendingPathComponent("avis", isDirectory: true)
        try write(avis, to: folder.appendingPathComponent("3f2a9c0d"))
        XCTAssertEqual(try ImageFinder.find(in: folder, workDirectory: work).images.map(\.path), ["3f2a9c0d"])
        let archive = try TestZip([TestZip.Entry("3f2a9c0d", avis)]).write(to: directory.appendingPathComponent("avis.zip"))
        XCTAssertEqual(try ImageFinder.find(in: archive, workDirectory: work).images.map(\.path), ["3f2a9c0d"])
    }

    /// A large file that isn't an image is told apart before its size matters: left out, not "too large".
    func testLargeNonImagesAreLeftOutNotSkipped() throws {
        let rar = Data("Rar!\u{1A}\u{07}\u{01}\u{00}".utf8) + Data(repeating: 0, count: 5000)
        let procreate = TestZip([TestZip.Entry("Document.archive", Data(repeating: 7, count: 5000), deflate: false),
                                 TestZip.Entry("QuickLook/Thumbnail.png", png)]).data()
        let archive = try TestZip([TestZip.Entry("sources.rar", rar), TestZip.Entry("art.procreate", procreate),
                                   TestZip.Entry("sticker.png", png)])
            .write(to: directory.appendingPathComponent("pack.zip"))
        var limits = ImageFinder.Limits()
        limits.maxFileBytes = 2000
        let result = try ImageFinder.find(in: archive, workDirectory: work, limits: limits)
        XCTAssertEqual(result.images.map(\.path), ["sticker.png"])
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(result.otherFiles, 2)
    }

    /// Every record counts toward the entry limit, folders and hidden files included, and nested archives share it.
    /// Going over it fails the whole search, which then removes what it unpacked.
    func testTheEntryLimitCountsEveryRecordAndFailsTheSearch() throws {
        let folders = (0..<10).map { TestZip.Entry.directory("folder\($0)") }
        let archive = try TestZip([TestZip.Entry("a.png", png)] + folders).write(to: directory.appendingPathComponent("folders.zip"))
        var limits = ImageFinder.Limits()
        limits.maxEntries = 5
        XCTAssertThrowsError(try ImageFinder.find(in: archive, workDirectory: work, limits: limits)) {
            XCTAssertEqual($0 as? ImageFinder.FinderError, .tooManyFiles(5))
        }

        // The nested archive that goes over is the last entry: the search fails rather than returning half of it.
        let inner = TestZip((0..<4).map { TestZip.Entry("\($0).png", png) }).data()
        let outer = try TestZip([TestZip.Entry("first.png", png), TestZip.Entry("inner.zip", inner, deflate: false)])
            .write(to: directory.appendingPathComponent("outer.zip"))
        XCTAssertThrowsError(try ImageFinder.find(in: outer, workDirectory: work, limits: limits)) {
            XCTAssertEqual($0 as? ImageFinder.FinderError, .tooManyFiles(5))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [], "first.png was removed again")

        // Archives side by side in a folder share the limit; going over it ends the search rather than blaming one.
        let folder = directory.appendingPathComponent("siblings", isDirectory: true)
        try write(TestZip((0..<4).map { TestZip.Entry("\($0).png", png) }).data(), to: folder.appendingPathComponent("a.zip"))
        try write(TestZip([TestZip.Entry("x.png", png), TestZip.Entry("y.png", png)]).data(), to: folder.appendingPathComponent("b.zip"))
        XCTAssertThrowsError(try ImageFinder.find(in: folder, workDirectory: work, limits: limits)) {
            XCTAssertEqual($0 as? ImageFinder.FinderError, .tooManyFiles(5))
        }
    }

    /// The limit keeps the first images by name, whatever order the archive or the file system lists them in (Finder
    /// writes ZIP entries in directory hash order), so "the rest" is a well-defined set.
    func testTheImageLimitStopsTheSearchAndSaysSo() throws {
        let archive = try TestZip([5, 3, 1, 4, 2].map { TestZip.Entry("\($0).png", png) }).write(to: directory.appendingPathComponent("five.zip"))
        var limits = ImageFinder.Limits()
        limits.maxImages = 3
        let result = try ImageFinder.find(in: archive, workDirectory: work, limits: limits)
        XCTAssertEqual(result.images.map(\.path), ["1.png", "2.png", "3.png"])
        XCTAssertTrue(result.reachedImageLimit)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).count, 3)
        limits.maxImages = 5
        XCTAssertFalse(try ImageFinder.find(in: archive, workDirectory: work, limits: limits).reachedImageLimit)
    }

    /// An archive's images come where the archive is, so the limit keeps what comes first in that order even when a
    /// sibling's name starts with the archive's ("Cats.zip.png" sorts before "Cats.zip/1.png" as text).
    func testTheImageLimitKeepsTheFirstInTheOrderFound() throws {
        let folder = directory.appendingPathComponent("cats", isDirectory: true)
        try write(TestZip([TestZip.Entry("1.png", png), TestZip.Entry("2.png", png)]).data(), to: folder.appendingPathComponent("Cats.zip"))
        try write(png, to: folder.appendingPathComponent("Cats.zip.png"))
        let all = try ImageFinder.find(in: folder, workDirectory: work)
        var limits = ImageFinder.Limits()
        for count in 1...3 {
            limits.maxImages = count
            let some = try ImageFinder.find(in: folder, workDirectory: work, limits: limits)
            XCTAssertEqual(some.images.map(\.path), Array(all.images.map(\.path).prefix(count)), "\(count)")
        }
    }

    /// A cancel (from the CLI's signal handling) ends the search at the next file, and what it unpacked is removed.
    func testCancellingEndsTheSearchAndRemovesWhatItUnpacked() throws {
        struct Stop: Error {}
        let archive = try TestZip((1...5).map { TestZip.Entry("\($0).png", png) }).write(to: directory.appendingPathComponent("five.zip"))
        var checks = 0
        XCTAssertThrowsError(try ImageFinder.find(in: archive, workDirectory: work, checkCancelled: {
            checks += 1
            if checks == 3 { throw Stop() }
        })) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    func testSingleFilesAndNonImages() throws {
        let image = try write(png, to: directory.appendingPathComponent("one.png"))
        XCTAssertEqual(try ImageFinder.find(in: image, workDirectory: work).images.map(\.url), [image])
        let text = try write(Data("x".utf8), to: directory.appendingPathComponent("x.txt"))
        XCTAssertThrowsError(try ImageFinder.find(in: text, workDirectory: work))
        let fake = try write(Data("not a zip".utf8), to: directory.appendingPathComponent("fake.zip"))
        XCTAssertThrowsError(try ImageFinder.find(in: fake, workDirectory: work)) {
            XCTAssertEqual($0 as? ZipError, .notAnArchive)
        }
        XCTAssertTrue(ImageFinder.isArchive(fake), "by extension")
        XCTAssertFalse(ImageFinder.isArchive(image))
    }

    // MARK: Helpers

    @discardableResult
    private func write(_ data: Data, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}
