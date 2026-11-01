import StickerizeKit
import XCTest

final class ImportFoldersTests: XCTestCase {
    private func paths(_ root: String?, _ entries: [String], complete: Bool = true) -> [String] {
        ImportFolders.paths(rootName: root, entries: entries, complete: complete).map { $0.joined(separator: " › ") }
    }

    func testLooseImagesGoIntoAFolderNamedAfterTheArchive() {
        XCTAssertEqual(paths("Funny_Cats.zip", ["a.png", "b.png"]), ["Funny Cats", "Funny Cats"])
        XCTAssertEqual(paths("Cats.ZIP", ["a.png"]), ["Cats"])
    }

    func testAZippedFolderIsNamedAfterTheFolder() {
        // Finder's Compress: one top folder (its __MACOSX copies are left out by ImageFinder).
        XCTAssertEqual(paths("Cats.zip", ["Cats/a.png", "Cats/b.png"]), ["Cats", "Cats"])
        XCTAssertEqual(paths("download (3).zip", ["Cute Cats/a.png"]), ["Cute Cats"])
        // Full paths: the deepest common folder names the level.
        XCTAssertEqual(paths("Cats.zip", ["Users/aaron/Desktop/Cats/a.png", "Users/aaron/Desktop/Cats/sub/b.png"]),
                       ["Cats", "Cats › sub"])
    }

    func testSubfoldersAreKept() {
        XCTAssertEqual(paths("Pack.zip", ["Happy/a.png", "Sad/b.png", "c.png"]), ["Pack › Happy", "Pack › Sad", "Pack"])
        XCTAssertEqual(paths("Pack.zip", ["Pack/Happy/a.png", "Pack/Sad/b.png"]), ["Pack › Happy", "Pack › Sad"])
    }

    func testATopFolderNamedLikeTheArchiveIsNotRepeated() {
        // Next to other items, it's Windows naming the zip after the right-clicked one: they stay side by side.
        XCTAssertEqual(paths("Cats.zip", ["Cats/a.png", "b.png"]), ["Cats", ""])
        XCTAssertEqual(paths("cats.zip", ["CATS/a.png", "b.png"]), ["CATS", ""])
        XCTAssertEqual(paths("开心.zip", ["开心/a.gif", "狗头.gif"]), ["开心", ""])
    }

    func testGeneratedArchiveNamesMakeNoFolder() {
        for name in ["Archive.zip", "Archive 2.zip", "download.zip", "download (3).zip", "Untitled.zip",
                     "IMG_1234.zip", "8f14e45fceea167a5a36dedd4bea2543.zip", "123e4567-e89b-12d3-a456-426614174000.zip",
                     "2024.zip", nil] as [String?] {
            XCTAssertEqual(paths(name, ["a.png", "b.png"]), ["", ""], name ?? "nil")
        }
        // Windows names a zip of several files after the one that was right-clicked.
        XCTAssertEqual(paths("开心.zip", ["开心.gif", "狗头.gif"]), ["", ""])
        // A meaningful name stays, including dots that aren't the zip extension.
        XCTAssertEqual(paths("Pack v1.5.zip", ["a.png"]), ["Pack v1.5"])
    }

    func testWindowsZipOfSeveralFoldersKeepsThemSiblings() {
        // Windows names the zip after the right-clicked folder.
        XCTAssertEqual(paths("开心.zip", ["开心/a.gif", "难过/b.gif"]), ["开心", "难过"])
        XCTAssertEqual(paths("Cats.zip", ["Cats/a.png", "Dogs/b.png", "c.png"]), ["Cats", "Dogs", ""])
        XCTAssertEqual(paths("Cats.zip", ["Cats/Cats/a.png", "Cats/Dogs/b.png"]), ["Cats", "Cats › Dogs"], "a zipped folder still collapses")
        // Below dropped common folders, the same rule applies to what the level holds.
        XCTAssertEqual(paths("Cats.zip", ["Users/aaron/Downloads/Cats/a.png", "Users/aaron/Downloads/Dogs/b.png"]), ["Cats", "Dogs"])
        XCTAssertEqual(paths("Cats.zip", ["DCIM/Cats/a.png", "DCIM/Dogs/b.png"]), ["Cats", "Dogs"])
        XCTAssertEqual(paths("开心.zip", ["Users/a/Downloads/开心.gif", "Users/a/Downloads/狗头.gif"]), ["", ""])
    }

    func testGenericNamesGiveWayToTheArchiveName() {
        XCTAssertEqual(paths("Cats.zip", ["New folder/a.png", "New folder/b.png"]), ["Cats", "Cats"])
        // The archive, not the folder above the default one (here the account name).
        XCTAssertEqual(paths("Cats.zip", ["Users/aaron/Downloads/a.png", "Users/aaron/Downloads/b.png"]), ["Cats", "Cats"])
        XCTAssertEqual(paths("Cute Cats.zip", ["Archive.zip/Users/aaron/Downloads/a.png"]), ["Cute Cats"])
        XCTAssertEqual(paths("Archive.zip", ["Archive/a.png"]), [""])
        XCTAssertEqual(paths("Cute Cats.zip", ["Archive.zip/a.png", "Archive.zip/b.png"]), ["Cute Cats", "Cute Cats"],
                       "a lone inner zip with a generated name takes the outer one's")
        XCTAssertEqual(paths("Cute Cats.zip", ["Cute Cats/download.zip/a.png"]), ["Cute Cats"])
        XCTAssertEqual(paths("download.zip", ["Archive.zip/a.png"]), [""])
    }

    func testCameraFoldersAreFlattened() {
        XCTAssertEqual(paths("Phone.zip", ["DCIM/100APPLE/IMG_0001.png", "DCIM/101APPLE/IMG_0002.png"]), ["Phone", "Phone"])
        XCTAssertEqual(paths("Phone.zip", ["DCIM/202310__/a.png", "DCIM/100D3500/b.png", "c.png"]), ["Phone", "Phone", "Phone"])
        // Archives named like such folders make none either.
        XCTAssertEqual(paths("DCIM.zip", ["DCIM/100APPLE/a.png"]), [""])
        XCTAssertEqual(paths("1_50_组.zip", ["1_50_组/a.gif", "1_50_组/b.gif"]), ["", ""])
        // Eight digits are a date someone chose, not a camera folder.
        XCTAssertEqual(paths("Pack.zip", ["20231015/a.png", "x/b.png"]), ["Pack › 20231015", "Pack › x"])
    }

    func testOnlyPageShapedRangesAreFlattened() {
        XCTAssertEqual(paths("Pack.zip", ["2023-2024/a.png", "2025/b.png"]), ["Pack › 2023-2024", "Pack › 2025"])
        XCTAssertEqual(paths("Pack.zip", ["10-20/a.png", "x/b.png"]), ["Pack › 10-20", "Pack › x"])
        XCTAssertEqual(paths("Pack.zip", ["1-50/a.png", "101 150/b.png", "451_473_组/c.png", "x/d.png"]),
                       ["Pack › 1-50", "Pack › 101 150", "Pack", "Pack › x"], "only export-wechat-emoji's “…_组” pages")
        XCTAssertEqual(paths("Pack.zip", ["2011-2020/a.png", "x/b.png"]), ["Pack › 2011-2020", "Pack › x"])
    }

    func testWeChatExportPagesAreFlattened() {
        let root = "微信表情包_导出_20261030_120000"
        XCTAssertEqual(paths("export.zip", ["\(root)/1_50_组/a.gif", "\(root)/51_100_组/b.gif"]),
                       ["微信表情包 导出 20261030 120000", "微信表情包 导出 20261030 120000"])
        // Only one page: the common folder is the page, so the export folder above names the level.
        XCTAssertEqual(paths("export.zip", ["\(root)/1_50_组/a.gif"]), ["微信表情包 导出 20261030 120000"])
        XCTAssertEqual(paths("Stickers.zip", ["1_50_组/a.gif", "51_100_组/b.gif"]), ["Stickers", "Stickers"])
    }

    func testHashAndUUIDFoldersAreFlattened() {
        XCTAssertEqual(paths("Pack.zip", ["8f14e45fceea167a5a36dedd4bea2543/a.png", "Happy/b.png"]), ["Pack", "Pack › Happy"])
        XCTAssertEqual(paths("Pack.zip", ["123e4567-e89b-12d3-a456-426614174000/a.png"]), ["Pack"],
                       "a generated common folder falls back to the archive's name")
        XCTAssertEqual(paths("Pack.zip", ["2023/a.png", "images/b.png"]), ["Pack › 2023", "Pack › images"],
                       "years and plain words are names someone chose")
    }

    func testNestedArchivesFollowTheSameRule() {
        XCTAssertEqual(paths("Packs.zip", ["Cats.zip/Cats/a.png", "Dogs.zip/Dogs/b.png"]), ["Packs › Cats", "Packs › Dogs"])
        XCTAssertEqual(paths("Packs.zip", ["Cats.zip/a.png", "Dogs.zip/b.png", "c.png"]), ["Packs › Cats", "Packs › Dogs", "Packs"])
        XCTAssertEqual(paths("download (3).zip", ["Archive.zip/a.png", "x.png"]), ["", ""], "generated inner names too")
        XCTAssertEqual(paths("Outer.zip", ["Inner.zip/Cats/a.png"]), ["Cats"], "everything in one nested archive: it stands for the outer one")
        XCTAssertEqual(paths("Packs.zip", ["sub/Cats.zip/a.png", "sub/Dogs.zip/b.png"]), ["sub › Cats", "sub › Dogs"])
    }

    func testDepthIsCapped() {
        XCTAssertEqual(paths("Deep.zip", ["a/b/c/d/e/x.png", "y.png"]), ["Deep › a › b", "Deep"])
    }

    func testIncompleteImportsDontCollapse() {
        // Only Cats was reached before a limit: don't name the level after it.
        XCTAssertEqual(paths("Pack.zip", ["Cats/a.png", "Cats/b.png"], complete: false), ["Pack › Cats", "Pack › Cats"])
        XCTAssertEqual(paths("Cats.zip", ["Cats/a.png"], complete: false), ["Cats"])
    }

    func testNamesAreCleaned() {
        XCTAssertEqual(paths("Pack.zip", ["bad\u{202E}name/a.png", "ok/b.png"]), ["Pack › badname", "Pack › ok"])
    }

    func testRelativeToDestination() {
        XCTAssertEqual(ImportFolders.relative(["Cats", "Happy"], toDestinationNamed: "cats"), ["Happy"])
        XCTAssertEqual(ImportFolders.relative(["Cats"], toDestinationNamed: "Dogs"), ["Cats"])
        XCTAssertEqual(ImportFolders.relative(["Cats"], toDestinationNamed: nil), ["Cats"])
    }
}
