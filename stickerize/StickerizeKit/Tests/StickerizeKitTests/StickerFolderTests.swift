import Foundation
import StickerizeKit
import XCTest

final class StickerFolderTests: XCTestCase {
    private var directory: URL!
    private var store: StickerStore!

    override func setUp() {
        directory = TestImages.temporaryDirectory().appendingPathComponent("Stickers", isDirectory: true)
        store = StickerStore(directory: directory, changeNotificationName: "ai.qokka.stickerize.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func sample() throws -> EncodedSticker {
        let canvas = StickerCanvas(maxPixelDimension: 618, minPixelDimension: 0, maxUpscale: 1, maxBytes: 500_000)
        return try StickerEncoder.encode(TestImages.halves(width: 40, height: 30), canvas: canvas)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    private func manifestJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    }

    // MARK: Store

    func testAddIntoPathCreatesFoldersOnceAndReusesThem() throws {
        let a = try store.add(try sample(), name: "A", path: ["Cats", "Happy"])
        let b = try store.add(try sample(), name: "B", path: ["cats", "ＨＡＰＰＹ"])
        let library = try store.library()
        XCTAssertEqual(library.folders.count, 2, "case and width don't make a new folder")
        let cats = try XCTUnwrap(library.children(of: nil).first)
        let happy = try XCTUnwrap(library.children(of: cats.id).first)
        XCTAssertEqual(cats.name, "Cats")
        XCTAssertEqual(happy.name, "Happy")
        XCTAssertEqual(a.folderID, happy.id, "the returned sticker says where it went")
        XCTAssertEqual(Set(library.stickers(in: happy.id).map(\.id)), [a.id, b.id])
        XCTAssertEqual(library.path(to: happy.id).map(\.name), ["Cats", "Happy"])
    }

    func testAccentsMakeDifferentFolders() throws {
        _ = try store.add(try sample(), name: "A", path: ["Bär"])
        _ = try store.add(try sample(), name: "B", path: ["Bar"])
        XCTAssertEqual(try store.library().children(of: nil).map(\.name), ["Bar", "Bär"])
    }

    func testAddIntoDeletedFolderFallsBackToTopLevel() throws {
        let folder = try store.createFolder(named: "Gone")
        try store.deleteFolder(folder.id, keepingContents: false)
        let sticker = try store.add(try sample(), name: "A", in: folder.id, path: ["Sub"])
        let library = try store.library()
        XCTAssertEqual(library.children(of: nil).map(\.name), ["Sub"])
        XCTAssertEqual(sticker.folderID, library.children(of: nil).first?.id)
    }

    func testBatchKeepsItsOrderWithAfter() throws {
        let existing = try store.add(try sample(), name: "Old")
        var last: UUID?
        for name in ["1", "2", "3"] {
            last = try store.add(try sample(), name: name, after: last).id
        }
        XCTAssertEqual(try store.stickers().map(\.name), ["1", "2", "3", "Old"])
        // A sticker the batch follows that was deleted meanwhile: the next one goes to the front.
        try store.delete([try XCTUnwrap(last)])
        _ = try store.add(try sample(), name: "4", after: last)
        XCTAssertEqual(try store.stickers().map(\.name), ["4", "1", "2", "Old"])
        XCTAssertNotNil(existing)
    }

    func testCreateFolderNumbersTakenNames() throws {
        let parent = try store.createFolder(named: "  Animals ")
        XCTAssertEqual(parent.name, "Animals")
        XCTAssertEqual(try store.createFolder(named: "Cats", in: parent.id).name, "Cats")
        XCTAssertEqual(try store.createFolder(named: "CATS", in: parent.id).name, "CATS 2")
        XCTAssertEqual(try store.createFolder(named: "cats", in: parent.id).name, "cats 3")
        XCTAssertEqual(try store.createFolder(named: "Cats").name, "Cats", "another place, no clash")
        XCTAssertEqual(try store.createFolder(named: "   ").name, "Folder")
        XCTAssertThrowsError(try store.createFolder(named: "X", in: UUID())) { error in
            guard case StickerStoreError.folderNotFound = error else { return XCTFail("\(error)") }
        }
    }

    func testRenameFolderRefusesTakenName() throws {
        let cats = try store.createFolder(named: "Cats")
        let dogs = try store.createFolder(named: "Dogs")
        XCTAssertThrowsError(try store.renameFolder(dogs.id, to: "cats")) { error in
            XCTAssertEqual(error as? StickerStoreError, .folderNameTaken("cats"))
        }
        try store.renameFolder(cats.id, to: "CATS")
        try store.renameFolder(dogs.id, to: "AC/DC")
        XCTAssertEqual(try store.library().children(of: nil).map(\.name), ["AC/DC", "CATS"], "“/” is allowed")
    }

    func testMoveFolderPreventsCyclesAndNumbersClashes() throws {
        let a = try store.createFolder(named: "A")
        let b = try store.createFolder(named: "B", in: a.id)
        let c = try store.createFolder(named: "C", in: b.id)
        XCTAssertThrowsError(try store.moveFolder(a.id, into: c.id)) { XCTAssertEqual($0 as? StickerStoreError, .folderCycle) }
        XCTAssertThrowsError(try store.moveFolder(a.id, into: a.id)) { XCTAssertEqual($0 as? StickerStoreError, .folderCycle) }
        _ = try store.createFolder(named: "C")
        try store.moveFolder(c.id, into: nil)
        let library = try store.library()
        XCTAssertEqual(library.children(of: nil).map(\.name), ["A", "C", "C 2"])
        XCTAssertEqual(library.children(of: b.id), [])
    }

    func testDeleteFolderKeepingContentsMovesThemUp() throws {
        let animals = try store.createFolder(named: "Animals")
        let cats = try store.createFolder(named: "Cats", in: animals.id)
        _ = try store.createFolder(named: "Kittens", in: cats.id)
        _ = try store.createFolder(named: "Kittens", in: animals.id)
        let sticker = try store.add(try sample(), name: "A", in: cats.id)
        try store.deleteFolder(cats.id, keepingContents: true)
        let library = try store.library()
        XCTAssertEqual(library.children(of: animals.id).map(\.name), ["Kittens", "Kittens 2"])
        XCTAssertEqual(library.stickers(in: animals.id).map(\.id), [sticker.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: sticker).path))
    }

    func testDeleteFolderWithContentsDeletesEverythingInside() throws {
        let animals = try store.createFolder(named: "Animals")
        let cats = try store.createFolder(named: "Cats", in: animals.id)
        let inside = try store.add(try sample(), name: "In", in: cats.id)
        let outside = try store.add(try sample(), name: "Out")
        try store.deleteFolder(animals.id, keepingContents: false)
        let library = try store.library()
        XCTAssertEqual(library.folders, [])
        XCTAssertEqual(library.stickers.map(\.id), [outside.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: inside).path))
    }

    func testMoveStickers() throws {
        let cats = try store.createFolder(named: "Cats")
        let a = try store.add(try sample(), name: "A")
        let b = try store.add(try sample(), name: "B")
        try store.move([a.id], to: cats.id)
        XCTAssertEqual(try store.library().stickers(in: cats.id).map(\.id), [a.id])
        XCTAssertEqual(try store.library().stickers(in: nil).map(\.id), [b.id])
        XCTAssertEqual(try store.stickers().map(\.id), [b.id, a.id], "moving keeps the overall order")
        XCTAssertThrowsError(try store.move([b.id], to: UUID()))
        try store.move([a.id], to: nil)
        XCTAssertEqual(try store.library().stickers(in: nil).count, 2)
    }

    // MARK: Manifest

    func testVersion1ManifestLoadsAndIsUpgradedOnWrite() throws {
        let a = try store.add(try sample(), name: "A")
        let legacy = """
        {"version":1,"stickers":[{"id":"\(a.id.uuidString)","name":"Old","createdAt":"2026-10-01T10:00:00Z",
        "pixelWidth":40,"pixelHeight":30,"byteCount":100,"format":"png"}]}
        """
        try Data(legacy.utf8).write(to: manifestURL)
        XCTAssertEqual(try store.library(), StickerLibrary(stickers: try store.stickers(), folders: []))
        XCTAssertNil(try store.stickers().first?.folderID)
        _ = try store.createFolder(named: "New")
        XCTAssertEqual(try manifestJSON()["version"] as? Int, 2)
        XCTAssertEqual(try store.stickers().map(\.name), ["Old"])
    }

    func testBadFolderDataNeverCostsTheStickers() throws {
        let a = try store.add(try sample(), name: "A")
        let b = try store.add(try sample(), name: "B")
        let good = UUID()
        let json = """
        {"version":2,"folders":[{"id":"\(good.uuidString)","name":"Good","parentID":"not a uuid"},{"id":42},"junk"],
        "stickers":[
        {"id":"\(a.id.uuidString)","name":"A","createdAt":"2026-10-01T10:00:00Z","pixelWidth":40,"pixelHeight":30,"byteCount":1,"folderID":"\(good.uuidString)"},
        {"id":"\(b.id.uuidString)","name":"B","createdAt":"2026-10-01T10:00:00Z","pixelWidth":40,"pixelHeight":30,"byteCount":1,"folderID":7}]}
        """
        try Data(json.utf8).write(to: manifestURL)
        let library = try store.library()
        XCTAssertEqual(library.stickers.map(\.name), ["A", "B"], "names survive")
        XCTAssertEqual(library.folders.map(\.name), ["Good"])
        XCTAssertNil(library.folders[0].parentID, "a bad parent goes to the top level")
        XCTAssertEqual(library.stickers[0].folderID, good)
        XCTAssertNil(library.stickers[1].folderID, "a bad folder ID goes to the top level")
    }

    func testNormalizationRepairsCyclesOrphansAndDuplicates() throws {
        let a = try store.add(try sample(), name: "A")
        let (x, y, z, orphan) = (UUID(), UUID(), UUID(), UUID())
        func sticker(_ folder: UUID?) -> String {
            #"{"id":"\#(a.id.uuidString)","name":"A","createdAt":"2026-10-01T10:00:00Z","pixelWidth":40,"pixelHeight":30,"byteCount":1"#
                + (folder.map { #","folderID":"\#($0.uuidString)""# } ?? "") + "}"
        }
        let json = """
        {"version":2,"folders":[
        {"id":"\(x.uuidString)","name":"X","parentID":"\(y.uuidString)"},
        {"id":"\(y.uuidString)","name":"Y","parentID":"\(x.uuidString)"},
        {"id":"\(z.uuidString)","name":"Z","parentID":"\(UUID().uuidString)"},
        {"id":"\(z.uuidString)","name":"Z duplicate"}],
        "stickers":[\(sticker(orphan)),\(sticker(x))]}
        """
        try Data(json.utf8).write(to: manifestURL)
        let library = try store.library()
        XCTAssertEqual(library.folders.map(\.name), ["X", "Y", "Z"])
        XCTAssertNil(library.folder(x)?.parentID, "the cycle is broken at the first folder")
        XCTAssertEqual(library.folder(y)?.parentID, x)
        XCTAssertNil(library.folder(z)?.parentID)
        XCTAssertEqual(library.stickers.count, 1, "the duplicate sticker entry is dropped, the first kept")
        XCTAssertNil(library.stickers[0].folderID, "its folder doesn't exist")
        // A folder below a cycle it isn't part of keeps its parent.
        let (p, q, r) = (UUID(), UUID(), UUID())
        let below = """
        {"version":2,"folders":[
        {"id":"\(p.uuidString)","name":"P","parentID":"\(q.uuidString)"},
        {"id":"\(q.uuidString)","name":"Q","parentID":"\(r.uuidString)"},
        {"id":"\(r.uuidString)","name":"R","parentID":"\(q.uuidString)"}],
        "stickers":[]}
        """
        try Data(below.utf8).write(to: manifestURL)
        let repaired = try store.library()
        XCTAssertEqual(repaired.folder(p)?.parentID, q)
        XCTAssertNil(repaired.folder(q)?.parentID)
        XCTAssertEqual(repaired.folder(r)?.parentID, q)
        try Data(json.utf8).write(to: manifestURL)
        // Writing persists the repair.
        try store.rename(a.id, to: "A2")
        let folders = try XCTUnwrap(try manifestJSON()["folders"] as? [[String: Any]])
        XCTAssertEqual(folders.count, 3)
    }

    func testManifestFromNewerVersionIsNotRewritten() throws {
        let a = try store.add(try sample(), name: "A")
        var json = try manifestJSON()
        json["version"] = 3
        json["tags"] = ["from the future"]
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        XCTAssertEqual(try store.stickers().map(\.id), [a.id], "it can still be read")
        XCTAssertThrowsError(try store.rename(a.id, to: "B")) { XCTAssertEqual($0 as? StickerStoreError, .manifestFromNewerVersion) }
        XCTAssertNotNil(try manifestJSON()["tags"])
    }

    func testNewerManifestThisBuildCantFullyReadIsNeverRepaired() throws {
        let a = try store.add(try sample(), name: "Rex")
        let folder = UUID()
        let json = """
        {"version":3,"folders":[{"id":"\(folder.uuidString)","name":"Dogs"}],"stickers":[
        {"id":"\(a.id.uuidString)","name":"Rex","emoji":"🐶","createdAt":"2026-10-01T10:00:00Z","pixelWidth":40,"pixelHeight":30,"byteCount":1,"format":"png","folderID":"\(folder.uuidString)"},
        {"id":"\(UUID().uuidString)","name":"Wag","createdAt":"2026-10-01T10:00:00Z","pixelWidth":40,"pixelHeight":30,"byteCount":1,"format":"webp"}]}
        """
        try Data(json.utf8).write(to: manifestURL)
        // Readers get what this build understands, names and folders included.
        let library = try store.library()
        XCTAssertEqual(library.stickers.map(\.name), ["Rex"])
        XCTAssertEqual(library.stickers.first?.folderID, folder)
        XCTAssertEqual(library.folders.map(\.name), ["Dogs"])
        // Writers refuse, and leave the file exactly as it was, with no backup and no rebuild.
        XCTAssertThrowsError(try store.createFolder(named: "Cats")) { XCTAssertEqual($0 as? StickerStoreError, .manifestFromNewerVersion) }
        XCTAssertThrowsError(try store.rename(a.id, to: "B")) { XCTAssertEqual($0 as? StickerStoreError, .manifestFromNewerVersion) }
        XCTAssertEqual(try Data(contentsOf: manifestURL), Data(json.utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("manifest.corrupt-") })
    }

    func testStickersWithoutFolderAreWrittenWithoutTheKey() throws {
        _ = try store.add(try sample(), name: "A")
        let stickers = try XCTUnwrap(try manifestJSON()["stickers"] as? [[String: Any]])
        XCTAssertNil(stickers[0]["folderID"])
    }

    // MARK: Names

    func testFolderNameCleaning() {
        XCTAssertEqual(FolderName.clean("  Cats \n\t and   dogs  "), "Cats and dogs")
        XCTAssertEqual(FolderName.clean("evil\u{202E}gpj.exe"), "evilgpj.exe", "direction overrides are removed")
        XCTAssertEqual(FolderName.clean("Cafe\u{301}"), "Café", "stored precomposed")
        XCTAssertEqual(FolderName.clean("👨‍👩‍👧 family"), "👨‍👩‍👧 family", "emoji joiners stay")
        XCTAssertEqual(FolderName.clean(String(repeating: "x", count: 200)).count, FolderName.maxLength)
        let stacked = String(repeating: "a" + String(repeating: "\u{301}", count: 50), count: 20)
        XCTAssertLessThanOrEqual(FolderName.clean(stacked).unicodeScalars.count, 400, "combining marks can't bloat a name")
        XCTAssertEqual(FolderName.clean(FolderName.clean(" a  b ")), FolderName.clean(" a  b "))
        XCTAssertEqual(FolderName.cleanOrDefault("\u{202E} "), "Folder")
    }

    func testFolderNameKeyIgnoresCaseAndWidthNotAccents() {
        XCTAssertEqual(FolderName.key("Cats"), FolderName.key("ＣＡＴＳ"))
        XCTAssertEqual(FolderName.key("ｶﾜｲｲ"), FolderName.key("カワイイ"))
        XCTAssertNotEqual(FolderName.key("Bär"), FolderName.key("Bar"))
        XCTAssertNotEqual(FolderName.key("はか"), FolderName.key("ばか"))
        XCTAssertEqual(FolderName.key("Cafe\u{301}"), FolderName.key("Café"))
    }

    func testUniqueNameFitsAndEndsForNamesAtTheScalarLimit() throws {
        // 57 family emoji are 399 scalars: a plain " 2" would be cut off again, and the numbering never end.
        let family = FolderName.clean(String(repeating: "👨‍👩‍👧‍👦", count: 60))
        let twin = FolderName.unique(family, among: [family])
        XCTAssertNotEqual(FolderName.key(twin), FolderName.key(family))
        XCTAssertEqual(FolderName.clean(twin), twin, "the numbered name survives cleaning")
        XCTAssertTrue(twin.hasSuffix(" 2"))
        _ = try store.createFolder(named: family)
        XCTAssertNotEqual(try store.createFolder(named: family).name, family)
        // One character carrying 399 marks: nothing of it fits beside the number, so the fallback name is numbered.
        let zalgo = FolderName.clean("Z" + String(repeating: "\u{336}", count: 398))
        XCTAssertEqual(FolderName.unique(zalgo, among: [zalgo]), "Folder 2")
    }

    func testUniqueNameKeepsWithinTheLengthLimit() {
        let long = String(repeating: "y", count: FolderName.maxLength)
        let unique = FolderName.unique(long, among: [long])
        XCTAssertEqual(unique.count, FolderName.maxLength)
        XCTAssertTrue(unique.hasSuffix(" 2"))
        XCTAssertEqual(FolderName.unique("A", among: ["B"]), "A")
    }

    // MARK: Library

    func testChildrenAreSortedLikeFinder() {
        let names = ["Folder 10", "folder 2", "Zebra", "Émotions", "⭐ Favorites", "1 Pinned"]
        let library = StickerLibrary(folders: names.map { StickerFolder(name: $0) })
        XCTAssertEqual(library.children(of: nil).map(\.name), ["⭐ Favorites", "1 Pinned", "Émotions", "folder 2", "Folder 10", "Zebra"])
    }

    func testTreeQueries() {
        let animals = StickerFolder(name: "Animals")
        let cats = StickerFolder(name: "Cats", parentID: animals.id)
        let other = StickerFolder(name: "Other")
        let s1 = Sticker(name: "top", pixelWidth: 1, pixelHeight: 1, byteCount: 1)
        let s2 = Sticker(name: "cat", pixelWidth: 1, pixelHeight: 1, byteCount: 1, folderID: cats.id)
        let s3 = Sticker(name: "animal", pixelWidth: 1, pixelHeight: 1, byteCount: 1, folderID: animals.id)
        let library = StickerLibrary(stickers: [s1, s2, s3], folders: [cats, other, animals])
        XCTAssertEqual(library.stickers(inTree: animals.id).map(\.name), ["cat", "animal"])
        XCTAssertEqual(library.stickers(inTree: nil).count, 3)
        XCTAssertEqual(library.count(inTree: animals.id), 2)
        XCTAssertEqual(library.cover(of: animals.id)?.name, "cat", "the tree's first sticker in display order")
        XCTAssertNil(library.cover(of: other.id))
        XCTAssertEqual(library.outline().map { "\($0.depth)\($0.folder.name)" }, ["0Animals", "1Cats", "0Other"])
        XCTAssertEqual(library.subtree(of: animals.id), [animals.id, cats.id])
        XCTAssertEqual(library.path(to: nil), [])
    }

    func testSearch() {
        let animals = StickerFolder(name: "Animals")
        let cats = StickerFolder(name: "Cats", parentID: animals.id)
        func sticker(_ name: String, _ emoji: String? = nil, _ folder: StickerFolder? = nil) -> Sticker {
            Sticker(name: name, emoji: emoji, pixelWidth: 1, pixelHeight: 1, byteCount: 1, folderID: folder?.id)
        }
        let library = StickerLibrary(stickers: [
            sticker("Happy Cat", "😺", cats), sticker("sad dog", nil, animals), sticker("开心猫"),
            sticker("Café time"), sticker("ＯＫ"),
        ], folders: [animals, cats])
        XCTAssertEqual(library.search("cat").map(\.name), ["Happy Cat"])
        XCTAssertEqual(library.search("cats").map(\.name), ["Happy Cat"], "folder names match too")
        XCTAssertEqual(library.search("animals").map(\.name), ["Happy Cat", "sad dog"])
        XCTAssertEqual(library.search("animals sad").map(\.name), ["sad dog"], "every word has to match")
        XCTAssertEqual(library.search("😺").map(\.name), ["Happy Cat"])
        XCTAssertEqual(library.search("开心").map(\.name), ["开心猫"], "no word breaks needed")
        XCTAssertEqual(library.search("cafe").map(\.name), ["Café time"], "accents ignored")
        XCTAssertEqual(library.search("ok").map(\.name), ["ＯＫ"], "width ignored")
        XCTAssertEqual(library.search("  ").map(\.name), [])
        XCTAssertEqual(library.search("animals", in: animals.id).map(\.name), [], "the scope's own name doesn't match everything")
        XCTAssertEqual(library.search("cats", in: animals.id).map(\.name), ["Happy Cat"])
        XCTAssertEqual(library.searchFolders("cat").map(\.name), ["Cats"])
    }

    func testSuggestionsForTypedText() {
        let cats = StickerFolder(name: "Cats")
        func sticker(_ name: String, _ folder: StickerFolder? = nil) -> Sticker {
            Sticker(name: name, pixelWidth: 1, pixelHeight: 1, byteCount: 1, folderID: folder?.id)
        }
        let library = StickerLibrary(stickers: [sticker("happy cat", cats), sticker("开心"), sticker("lol"), sticker("Good morning"),
                                                sticker("แมว"), sticker("사랑"), sticker("party 😂")], folders: [cats])
        func suggested(_ text: String?, in scope: UUID? = nil) -> String? {
            library.suggestions(forTextBefore: text, in: scope).map { "\($0.word): " + $0.stickers.map(\.name).joined(separator: ",") }
        }
        XCTAssertEqual(suggested("I feel happy"), "happy: happy cat")
        XCTAssertEqual(suggested("so lol "), "lol: lol", "a space typed after the word is fine")
        XCTAssertNil(suggested("lol!"), "not after the sentence ended")
        XCTAssertNil(suggested("a"), "one letter is too short in a spaced script")
        XCTAssertNil(suggested("nothing matches"))
        XCTAssertNil(suggested(""))
        XCTAssertNil(suggested(nil))
        XCTAssertEqual(suggested("我今天好开心"), "开心: 开心", "the longest ending that matches")
        XCTAssertEqual(suggested("Cats"), "Cats: happy cat", "folder names match too")
        XCTAssertNil(suggested("lol", in: cats.id), "only in the folder shown")
        XCTAssertNil(suggested("see you at"), "“at” is inside “Cats” but doesn't start a word, and is too short")
        XCTAssertNil(suggested("I'm going in"))
        XCTAssertEqual(suggested("good mor"), "mor: Good morning", "three letters that start a word")
        XCTAssertEqual(suggested("ฉันรักแมว"), "แมว: แมว", "Thai is written without spaces")
        XCTAssertEqual(suggested("我好开心happy"), "happy: happy cat", "the last run of one kind of writing")
        XCTAssertEqual(suggested("so funny 😂"), "😂: party 😂")
        XCTAssertEqual(suggested("너무 사랑"), "사랑: 사랑", "two letters are enough in Korean")
        XCTAssertEqual(StickerLibrary.typedWord(in: "lol😂"), "😂")
        XCTAssertNil(StickerLibrary.typedWord(in: "done."))
        XCTAssertEqual(suggested("😂😂"), "😂: party 😂", "a run of emoji also tries the last one")
    }

    func testOneCharacterMatchesOnlyWhenThatIsAllThatWasTyped() {
        func sticker(_ name: String) -> Sticker { Sticker(name: name, pixelWidth: 1, pixelHeight: 1, byteCount: 1) }
        let library = StickerLibrary(stickers: [sticker("気分最高"), sticker("おめでとう"), sticker("猫"), sticker("日々")])
        func suggested(_ text: String) -> String? {
            library.suggestions(forTextBefore: text).map { "\($0.word): " + $0.stickers.map(\.name).joined(separator: ",") }
        }
        XCTAssertNil(suggested("あと10分"), "“分” was cut out of a longer run")
        XCTAssertNil(suggested("LINEで"))
        XCTAssertEqual(suggested("猫"), "猫: 猫")
        XCTAssertEqual(suggested("楽しい日々"), "日々: 日々", "々 is written like the kanji it repeats")
        XCTAssertNil(suggested("嗯，猫"), "after punctuation isn't all that was typed")
        XCTAssertEqual(suggested("おめでとう～"), "おめでとう: おめでとう", "“～” separates words; it isn't an emoji")
        XCTAssertNil(suggested("^^"))
        XCTAssertEqual(suggested("気分♪♪"), "気分: 気分最高", "the word before the ♪, not the ♪")
    }
}
