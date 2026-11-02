import Foundation
import StickerizeKit
import XCTest

/// Merging one library into another, as moving stickers between installs with different App Groups does.
final class StickerMergeTests: XCTestCase {
    private var root: URL!
    private var source: StickerStore!
    private var destination: StickerStore!

    override func setUp() {
        root = TestImages.temporaryDirectory()
        source = store("Old")
        destination = store("New")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(_ name: String) -> StickerStore {
        StickerStore(directory: root.appendingPathComponent(name).appendingPathComponent("Stickers", isDirectory: true),
                     changeNotificationName: "xyz.hiddenstate.stickerize.tests.\(UUID().uuidString)")
    }

    /// A distinct image for each width.
    private func sample(width: Int = 40) throws -> EncodedSticker {
        let canvas = StickerCanvas(maxPixelDimension: 618, minPixelDimension: 0, maxUpscale: 1, maxBytes: 500_000)
        return try StickerEncoder.encode(TestImages.halves(width: width, height: 30), canvas: canvas)
    }

    private func files(_ store: StickerStore) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        return try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: store.directory.appendingPathComponent($0))) })
    }

    func testMergeIntoAnEmptyLibraryKeepsEverything() throws {
        let pets = try source.createFolder(named: "Pets")
        _ = try source.createFolder(named: "Empty")
        let cat = try source.add(try sample(width: 40), name: "fluffy cat", emoji: "🐱", in: pets.id, path: ["Cats"])
        let dog = try source.add(try sample(width: 50), name: "good boy", emoji: "🐶", in: pets.id, path: ["Dogs"])
        let top = try source.add(try sample(width: 60), name: "party")
        let before = try source.library()

        let summary = try destination.merge(from: source)

        XCTAssertEqual(summary, StickerStore.MergeSummary(added: 3, alreadyHere: 0, duplicates: 0, foldersAdded: 4, foldersMatched: 0))
        let after = try destination.library()
        XCTAssertEqual(after.stickers, before.stickers, "IDs, names, emoji, dates, folders and order")
        XCTAssertEqual(Set(after.folders.map(\.id)), Set(before.folders.map(\.id)))
        XCTAssertEqual(after.outline().map { after.path(to: $0.folder.id).map(\.name) },
                       before.outline().map { before.path(to: $0.folder.id).map(\.name) }, "empty folders included")
        for sticker in [cat, dog, top] {
            XCTAssertEqual(try destination.data(for: sticker), try source.data(for: sticker))
        }
    }

    func testMergedStickersComeAfterTheLibrarysOwnAndSameNamedFoldersCombine() throws {
        let mine = try destination.add(try sample(width: 40), name: "mine", path: ["pets", "Cats"])
        let theirs = try source.add(try sample(width: 50), name: "theirs", path: ["Pets", "Cats"])
        let other = try source.add(try sample(width: 60), name: "other", path: ["Pets", "Birds"])

        let summary = try destination.merge(from: source)

        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.foldersMatched, 2, "Pets and Pets › Cats")
        XCTAssertEqual(summary.foldersAdded, 1, "Pets › Birds")
        let library = try destination.library()
        XCTAssertEqual(library.stickers.map(\.id), [mine.id, other.id, theirs.id], "the source's order, after this library's own")
        let pets = try XCTUnwrap(library.children(of: nil).first)
        XCTAssertEqual(library.children(of: nil).count, 1)
        XCTAssertEqual(pets.name, "pets", "the folder already here keeps its name")
        XCTAssertEqual(library.children(of: pets.id).map(\.name), ["Birds", "Cats"])
        XCTAssertEqual(Set(library.stickers(in: mine.folderID).map(\.id)), [mine.id, theirs.id])
    }

    func testMergingAgainAddsNothing() throws {
        _ = try source.add(try sample(width: 40), name: "a", path: ["Pets"])
        _ = try source.add(try sample(width: 50), name: "b")
        try destination.merge(from: source)
        let once = try destination.library()
        let filesOnce = try files(destination)

        let summary = try destination.merge(from: source)

        XCTAssertEqual(summary, StickerStore.MergeSummary(added: 0, alreadyHere: 2, duplicates: 0, foldersAdded: 0, foldersMatched: 1))
        XCTAssertEqual(try destination.library(), once)
        XCTAssertEqual(try files(destination), filesOnce)
    }

    func testAnIdenticalStickerInTheSameFolderIsNotDoubled() throws {
        let image = try sample(width: 40)
        let kept = try destination.add(image, name: "cat", emoji: "🐱", path: ["Pets"])
        let same = try source.add(image, name: "cat", emoji: "🐱", path: ["Pets"])
        let renamed = try source.add(image, name: "kitty", emoji: "🐱", path: ["Pets"])
        let elsewhere = try source.add(image, name: "cat", emoji: "🐱")
        let otherImage = try source.add(try sample(width: 50), name: "cat", emoji: "🐱", path: ["Pets"])

        let summary = try destination.merge(from: source)

        XCTAssertEqual(summary.duplicates, 1)
        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(Set(try destination.library().stickers.map(\.id)), [kept.id, renamed.id, elsewhere.id, otherImage.id])
        XCTAssertNil(try files(destination)[same.fileName], "the duplicate's copied file is removed again")
    }

    func testTheSourceIsNeverWritten() throws {
        _ = try source.add(try sample(width: 40), name: "a", path: ["Pets", "Cats"])
        _ = try destination.add(try sample(width: 40), name: "a", path: ["Pets", "Cats"])
        let before = try files(source)
        try destination.merge(from: source)
        XCTAssertEqual(try files(source), before)
    }

    func testALibraryFromANewerBuildIsRefusedAndNothingChanges() throws {
        _ = try source.add(try sample(width: 40), name: "a")
        let manifestURL = source.directory.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        _ = try destination.add(try sample(width: 50), name: "mine")
        let before = try files(destination)

        XCTAssertThrowsError(try destination.merge(from: source)) { error in
            XCTAssertEqual(error as? StickerStoreError, .manifestFromNewerVersion)
        }
        XCTAssertEqual(try files(destination), before, "no image copied in")
    }

    func testALibraryFromBeforeFoldersMergesAtTheTopLevel() throws {
        let sticker = try source.add(try sample(width: 40), name: "old", emoji: "😀")
        // What a build from before folders wrote: version 1, no folders, no folderID.
        let manifestURL = source.directory.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        json["version"] = 1
        json["folders"] = nil
        json["stickers"] = (json["stickers"] as? [[String: Any]])?.map { var entry = $0; entry["folderID"] = nil; return entry }
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        let summary = try destination.merge(from: source)

        XCTAssertEqual(summary.added, 1)
        let merged = try XCTUnwrap(try destination.library().stickers.first)
        XCTAssertEqual(merged.id, sticker.id)
        XCTAssertEqual(merged.name, "old")
        XCTAssertEqual(merged.emoji, "😀")
        XCTAssertNil(merged.folderID)
    }

    /// A copy that stopped after the images, before the manifest: the images are here, unlisted.
    func testImagesLeftWithoutAManifestGetTheSourcesEntries() throws {
        let cat = try source.add(try sample(width: 40), name: "fluffy cat", emoji: "🐱", path: ["Pets", "Cats"])
        let dog = try source.add(try sample(width: 50), name: "good boy", emoji: "🐶", path: ["Pets", "Dogs"])
        try FileManager.default.createDirectory(at: destination.directory, withIntermediateDirectories: true)
        for sticker in [cat, dog] {
            try FileManager.default.copyItem(at: source.fileURL(for: sticker), to: destination.fileURL(for: sticker))
        }

        let summary = try destination.merge(from: source)

        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.alreadyHere, 0, "a manifest rebuilt from the files lists placeholders, not these stickers")
        XCTAssertEqual(try destination.library().stickers, try source.library().stickers, "names, emoji and folders")
    }

    /// The same, with the images of two sources: the placeholders the first merge saves aren't taken for the second's.
    func testImagesLeftWithoutAManifestGetEachSourcesEntriesWhenMergedTogether() throws {
        let other = store("Older")
        let cat = try source.add(try sample(width: 40), name: "fluffy cat", path: ["Pets"])
        let dog = try other.add(try sample(width: 50), name: "good boy", path: ["Dogs"])
        try FileManager.default.createDirectory(at: destination.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.fileURL(for: cat), to: destination.fileURL(for: cat))
        try FileManager.default.copyItem(at: other.fileURL(for: dog), to: destination.fileURL(for: dog))

        let summaries = try destination.merge(from: [source, other])

        XCTAssertEqual(summaries.map(\.added), [1, 1])
        let library = try destination.library()
        XCTAssertEqual(Set(library.stickers.map(\.name)), ["fluffy cat", "good boy"])
        XCTAssertEqual(library.outline().map(\.folder.name), ["Dogs", "Pets"])
    }

    /// The same, after the app saved the placeholders it showed for those images (any change in the app saves them).
    func testSavedPlaceholdersGetTheSourcesEntriesBack() throws {
        let cat = try source.add(try sample(width: 40), name: "fluffy cat", emoji: "🐱", path: ["Pets", "Cats"])
        let dog = try source.add(try sample(width: 50), name: "good boy", path: ["Pets", "Dogs"])
        try FileManager.default.createDirectory(at: destination.directory, withIntermediateDirectories: true)
        for sticker in [cat, dog] {
            try FileManager.default.copyItem(at: source.fileURL(for: sticker), to: destination.fileURL(for: sticker))
        }
        _ = try destination.createFolder(named: "Mine")
        try destination.rename(dog.id, to: "my dog")

        let summary = try destination.merge(from: source)

        XCTAssertEqual(summary.placeholdersFilled, 1)
        XCTAssertEqual(summary.alreadyHere, 1, "a sticker renamed here keeps its name")
        XCTAssertEqual(summary.added, 0)
        let library = try destination.library()
        let merged = try XCTUnwrap(library.stickers.first { $0.id == cat.id })
        XCTAssertEqual(merged.name, "fluffy cat")
        XCTAssertEqual(merged.emoji, "🐱")
        XCTAssertEqual(library.path(to: merged.folderID).map(\.name), ["Pets", "Cats"])
        XCTAssertEqual(library.stickers.first { $0.id == dog.id }?.name, "my dog")
    }

    func testAPartialLeftoverImageIsReplaced() throws {
        let cat = try source.add(try sample(width: 40), name: "fluffy cat", path: ["Pets"])
        _ = try destination.add(try sample(width: 50), name: "mine")
        let image = try source.data(for: cat)
        try image.prefix(image.count / 2).write(to: destination.fileURL(for: cat))

        XCTAssertEqual(try destination.merge(from: source).added, 1)
        XCTAssertEqual(try destination.data(for: cat), image)
    }

    func testMergingAgainBringsBackWhatWasDeletedHere() throws {
        _ = try source.add(try sample(width: 40), name: "a", path: ["Pets"])
        try destination.merge(from: source)
        let pets = try XCTUnwrap(try destination.library().children(of: nil).first)
        try destination.deleteFolder(pets.id, keepingContents: false)

        let summary = try destination.merge(from: source)

        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.foldersAdded, 1)
    }

    func testAnEmptyOrMissingSourceAddsNothing() throws {
        _ = try destination.add(try sample(width: 40), name: "mine")
        let before = try destination.library()
        XCTAssertEqual(try destination.merge(from: source), StickerStore.MergeSummary())
        XCTAssertEqual(try destination.library(), before)
    }
}
