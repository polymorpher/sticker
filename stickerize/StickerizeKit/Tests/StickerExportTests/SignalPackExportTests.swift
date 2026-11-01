import CoreGraphics
import Foundation
import ImageIO
@testable import StickerExport
import StickerizeKit
import StickerizeTestSupport
import XCTest

/// Signal's sticker creator (Signal-Desktop sticker-creator/src/util/processImage.ts) rejects an APNG unless it is
/// square, at most 512 px, at most 300 KiB and loops forever. These tests check the files the way it does.
final class SignalPackExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("signal-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Animated stickers

    func testAnimatedStickerIsSquareAndLoopsForeverWhateverTheSource() throws {
        // Wide, and set to play only twice: both are rejected by Signal if passed through.
        let url = try writeGIF(movingSquare(width: 320, height: 200, frames: 12), name: "wide", loopCount: 2)
        let sticker = try SignalPackExport.prepare(contentsOf: url)
        XCTAssertTrue(sticker.info.animated)
        XCTAssertEqual(sticker.info.fileExtension, "apng")
        XCTAssertEqual(sticker.info.frameCount, 12)
        XCTAssertLessThanOrEqual(sticker.data.count, SignalPackExport.maxFileBytes)

        let png = try PNGFile(sticker.data)
        XCTAssertEqual(png.width, 512)
        XCTAssertEqual(png.height, 512)
        XCTAssertEqual(png.numPlays, 0, "num_plays 0 = loop forever")
        XCTAssertTrue(png.acTLBeforeIDAT, "Signal looks for acTL before the first IDAT")
        XCTAssertEqual(sticker.info.pixelWidth, 512)
        XCTAssertEqual(sticker.info.pixelHeight, 512)
        try assertSignalClientsAccept(sticker.data)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(sticker.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 12)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(alpha(first, x: 256, y: 10), 0, "padding above the wide content is transparent")
    }

    func testPhotographicAnimationKeepsAUsableSizeAndMotion() throws {
        // A 240 px, 10-frame, 10 fps pan across a photo: before palette reduction this came out at 147 px with 5 frames.
        let url = try writeGIF(photoPan(frames: 10, side: 240), name: "photo", delay: 0.1)
        let sticker = try SignalPackExport.prepare(contentsOf: url)
        XCTAssertTrue(sticker.info.animated)
        XCTAssertTrue(sticker.info.colorsReduced)
        XCTAssertTrue(sticker.info.wasReduced)
        XCTAssertEqual(sticker.info.pixelWidth, sticker.info.pixelHeight)
        XCTAssertGreaterThanOrEqual(sticker.info.pixelWidth, 192)
        XCTAssertGreaterThanOrEqual(sticker.info.frameCount, 7)
        XCTAssertLessThanOrEqual(sticker.data.count, SignalPackExport.maxFileBytes)
        let png = try PNGFile(sticker.data)
        XCTAssertEqual(png.colorType, 3, "palette PNG")
        XCTAssertEqual(png.numPlays, 0)
        XCTAssertEqual(png.duration, 1.0, accuracy: 0.05, "dropped frames' time goes to the kept ones")
        try assertSignalClientsAccept(sticker.data)
    }

    /// What each Signal client checks before showing an animated sticker:
    /// - Desktop's sticker creator (processImage.ts, apng.ts): square, 10–512 px, ≤ 300 KiB, acTL before IDAT, loops forever.
    /// - iOS (OWSImageSource.imageMetadata): ImageIO reports width, height, Depth and a ColorModel of RGB or Gray.
    /// - Android (lib/apng ApngDecoder): dispose_op 0–2, blend_op 0–1, frames inside the canvas.
    /// Plus: no eXIf chunk (Android copies pre-IDAT chunks into every frame; iOS applies EXIF orientation).
    private func assertSignalClientsAccept(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let png = try PNGFile(data)
        XCTAssertEqual(png.width, png.height, "square", file: file, line: line)
        XCTAssertTrue((10...512).contains(png.width), file: file, line: line)
        XCTAssertLessThanOrEqual(data.count, 300 * 1024, file: file, line: line)
        XCTAssertTrue(png.acTLBeforeIDAT, file: file, line: line)
        XCTAssertEqual(png.numPlays, 0, file: file, line: line)
        XCTAssertTrue(png.crcsAreValid, file: file, line: line)
        XCTAssertFalse(png.chunkTypes.contains("eXIf"), file: file, line: line)
        XCTAssertTrue(png.frameOps.allSatisfy { $0.dispose <= 2 && $0.blend <= 1 }, file: file, line: line)
        XCTAssertTrue(png.frameRects.allSatisfy { $0.maxX <= png.width && $0.maxY <= png.height }, file: file, line: line)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 1, file: file, line: line)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], file: file, line: line)
        XCTAssertNotNil(properties[kCGImagePropertyPixelWidth], file: file, line: line)
        XCTAssertNotNil(properties[kCGImagePropertyDepth], file: file, line: line)
        XCTAssertEqual(properties[kCGImagePropertyColorModel] as? String, kCGImagePropertyColorModelRGB as String, file: file, line: line)
    }

    func testAnimationThatCannotFitIsKeptAsItsMostVisibleFrame() throws {
        // Pure noise at 5 fps can't fit 300 KiB at any usable size or frame rate. It starts on an empty frame, as
        // pop-in stickers do, which must not become the still.
        let blank = ImageOps.makeRGBAContext(width: 120, height: 120)!.makeImage()!
        let frames = [blank] + (1..<60).map { noise(side: 120, seed: UInt64($0)) }
        let url = try writeGIF(frames, name: "noise", delay: 0.2)
        let sticker = try SignalPackExport.prepare(contentsOf: url)
        XCTAssertTrue(sticker.info.isStillFallback)
        XCTAssertTrue(sticker.info.wasReduced)
        XCTAssertEqual(sticker.info.fileExtension, "png")
        XCTAssertEqual(sticker.info.sourceFrameCount, 60)
        XCTAssertNil(try PNGFile(sticker.data).numPlays, "a plain PNG, not an APNG")
        let still = try decode(sticker.data)
        XCTAssertEqual(alpha(still, x: still.width / 2, y: still.height / 2), 255, "a visible frame, not the blank first one")
        XCTAssertLessThanOrEqual(try SignalPackExport.signalWebPSize(of: still), SignalPackExport.maxFileBytes)
    }

    func testTinyAnimationIsPaddedToSignalsMinimumSize() throws {
        // Signal refuses APNGs under 10 px; a 2×2 GIF scaled up 3× is only 6.
        let frames = (0..<2).map { index -> CGImage in
            let context = ImageOps.makeRGBAContext(width: 2, height: 2)!
            context.setFillColor(CGColor(srgbRed: index == 0 ? 1 : 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            return context.makeImage()!
        }
        let sticker = try SignalPackExport.prepare(contentsOf: writeGIF(frames, name: "tiny"))
        XCTAssertTrue(sticker.info.animated)
        XCTAssertEqual(sticker.info.pixelWidth, SignalAnimatedEncoder.minimumCanvas)
        try assertSignalClientsAccept(sticker.data)
    }

    func testLongAnimationKeepsEveryFrameWhenItFits() throws {
        // 64 frames at 512 px is over the app extensions' 48 MiB decode budget; here the size ladder decides.
        let url = try writeGIF(movingSquare(width: 512, height: 512, frames: 64), name: "long", delay: 0.05)
        let sticker = try SignalPackExport.prepare(contentsOf: url)
        XCTAssertEqual(sticker.info.frameCount, 64)
        XCTAssertEqual(sticker.info.pixelWidth, 512)
        XCTAssertFalse(sticker.info.wasReduced)
        try assertSignalClientsAccept(sticker.data)
    }

    func testRenderingStaysWithinItsMemoryBudget() throws {
        // Every frame is rendered at canvas size at once: a long animation starts smaller (not below its own size)
        // and then loses frames evenly, rather than rendering 200 frames at 512 px.
        let animation = AnimatedFrames(frames: movingSquare(width: 200, height: 200, frames: 200),
                                       delays: Array(repeating: 0.05, count: 200))
        let budget = 8 * 1024 * 1024
        let output = try XCTUnwrap(SignalAnimatedEncoder.encode(animation, maxSide: 512, maxBytes: SignalPackExport.maxFileBytes,
                                                                renderBudget: budget))
        XCTAssertLessThanOrEqual(output.frameCount * output.side * output.side * 4, budget)
        XCTAssertEqual(output.side, 200)
        XCTAssertGreaterThan(output.frameCount, 40)
    }

    func testHeavyAnimationGrowsBackAfterDroppingFrames() throws {
        // A 30-frame photo clip has to drop frames; the smaller file then leaves room to grow back above 160 px.
        let url = try writeGIF(photoPan(frames: 30, side: 240), name: "clip", delay: 1.0 / 15)
        let sticker = try SignalPackExport.prepare(contentsOf: url)
        XCTAssertTrue(sticker.info.animated)
        XCTAssertLessThan(sticker.info.frameCount, 30)
        XCTAssertGreaterThan(sticker.info.pixelWidth, Int(SignalAnimatedEncoder.minimumSide))
        try assertSignalClientsAccept(sticker.data)
    }

    func testPaletteAPNGKeepsTransparencyAndExactColors() throws {
        // Few colors: kept exactly. Transparent background: palette entry 0 via tRNS.
        let frames = movingSquare(width: 200, height: 200, frames: 3)
        let (data, lossless) = try PaletteAPNG.data(frames: frames, delays: [0.1, 0.1, 0.1], loopCount: 0)
        XCTAssertTrue(lossless)
        let png = try PNGFile(data)
        XCTAssertEqual(png.colorType, 3)
        XCTAssertEqual(png.chunkTypes.filter { $0 == "tRNS" }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(png.chunkTypes.firstIndex(of: "PLTE")), try XCTUnwrap(png.chunkTypes.firstIndex(of: "tRNS")))
        XCTAssertLessThan(try XCTUnwrap(png.chunkTypes.firstIndex(of: "tRNS")), try XCTUnwrap(png.chunkTypes.firstIndex(of: "IDAT")))
        XCTAssertTrue(png.crcsAreValid)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        for index in 0..<3 {
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            let original = frames[index]
            for (x, y) in [(0, 0), (199, 199), (100, 100), (Int(20 + Double(index) * 30 + 40), 100)] {
                XCTAssertEqual(rgba(decoded, x: x, y: y), rgba(original, x: x, y: y), "frame \(index) at \(x),\(y)")
            }
        }
    }

    func testPaletteAPNGReducesManyColorsAndKeepsTransparency() throws {
        // A gradient disc has far more than 255 colors: median cut, still transparent outside the disc.
        let frames = (0..<3).map { gradientDisc(side: 160, shift: $0 * 20) }
        let (data, lossless) = try PaletteAPNG.data(frames: frames, delays: [0.1, 0.1, 0.1], loopCount: 0)
        XCTAssertFalse(lossless)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil))
        XCTAssertEqual(alpha(decoded, x: 1, y: 1), 0)
        XCTAssertEqual(alpha(decoded, x: 80, y: 80), 255)
        // This gradient spreads evenly over the whole RGB cube, the worst case for 255 colors; photos cluster.
        let (expected, actual) = (pixels(frames[1]), pixels(decoded))
        var error = 0, count = 0, transparencyMismatches = 0
        for offset in stride(from: 0, to: expected.count, by: 4) {
            if (expected[offset + 3] == 0) != (actual[offset + 3] == 0) { transparencyMismatches += 1 }
            guard expected[offset + 3] == 255 else { continue }
            for channel in 0..<3 { error += abs(Int(expected[offset + channel]) - Int(actual[offset + channel])) }
            count += 3
        }
        XCTAssertEqual(transparencyMismatches, 0)
        XCTAssertLessThan(Double(error) / Double(count), 8, "mean error per channel, out of 255")
    }

    func testCRCMatchesThePNGSpec() {
        // Every PNG ends with IEND and the CRC AE 42 60 82.
        XCTAssertEqual(PNGChunks.crc32(Array("IEND".utf8)), 0xAE42_6082)
    }

    // MARK: Stills

    func testStillKeeps512PixelsWhenSignalsOwnWebPFits() throws {
        // Signal redraws a still at 512 px as WebP and checks only that, so a photo isn't shrunk to fit a PNG limit
        // (this PNG is about 400 KB; Signal's WebP of it is a tenth of that).
        let sticker = try SignalPackExport.prepare(contentsOf: samplePhoto)
        XCTAssertFalse(sticker.info.animated)
        XCTAssertFalse(sticker.info.wasReduced)
        XCTAssertEqual(sticker.info.fileExtension, "png")
        XCTAssertEqual(max(sticker.info.pixelWidth, sticker.info.pixelHeight), SignalPackExport.pixelDimension)
        let png = try PNGFile(sticker.data)
        XCTAssertNil(png.numPlays)
        XCTAssertFalse(png.chunkTypes.contains("eXIf"))
        XCTAssertTrue(png.crcsAreValid)
        XCTAssertLessThanOrEqual(try SignalPackExport.signalWebPSize(of: decode(sticker.data)), SignalPackExport.maxFileBytes)
    }

    func testStillTooDetailedForSignalsWebPIsShrunkAndReported() throws {
        // Noisy color and noisy alpha: Signal's WebP of this at 512 px would be over 300 KiB.
        let url = try writePNG(noisyAlpha(side: 512), name: "static")
        let sticker = try SignalPackExport.prepare(contentsOf: url)
        XCTAssertTrue(sticker.info.shrunk)
        XCTAssertTrue(sticker.info.wasReduced)
        XCTAssertLessThan(sticker.info.pixelWidth, 512)
        XCTAssertLessThanOrEqual(try SignalPackExport.signalWebPSize(of: decode(sticker.data)), SignalPackExport.maxFileBytes)
    }

    // MARK: Packs on disk

    func testWritePacksSplitsIntoPacksAndNeverTouchesTheInput() throws {
        let input = try folder("in")
        for index in 1...5 { _ = try writePNG(noise(side: 64, seed: UInt64(index)), name: "s\(index)", in: input) }
        let before = try snapshot(input)
        let output = root.appendingPathComponent("out", isDirectory: true)

        let report = try SignalPackExport.writePacks(from: input, to: output, maxPerPack: 2)
        XCTAssertEqual(report.packs.map(\.stickers.count), [2, 2, 1])
        XCTAssertEqual(report.packs.map(\.directory.lastPathComponent), ["pack-01", "pack-02", "pack-03"])
        XCTAssertEqual(report.skipped, [])
        for pack in report.packs {
            let files = try FileManager.default.contentsOfDirectory(atPath: pack.directory.path).sorted()
            XCTAssertEqual(files, pack.stickers.map(\.fileURL.lastPathComponent).sorted())
            for sticker in pack.stickers { XCTAssertTrue(FileManager.default.fileExists(atPath: sticker.fileURL.path)) }
        }
        XCTAssertEqual(try snapshot(input), before, "input folder unchanged")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(), ["pack-01", "pack-02", "pack-03"],
                       "no staging folder left behind")
    }

    func testRerunStopsUnlessReplacingAndThenLeavesNoStaleFiles() throws {
        let first = try folder("first")
        for name in ["a", "b", "c"] { _ = try writePNG(noise(side: 64, seed: 7), name: name, in: first) }
        let output = root.appendingPathComponent("out", isDirectory: true)
        try SignalPackExport.writePacks(from: first, to: output, maxPerPack: 2)
        try Data("keep me".utf8).write(to: output.appendingPathComponent("notes.txt"))

        let second = try folder("second")
        _ = try writePNG(noise(side: 64, seed: 8), name: "x", in: second)
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: second, to: output)) { error in
            XCTAssertEqual(error as? SignalPackError, .outputHasPacks(["pack-01", "pack-02"]))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("pack-01").path).count, 2,
                       "a refused run changes nothing")

        let report = try SignalPackExport.writePacks(from: second, to: output, replacingExisting: true)
        XCTAssertEqual(report.packs.map(\.stickers.count), [1])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(), ["notes.txt", "pack-01"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("pack-01").path), ["001-x.png"])
    }

    func testAFailedRunKeepsTheOldPacksEvenWhenReplacing() throws {
        let good = try folder("good")
        _ = try writePNG(noise(side: 64, seed: 1), name: "a", in: good)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try SignalPackExport.writePacks(from: good, to: output)

        let broken = try folder("broken")
        try Data("not an image".utf8).write(to: broken.appendingPathComponent("bad.png"))
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: broken, to: output, replacingExisting: true)) { error in
            guard case let .nothingConverted(skipped) = error as? SignalPackError else { return XCTFail("\(error)") }
            XCTAssertEqual(skipped.map(\.name), ["bad.png"])
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("pack-01").path), ["001-a.png"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["pack-01"])
    }

    func testReplaceTouchesOnlyPacksThisToolMade() throws {
        let first = try folder("first")
        for name in ["a", "b"] { _ = try writePNG(noise(side: 64, seed: 7), name: name, in: first) }
        let output = root.appendingPathComponent("out", isDirectory: true)
        try SignalPackExport.writePacks(from: first, to: output)
        // The user's own things that happen to be named like packs.
        let mine = try folder("out/pack-2024")
        try Data("mine".utf8).write(to: mine.appendingPathComponent("notes.txt"))
        try Data("mine".utf8).write(to: output.appendingPathComponent("pack-99"))

        let second = try folder("second")
        _ = try writePNG(noise(side: 64, seed: 8), name: "x", in: second)
        let report = try SignalPackExport.writePacks(from: second, to: output, replacingExisting: true)
        XCTAssertEqual(report.packs.map(\.stickers.count), [1])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(), ["pack-01", "pack-2024", "pack-99"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mine.path), ["notes.txt"])
    }

    func testUsersOwnFolderWhereAPackGoesStopsTheRun() throws {
        let output = try folder("out")
        let mine = try folder("out/pack-01")
        try Data("mine".utf8).write(to: mine.appendingPathComponent("notes.txt"))
        let input = try folder("in")
        _ = try writePNG(noise(side: 64, seed: 1), name: "a", in: input)
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: input, to: output, replacingExisting: true)) {
            XCTAssertEqual($0 as? SignalPackError, .outputHasOtherItems(["pack-01"]))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["pack-01"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mine.path), ["notes.txt"])
    }

    func testSymlinkedInputAndOutputFoldersWork() throws {
        let input = try folder("real-in")
        _ = try writePNG(noise(side: 64, seed: 1), name: "a", in: input)
        let output = try folder("real-out")
        let inputLink = root.appendingPathComponent("in-link"), outputLink = root.appendingPathComponent("out-link")
        try FileManager.default.createSymbolicLink(at: inputLink, withDestinationURL: input)
        try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: output)
        XCTAssertEqual(try SignalPackExport.writePacks(from: inputLink, to: outputLink).packs.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["pack-01"])
    }

    func testRefusesOutputInsideInputAndInputInsideAPackFolder() throws {
        let input = try folder("in")
        _ = try writePNG(noise(side: 64, seed: 1), name: "a", in: input)

        // Output inside the input, spelled directly and through a symlink.
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: input, to: input)) {
            XCTAssertEqual($0 as? SignalPackError, .outputInsideInput)
        }
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: input, to: input.appendingPathComponent("packs"))) {
            XCTAssertEqual($0 as? SignalPackError, .outputInsideInput)
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: input, to: link.appendingPathComponent("out"))) {
            XCTAssertEqual($0 as? SignalPackError, .outputInsideInput)
        }
        // `..` after a symlink into the input, on a folder that doesn't exist yet: the kernel resolves it physically.
        let sub = try folder("in/sub")
        let intoInput = root.appendingPathComponent("into-input")
        try FileManager.default.createSymbolicLink(at: intoInput, withDestinationURL: sub)
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: input, to: URL(fileURLWithPath: intoInput.path + "/../new-out"))) {
            XCTAssertEqual($0 as? SignalPackError, .outputInsideInput)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.appendingPathComponent("new-out").path))

        // Input that is (or is inside) a pack folder of the output: this run would write into it or replace it.
        let output = try folder("out")
        let packInput = try folder("out/pack-01")
        _ = try writePNG(noise(side: 64, seed: 2), name: "b", in: packInput)
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: packInput, to: output, replacingExisting: true)) {
            XCTAssertEqual($0 as? SignalPackError, .inputInsidePackFolder("pack-01"))
        }
        let nested = try folder("out/PACK-02/favorites")
        _ = try writePNG(noise(side: 64, seed: 3), name: "c", in: nested)
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: nested, to: output, replacingExisting: true)) {
            XCTAssertEqual($0 as? SignalPackError, .inputInsidePackFolder("PACK-02"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: packInput.path), ["b.png"], "nothing written into the input")

        // An input that merely sits inside the output folder is fine. The user's own pack-01 (it holds b.png, not this
        // tool's files) is in the way of the new pack, though, so that stops the run untouched.
        let sibling = try folder("out/wechat")
        _ = try writePNG(noise(side: 64, seed: 4), name: "d", in: sibling)
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: sibling, to: output, replacingExisting: true)) {
            XCTAssertEqual($0 as? SignalPackError, .outputHasOtherItems(["pack-01"]))
        }
        try FileManager.default.removeItem(at: output.appendingPathComponent("pack-01"))
        try FileManager.default.removeItem(at: output.appendingPathComponent("PACK-02"))
        XCTAssertEqual(try SignalPackExport.writePacks(from: sibling, to: output).packs.count, 1)
    }

    /// export-wechat-emoji's default layout: folders of 50, files named by MD5 or number (some without an extension),
    /// and an info folder of text files.
    func testFindsStickersInSubfoldersLikeAWeChatExport() throws {
        let input = try folder("微信表情包_导出_20261030_120000")
        let png = try StickerEncoder.pngData(noise(side: 64, seed: 1))
        let gif = try AnimatedStickerEncoder.gifData(frames: movingSquare(width: 80, height: 80, frames: 4),
                                                     delays: Array(repeating: 0.1, count: 4), loopCount: 0)
        try FileManager.default.createDirectory(at: input.appendingPathComponent("51_100_组"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input.appendingPathComponent("1_50_组"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input.appendingPathComponent("导出信息"), withIntermediateDirectories: true)
        try png.write(to: input.appendingPathComponent("1_50_组/3f2a9c0d8e7b6a5f4e3d2c1b0a9f8e7d.png"))
        try gif.write(to: input.appendingPathComponent("1_50_组/开心.gif"))
        try png.write(to: input.appendingPathComponent("51_100_组/000051")) // no extension
        try png.write(to: input.appendingPathComponent("51_100_组/.hidden.png"))
        try Data("https://…".utf8).write(to: input.appendingPathComponent("导出信息/emoticon_urls.txt"))

        let report = try SignalPackExport.writePacks(from: input, to: root.appendingPathComponent("out"))
        XCTAssertEqual(report.packs.flatMap(\.stickers).map(\.fileURL.lastPathComponent),
                       ["001-3f2a9c0d8e7b6a5f4e3d2c1b0a9f8e7d.png", "002-开心.apng", "003-000051.png"])
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(report.otherFiles, 1)
    }

    /// The same collection zipped on Chinese Windows: GBK names without a UTF-8 flag, plus a ZIP archive inside.
    func testWritesPacksFromAZipArchiveWithLegacyNamesAndNestedArchives() throws {
        let png = try StickerEncoder.pngData(noise(side: 64, seed: 2))
        let inner = try TestZip([TestZip.Entry(rawName: TestZip.bytes("狗头.png", .GB_18030_2000), png)]).data()
        var encrypted = TestZip.Entry("locked.png", png)
        encrypted.flags = 0x0001
        let zip = TestZip([
            TestZip.Entry(rawName: TestZip.bytes("表情包/1_50_组/开心.png", .GB_18030_2000), png),
            TestZip.Entry(rawName: TestZip.bytes("表情包/更多.zip", .GB_18030_2000), inner, deflate: false),
            TestZip.Entry(rawName: TestZip.bytes("表情包/说明.txt", .GB_18030_2000), Data("hi".utf8)),
            encrypted,
        ])
        let archive = try zip.write(to: root.appendingPathComponent("stickers.zip"))
        let before = try Data(contentsOf: archive)
        let report = try SignalPackExport.writePacks(from: archive, to: root.appendingPathComponent("out"))
        XCTAssertEqual(report.packs.flatMap(\.stickers).map(\.fileURL.lastPathComponent), ["001-开心.png", "002-狗头.png"])
        XCTAssertEqual(report.packs.flatMap(\.stickers).map(\.info.sourceName), ["开心", "狗头"])
        XCTAssertEqual(report.skipped.map(\.name), ["locked.png"])
        XCTAssertEqual(report.otherFiles, 1)
        XCTAssertEqual(try Data(contentsOf: archive), before, "the archive is only read")
    }

    /// Password-protected sticker ZIPs are common; saying "no images found" would send the user looking elsewhere.
    func testPasswordProtectedArchiveSaysSoAndListsTheFiles() throws {
        let png = try StickerEncoder.pngData(noise(side: 64, seed: 3))
        var first = TestZip.Entry("a.png", png)
        first.flags = 0x0001
        var second = TestZip.Entry("dir/sub/b.png", png)
        second.flags = 0x0001
        let archive = try TestZip([first, second]).write(to: root.appendingPathComponent("locked.zip"))
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: archive, to: root.appendingPathComponent("out"))) { error in
            guard case let .nothingConverted(skipped) = error as? SignalPackError else { return XCTFail("\(error)") }
            XCTAssertEqual(skipped.map(\.name), ["a.png", "dir/sub/b.png"], "named by their path in the input")
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("password-protected") == true)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out").path), [],
                       "nothing written, nothing left unpacked")
    }

    /// Staging (with the images unpacked from archives) lives in the system's temporary items, outside the output: it
    /// must be gone after a run, whether it succeeds, converts nothing or is cancelled.
    func testRunsLeaveNoStagingBehind() throws {
        let png = try StickerEncoder.pngData(noise(side: 64, seed: 4))
        let zip = try TestZip([TestZip.Entry("dir/sub/good.png", png), TestZip.Entry("dir/sub/bad.png", Data("no".utf8))])
            .write(to: root.appendingPathComponent("in.zip"))
        var stagings: [URL] = []
        let report = try run(zip, to: root.appendingPathComponent("out")) { stagings.append($0) }
        XCTAssertEqual(report.skipped.map(\.name), ["dir/sub/bad.png"], "named by their path in the input")
        let broken = try TestZip([TestZip.Entry("bad.png", Data("no".utf8))]).write(to: root.appendingPathComponent("bad.zip"))
        XCTAssertThrowsError(try run(broken, to: root.appendingPathComponent("out2")) { stagings.append($0) })
        // Cancelled as soon as it has a staging folder: it stops at its first check.
        let state = SignalPackExport.RunState()
        XCTAssertThrowsError(try run(zip, to: root.appendingPathComponent("out3"), state: state) {
            stagings.append($0)
            XCTAssertFalse(state.cancel())
        }) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out3").path), [])
        XCTAssertEqual(stagings.count, 3)
        for staging in stagings { XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), staging.path) }
    }

    #if os(macOS) // Process: the app scheme builds these tests for iOS too.
    /// A run killed outright (or crashed) can't clean up; the next run removes what it left, and only that.
    func testStagingLeftByAKilledRunIsRemovedByTheNext() throws {
        let png = try StickerEncoder.pngData(noise(side: 64, seed: 6))
        let zip = try TestZip([TestZip.Entry("a.png", png)]).write(to: root.appendingPathComponent("in.zip"))
        var parent: URL!
        try run(zip, to: root.appendingPathComponent("out")) { parent = $0.deletingLastPathComponent() }
        // A process that has ended, and this one.
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let stale = parent.appendingPathComponent("stale-\(UUID().uuidString)", isDirectory: true)
        let alive = parent.appendingPathComponent("alive-\(UUID().uuidString)", isDirectory: true)
        let unmarked = parent.appendingPathComponent("other-\(UUID().uuidString)", isDirectory: true)
        for (folder, pid) in [(stale, ended.processIdentifier), (alive, getpid()), (unmarked, nil)] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("unpacked"), withIntermediateDirectories: true)
            if let pid { try Data(String(pid).utf8).write(to: folder.appendingPathComponent(".signal-pack-run")) }
        }
        defer { for folder in [stale, alive, unmarked] { try? FileManager.default.removeItem(at: folder) } }
        try run(zip, to: root.appendingPathComponent("out2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "left by a process that is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alive.path), "a run still going")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarked.path), "not this tool's")
    }
    #endif

    /// A cancel while converting stops the real run at its next image and removes its staging; one after the point of no
    /// return lets it install and report, keeping the signal for afterwards.
    func testCancellingARealRun() throws {
        let png = try StickerEncoder.pngData(noise(side: 24, seed: 8))
        let input = try folder("many")
        for index in 0..<200 { try png.write(to: input.appendingPathComponent(String(format: "%03d.png", index))) }
        let state = SignalPackExport.RunState()
        var staging: URL?
        XCTAssertThrowsError(try run(input, to: root.appendingPathComponent("out"), state: state, staging: { url in
            staging = url
            // Cancel from another thread once the first pack folder exists, as a signal handler would.
            DispatchQueue.global().async {
                while !FileManager.default.fileExists(atPath: url.appendingPathComponent("pack-01").path) { usleep(1000) }
                XCTAssertFalse(state.cancel(deferring: SIGINT))
            }
        })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        state.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staging).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out").path), [])

        let installing = SignalPackExport.RunState()
        let few = try folder("few")
        for index in 0..<3 { try png.write(to: few.appendingPathComponent("\(index).png")) }
        let report = try SignalPackExport.writePacks(
            from: few, to: root.appendingPathComponent("out2"), maxPerPack: 200, replacingExisting: false,
            movingReplacedToTrash: false, limits: ImageFinder.Limits(), runState: installing,
            committed: { XCTAssertTrue(installing.cancel(deferring: SIGTERM)) })
        XCTAssertEqual(report.packs.flatMap(\.stickers).count, 3)
        XCTAssertEqual(installing.takeDeferredSignal(), SIGTERM)
    }

    /// Nothing could be unpacked within the run's limit (a large archive inside took it all).
    func testNothingUnpackedWithinTheLimitSaysSo() throws {
        let png = try StickerEncoder.pngData(noise(side: 64, seed: 7))
        let inner = TestZip([TestZip.Entry("a.png", png), TestZip.Entry("b.png", png)]).data()
        let zip = try TestZip([TestZip.Entry("inner.zip", inner, deflate: false)]).write(to: root.appendingPathComponent("in.zip"))
        var limits = ImageFinder.Limits()
        limits.maxTotalBytes = UInt64(max(inner.count, 4096))
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: zip, to: root.appendingPathComponent("out"), limits: limits)) {
            XCTAssertEqual($0 as? SignalPackError, .tooLargeToUnpack(limit: limits.maxTotalBytes, leftOut: 2, firstLeftOut: "inner.zip/a.png",
                                                                      skipped: []))
        }
        // Images unpacked within the limit that don't convert: the ones left out are still told.
        let junk = try TestZip([TestZip.Entry("a.png", Data(repeating: 9, count: 100)), TestZip.Entry("b.png", png)])
            .write(to: root.appendingPathComponent("junk.zip"))
        limits.maxTotalBytes = 4096
        XCTAssertThrowsError(try SignalPackExport.writePacks(from: junk, to: root.appendingPathComponent("out2"), limits: limits)) {
            guard case let .tooLargeToUnpack(_, leftOut, firstLeftOut, skipped) = $0 as? SignalPackError else { return XCTFail("\($0)") }
            XCTAssertEqual(leftOut, 1)
            XCTAssertEqual(firstLeftOut, "b.png")
            XCTAssertEqual(skipped.map(\.name), ["a.png"])
        }
    }

    func testTheImageLimitIsReported() throws {
        let png = try StickerEncoder.pngData(noise(side: 64, seed: 5))
        let zip = try TestZip((1...3).map { TestZip.Entry("\($0).png", png) }).write(to: root.appendingPathComponent("three.zip"))
        var limits = ImageFinder.Limits()
        limits.maxImages = 2
        let report = try SignalPackExport.writePacks(from: zip, to: root.appendingPathComponent("out"), limits: limits)
        XCTAssertTrue(report.reachedImageLimit)
        XCTAssertEqual(report.packs.flatMap(\.stickers).map(\.info.sourceName), ["1", "2"])
    }

    /// What a signal handler relies on: a cancel makes a run stop at its next check, and waiting returns once the run
    /// has ended (its cleanup done).
    func testCancellingARunWaitsForItToEnd() throws {
        let state = SignalPackExport.RunState()
        try state.begin()
        let ended = expectation(description: "run ended")
        DispatchQueue.global().async {
            while (try? state.checkCancelled()) != nil { usleep(1000) }
            usleep(50_000) // cleaning up
            state.end()
            ended.fulfill()
        }
        let started = Date()
        XCTAssertFalse(state.cancel(deferring: SIGINT), "not installing")
        state.waitUntilIdle()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.05, "waited for the cleanup")
        wait(for: [ended], timeout: 1)
        XCTAssertNil(state.takeDeferredSignal())
        XCTAssertThrowsError(try state.begin(), "no new run after a cancel") { XCTAssertTrue($0 is CancellationError) }
        // Nothing running: returns at once.
        SignalPackExport.RunState().waitUntilIdle()
    }

    /// Past the point of no return a run finishes: the cancel says so and keeps the signal for after the report.
    func testACancelWhileInstallingLetsTheRunFinish() throws {
        let state = SignalPackExport.RunState()
        try state.begin()
        try state.commit()
        XCTAssertTrue(state.cancel(deferring: SIGTERM))
        XCTAssertTrue(state.cancel(deferring: SIGINT), "the first signal is the one kept")
        state.end()
        state.waitUntilIdle()
        XCTAssertEqual(state.takeDeferredSignal(), SIGTERM)
        XCTAssertNil(state.takeDeferredSignal(), "once")
        // A run cancelled before it commits stops instead.
        let other = SignalPackExport.RunState()
        try other.begin()
        XCTAssertFalse(other.cancel())
        XCTAssertThrowsError(try other.commit()) { XCTAssertTrue($0 is CancellationError) }
    }

    // MARK: Fixtures

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(_ image: CGImage, name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent("\(name).png")
        try StickerEncoder.pngData(image).write(to: url)
        return url
    }

    private func writeGIF(_ frames: [CGImage], name: String, delay: Double = 0.1, loopCount: Int = 0) throws -> URL {
        let url = root.appendingPathComponent("\(name).gif")
        try AnimatedStickerEncoder.gifData(frames: frames, delays: Array(repeating: delay, count: frames.count),
                                           loopCount: loopCount).write(to: url)
        return url
    }

    /// `writePacks` with a run state of its own, telling `staging` where it builds the packs.
    @discardableResult
    private func run(_ input: URL, to output: URL, state: SignalPackExport.RunState = .init(),
                     staging: (URL) -> Void = { _ in }) throws -> SignalPackExport.Report {
        try SignalPackExport.writePacks(from: input, to: output, maxPerPack: SignalPackExport.stickerCount.upperBound,
                                        replacingExisting: false, movingReplacedToTrash: false, limits: ImageFinder.Limits(),
                                        runState: state, stagingCreated: staging)
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            files[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return files
    }

    /// A flat red square moving left to right on a transparent canvas (no anti-aliased edges).
    private func movingSquare(width: Int, height: Int, frames: Int) -> [CGImage] {
        (0..<frames).map { index in
            let context = ImageOps.makeRGBAContext(width: width, height: height)!
            context.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 20 + Double((index * 30) % max(1, width - 120)), y: Double(height) / 2 - 40, width: 80, height: 80))
            return context.makeImage()!
        }
    }

    private func gradientDisc(side: Int, shift: Int) -> CGImage {
        let context = ImageOps.makeRGBAContext(width: side, height: side)!
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x - side / 2), dy = Double(y - side / 2)
                guard dx * dx + dy * dy < Double(side * side) / 5 else { continue }
                let pixel = base + y * context.bytesPerRow + x * 4
                pixel[0] = UInt8((x + shift) % 256)
                pixel[1] = UInt8((y * 3 + shift) % 256)
                pixel[2] = UInt8((x + y) % 256)
                pixel[3] = 255
            }
        }
        return context.makeImage()!
    }

    /// Random color and random alpha (premultiplied), the worst case for any encoder.
    private func noisyAlpha(side: Int) -> CGImage {
        let context = ImageOps.makeRGBAContext(width: side, height: side)!
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        var state: UInt64 = 0x1234_5678
        for y in 0..<side {
            for x in 0..<side {
                let pixel = base + y * context.bytesPerRow + x * 4
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let alpha = UInt8(truncatingIfNeeded: state >> 56)
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    pixel[channel] = UInt8(UInt32(UInt8(truncatingIfNeeded: state >> 56)) * UInt32(alpha) / 255)
                }
                pixel[3] = alpha
            }
        }
        return context.makeImage()!
    }

    private func decode(_ data: Data) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil))
    }

    private func noise(side: Int, seed: UInt64) -> CGImage {
        let context = ImageOps.makeRGBAContext(width: side, height: side)!
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        for y in 0..<side {
            for x in 0..<side {
                let pixel = base + y * context.bytesPerRow + x * 4
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    pixel[channel] = UInt8(truncatingIfNeeded: state >> 56)
                }
                pixel[3] = 255
            }
        }
        return context.makeImage()!
    }

    /// Square crops panning across a sample photo, like a clip from a video.
    private func photoPan(frames: Int, side: Int) throws -> [CGImage] {
        let photo = try ImageLoader.image(contentsOf: samplePhoto, maxPixelSize: 480)
        let crop = min(photo.width, photo.height) - 60
        return (0..<frames).map { index in
            let cropped = photo.cropping(to: CGRect(x: index * 2, y: index, width: crop, height: crop))!
            return ImageOps.redraw(cropped, width: side, height: side, opaque: true)!
        }
    }

    private var samplePhoto: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // StickerExportTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // StickerizeKit
            .deletingLastPathComponent() // stickerize
            .appendingPathComponent("samples/test2.jpg")
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let context = ImageOps.makeRGBAContext(width: image.width, height: image.height)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixel = context.data!.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
        return [pixel[0], pixel[1], pixel[2], pixel[3]]
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 { rgba(image, x: x, y: y)[3] }

    /// All pixels as RGBA bytes, tightly packed, top row first.
    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = ImageOps.makeRGBAContext(width: image.width, height: image.height)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).flatMap { y in Array(UnsafeBufferPointer(start: base + y * context.bytesPerRow, count: image.width * 4)) }
    }
}

/// The parts of a PNG file Signal's sticker creator looks at.
private struct PNGFile {
    var chunkTypes: [String] = []
    var width = 0
    var height = 0
    var colorType: UInt8 = 0
    /// acTL num_plays, or nil for a still PNG.
    var numPlays: UInt32?
    var acTLBeforeIDAT = false
    var duration = 0.0
    var frameOps: [(dispose: UInt8, blend: UInt8)] = []
    /// Right and bottom edge of each frame region (fcTL x_offset + width, y_offset + height).
    var frameRects: [(maxX: Int, maxY: Int)] = []
    var crcsAreValid = true

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(uint32(offset))
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let body = offset + 8
            chunkTypes.append(type)
            if PNGChunks.crc32(Array(bytes[(offset + 4)..<(body + length)])) != uint32(body + length) { crcsAreValid = false }
            switch type {
            case "IHDR":
                width = Int(uint32(body))
                height = Int(uint32(body + 4))
                colorType = bytes[body + 9]
            case "acTL":
                numPlays = uint32(body + 4)
                acTLBeforeIDAT = !chunkTypes.contains("IDAT")
            case "fcTL":
                let numerator = Double(UInt16(bytes[body + 20]) << 8 | UInt16(bytes[body + 21]))
                let denominator = Double(UInt16(bytes[body + 22]) << 8 | UInt16(bytes[body + 23]))
                duration += numerator / (denominator == 0 ? 100 : denominator)
                frameOps.append((bytes[body + 24], bytes[body + 25]))
                frameRects.append((Int(uint32(body + 12) + uint32(body + 4)), Int(uint32(body + 16) + uint32(body + 8))))
            default: break
            }
            offset = body + length + 4
        }
    }
}
