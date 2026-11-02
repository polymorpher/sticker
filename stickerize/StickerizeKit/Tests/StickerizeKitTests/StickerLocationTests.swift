import Foundation
import StickerizeKit
import XCTest

/// Where the library lives in an App Group container, and the move from where builds before kept it.
final class StickerLocationTests: XCTestCase {
    private var container: URL!

    private var current: URL { container.appendingPathComponent("Library/Application Support/Stickers", isDirectory: true) }
    private var legacy: URL { container.appendingPathComponent("Stickers", isDirectory: true) }

    override func setUp() {
        container = TestImages.temporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
        try? FileManager.default.removeItem(at: container)
    }

    private let notificationName = "xyz.hiddenstate.stickerize.tests.\(UUID().uuidString)"

    private func store(_ directory: URL) -> StickerStore {
        StickerStore(directory: directory, changeNotificationName: "xyz.hiddenstate.stickerize.tests.\(UUID().uuidString)")
    }

    private func sample() throws -> EncodedSticker {
        let canvas = StickerCanvas(maxPixelDimension: 618, minPixelDimension: 0, maxUpscale: 1, maxBytes: 500_000)
        return try StickerEncoder.encode(TestImages.halves(width: 40, height: 30), canvas: canvas)
    }

    func testALibraryAtTheTopLevelMovesUnderLibraryWithEverythingInIt() throws {
        let old = store(legacy)
        _ = try old.add(try sample(), name: "fluffy cat", emoji: "🐱", path: ["Pets"])
        let before = try old.library()

        let directory = StickerStore.libraryDirectory(inGroupContainer: container, changeNotificationName: notificationName)

        XCTAssertEqual(directory.standardizedFileURL, current.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try store(directory).library(), before)
        XCTAssertEqual(StickerStore.libraryDirectory(inGroupContainer: container, changeNotificationName: notificationName)
            .standardizedFileURL, current.standardizedFileURL, "and stays there")
    }

    func testANewContainerUsesTheNewPlaceAndCreatesNothing() throws {
        XCTAssertEqual(StickerStore.libraryDirectory(inGroupContainer: container, changeNotificationName: notificationName)
            .standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: container.path), [])
    }

    /// An older build sharing the App Group still saves to the top level after the move.
    func testWhatAnOlderBuildSavesAfterTheMoveIsMergedInAndSetAside() throws {
        let moved = try store(current).add(try sample(), name: "moved", path: ["Pets"])
        let later = try store(legacy).add(try sample(), name: "made later", emoji: "🐶", path: ["Pets", "Dogs"])

        XCTAssertEqual(StickerStore.libraryDirectory(inGroupContainer: container, changeNotificationName: notificationName)
            .standardizedFileURL, current.standardizedFileURL)

        let library = try store(current).library()
        XCTAssertEqual(Set(library.stickers.map(\.id)), [moved.id, later.id])
        XCTAssertEqual(library.path(to: library.stickers.first { $0.id == later.id }?.folderID).map(\.name), ["Pets", "Dogs"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "so it isn't merged again")
        let support = current.deletingLastPathComponent()
        let aside = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: support.path)
            .first { $0.hasPrefix("Stickers saved by an older build") })
        XCTAssertEqual(try store(support.appendingPathComponent(aside)).library().stickers.map(\.name), ["made later"],
                       "kept where devicectl can reach it")
    }

    func testAProcessThatCantWriteLeavesBothAsTheyAre() throws {
        _ = try store(current).add(try sample(), name: "moved")
        _ = try store(legacy).add(try sample(), name: "made later")
        for folder in [current, container!] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: current.path) }

        XCTAssertEqual(StickerStore.libraryDirectory(inGroupContainer: container, changeNotificationName: notificationName)
            .standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(try store(legacy).library().stickers.map(\.name), ["made later"], "left for a process that can write")
        XCTAssertEqual(try store(current).library().stickers.map(\.name), ["moved"])
    }

    func testAProcessThatCantWriteReadsItWhereItIs() throws {
        _ = try store(legacy).add(try sample(), name: "fluffy cat")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: container.path)

        let directory = StickerStore.libraryDirectory(inGroupContainer: container, changeNotificationName: notificationName)

        XCTAssertEqual(directory.standardizedFileURL, legacy.standardizedFileURL)
        XCTAssertEqual(try store(directory).library().stickers.map(\.name), ["fluffy cat"])
    }
}
