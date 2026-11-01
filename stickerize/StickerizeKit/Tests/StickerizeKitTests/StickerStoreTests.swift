import Foundation
import ImageIO
import StickerizeKit
import XCTest

final class StickerStoreTests: XCTestCase {
    private var directory: URL!
    private var store: StickerStore!

    override func setUp() {
        directory = TestImages.temporaryDirectory().appendingPathComponent("Stickers", isDirectory: true)
        store = StickerStore(directory: directory, changeNotificationName: "ai.qokka.stickerize.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    /// Small stickers that keep their size (no padding or upscaling), so widths identify them.
    private func sample(_ width: Int = 40) throws -> EncodedSticker {
        let canvas = StickerCanvas(maxPixelDimension: 618, minPixelDimension: 0, maxUpscale: 1, maxBytes: 500_000)
        return try StickerEncoder.encode(TestImages.halves(width: width, height: 30), canvas: canvas)
    }

    func testEmptyStoreHasNoStickers() throws {
        XCTAssertEqual(try store.stickers(), [])
    }

    func testAddPutsNewestFirstAndWritesFiles() throws {
        let first = try store.add(try sample(), name: "First")
        let second = try store.add(try sample(50), name: "  Second  ")
        let stickers = try store.stickers()
        XCTAssertEqual(stickers.map(\.id), [second.id, first.id])
        XCTAssertEqual(stickers[0].name, "Second")
        XCTAssertEqual(stickers[0].pixelWidth, 50)
        XCTAssertEqual(try store.data(for: first), try sample().data)
        XCTAssertEqual(first.format, .png)
        XCTAssertTrue(first.fileName.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
    }

    func testEmojiIsStoredAndUpdated() throws {
        let a = try store.add(try sample(), name: "A", emoji: " 🐱 ")
        XCTAssertEqual(try store.stickers().first?.emoji, "🐱")
        try store.update(a.id, name: "Cat", emoji: "😺🐈🐾🐟")
        let updated = try XCTUnwrap(try store.stickers().first)
        XCTAssertEqual(updated.name, "Cat")
        XCTAssertEqual(updated.emoji, "😺🐈🐾")
        try store.update(a.id, name: "Cat", emoji: "")
        XCTAssertNil(try store.stickers().first?.emoji)
    }

    func testManifestWithoutEmojiFieldStillDecodes() throws {
        let a = try store.add(try sample(), name: "A")
        let url = directory.appendingPathComponent("manifest.json")
        let legacy = """
        {"version":1,"stickers":[{"id":"\(a.id.uuidString)","name":"Old","createdAt":"2026-10-01T10:00:00Z",
        "pixelWidth":40,"pixelHeight":30,"byteCount":100}]}
        """
        try Data(legacy.utf8).write(to: url)
        let stickers = try store.stickers()
        XCTAssertEqual(stickers.map(\.name), ["Old"])
        XCTAssertNil(stickers[0].emoji)
        XCTAssertEqual(stickers[0].format, .png, "manifests from before animated stickers are all PNG")
    }

    func testPasteboardCopyIsAtMost512Pixels() throws {
        let big = try store.add(try StickerEncoder.encode(TestImages.halves(width: 1200, height: 600)), name: "Big")
        XCTAssertEqual(big.pixelWidth, 618)
        let pasted = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(try store.pasteboardItem(for: big).data as CFData, nil)!, 0, nil))
        XCTAssertEqual(try store.pasteboardItem(for: big).type, .png)
        XCTAssertEqual(max(pasted.width, pasted.height), 512)
        let small = try store.add(try sample(), name: "Small")
        XCTAssertEqual(try store.pasteboardItem(for: small).data, try store.data(for: small), "small stickers are copied as-is")
    }

    func testBlankNameBecomesDefault() throws {
        XCTAssertEqual(try store.add(try sample(), name: "   ").name, "Sticker")
    }

    func testRenameDeleteReorder() throws {
        let a = try store.add(try sample(), name: "A")
        let b = try store.add(try sample(), name: "B")
        let c = try store.add(try sample(), name: "C")
        try store.rename(b.id, to: "Bee")
        XCTAssertEqual(try store.stickers().map(\.name), ["C", "Bee", "A"])

        try store.reorder([a.id, c.id])
        XCTAssertEqual(try store.stickers().map(\.name), ["A", "C", "Bee"])

        try store.delete([c.id])
        XCTAssertEqual(try store.stickers().map(\.name), ["A", "Bee"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: c).path))

        XCTAssertThrowsError(try store.rename(c.id, to: "gone"))
    }

    func testStickersWithMissingFilesAreSkipped() throws {
        let a = try store.add(try sample(), name: "A")
        _ = try store.add(try sample(), name: "B")
        try FileManager.default.removeItem(at: store.fileURL(for: a))
        XCTAssertEqual(try store.stickers().map(\.name), ["B"])
    }

    func testCorruptManifestIsRebuiltFromFiles() throws {
        let a = try store.add(try sample(), name: "A")
        let b = try store.add(try sample(60), name: "B")
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        let recovered = try store.stickers()
        XCTAssertEqual(Set(recovered.map(\.id)), [a.id, b.id])
        XCTAssertEqual(recovered.first { $0.id == b.id }?.pixelWidth, 60)
        // Readers (the iMessage and keyboard extensions) rebuild in memory only and leave the file alone.
        func backups() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("manifest.corrupt-") }
        }
        XCTAssertEqual(try backups().count, 0)
        XCTAssertEqual(Set(try store.stickers().map(\.id)), [a.id, b.id])
        // The next write sets the bad file aside and persists the rebuilt library.
        try store.rename(a.id, to: "A again")
        XCTAssertEqual(try backups().count, 1)
        XCTAssertEqual(try store.stickers().first { $0.id == a.id }?.name, "A again")
    }

    func testUnreadableManifestIsNeverOverwritten() throws {
        let a = try store.add(try sample(), name: "A")
        let url = directory.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: url)
        // A manifest that exists but can't be read right now (here: a directory in its place stands in for a
        // protection or permission error) must make writes fail, not replace it with a library rebuilt from files.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.rename(a.id, to: "Renamed"))
        try FileManager.default.removeItem(at: url)
        try before.write(to: url)
        XCTAssertEqual(try store.stickers().map(\.name), ["A"])
    }

    func testConcurrentWritersDontLoseUpdates() throws {
        let encoded = try sample()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "writers", attributes: .concurrent)
        let errors = ErrorBox()
        let store = self.store!
        for i in 0..<40 {
            group.enter()
            queue.async {
                do { try store.add(encoded, name: "S\(i)") } catch { errors.append(error) }
                group.leave()
            }
        }
        group.wait()
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try store.stickers().count, 40)
    }

    func testChangeNotificationIsDelivered() throws {
        let delivered = expectation(description: "change observed")
        delivered.assertForOverFulfill = false
        let observer = store.observeChanges { delivered.fulfill() }
        _ = try store.add(try sample(), name: "A")
        wait(for: [delivered], timeout: 5)
        withExtendedLifetime(observer) {}
    }

    func testFallsBackToLocalStorageWithoutAppGroup() {
        let store = StickerStore(appGroupIdentifier: nil)
        XCTAssertEqual(store.location, .local)
        XCTAssertEqual(store.directory.lastPathComponent, "Stickers")
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func append(_ error: Error) { lock.withLock { errors.append(error) } }
    var isEmpty: Bool { lock.withLock { errors.isEmpty } }
}
