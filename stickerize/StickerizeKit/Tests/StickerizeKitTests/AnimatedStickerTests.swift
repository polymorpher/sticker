import CoreGraphics
import Foundation
import ImageIO
import StickerizeKit
import UniformTypeIdentifiers
import XCTest

final class AnimatedStickerTests: XCTestCase {
    /// A bouncing square on a transparent canvas: `count` frames, `delay` seconds each.
    private func bouncingSquare(count: Int, size: Int = 200, delay: Double = 0.05) -> AnimatedFrames {
        let frames = (0..<count).map { index -> CGImage in
            let offset = Double(index) / Double(max(count - 1, 1)) * Double(size / 2)
            return TestImages.square(canvas: size, rect: CGRect(x: offset, y: offset, width: Double(size / 2), height: Double(size / 2)))
        }
        return AnimatedFrames(frames: frames, delays: Array(repeating: delay, count: count))
    }

    private func gifFile(_ animation: AnimatedFrames, loopCount: Int = 0) throws -> Data {
        try AnimatedStickerEncoder.gifData(frames: animation.frames, delays: animation.delays, loopCount: loopCount)
    }

    func testRoundTripKeepsFramesTimingAndLoop() throws {
        let gif = try gifFile(bouncingSquare(count: 10, delay: 0.07), loopCount: 3)
        XCTAssertEqual(AnimatedImageLoader.frameCount(of: gif), 10)
        let decoded = try AnimatedImageLoader.frames(from: gif)
        XCTAssertEqual(decoded.frames.count, 10)
        XCTAssertEqual(decoded.loopCount, 3)
        XCTAssertEqual(decoded.duration, 0.7, accuracy: 0.05)
        XCTAssertEqual(decoded.frames[0].width, 200)
    }

    func testZeroDelaysPlayAtTenFramesPerSecond() throws {
        let gif = try gifFile(bouncingSquare(count: 4, delay: 0))
        XCTAssertEqual(try AnimatedImageLoader.frames(from: gif).delays, [0.1, 0.1, 0.1, 0.1])
    }

    func testEncodedStickerMeetsMSStickerLimitsAndStaysAnimated() throws {
        let encoded = try AnimatedStickerEncoder.encode(bouncingSquare(count: 12))
        XCTAssertEqual(encoded.format, .gif)
        XCTAssertLessThanOrEqual(encoded.data.count, StickerSpec.maxFileBytes)
        XCTAssertGreaterThanOrEqual(min(encoded.pixelWidth, encoded.pixelHeight), StickerSpec.minPixelDimension)
        XCTAssertLessThanOrEqual(max(encoded.pixelWidth, encoded.pixelHeight), StickerSpec.maxPixelDimension)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.gif.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 12)
        // The canvas is transparent outside the square.
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(TestImages.pixel(frame, x: frame.width - 3, y: 2).a, 0)
    }

    func testHeavyAnimationsDropFramesAndShrinkUntilTheyFit() throws {
        // 40 frames of noise at 618 px is many MB as GIF; it must still come in under 500 KB, keeping its duration.
        let frames = (0..<40).map { TestImages.noise(width: 618, height: 618, seed: UInt64($0 + 1)) }
        let animation = AnimatedFrames(frames: frames, delays: Array(repeating: 0.05, count: 40))
        let encoded = try AnimatedStickerEncoder.encode(animation)
        XCTAssertLessThanOrEqual(encoded.data.count, StickerSpec.maxFileBytes)
        let decoded = try AnimatedImageLoader.frames(from: encoded.data)
        XCTAssertLessThan(decoded.frames.count, 40)
        XCTAssertGreaterThanOrEqual(decoded.frames.count, 2)
        XCTAssertEqual(decoded.duration, 2.0, accuracy: 0.15)
    }

    func testLongAnimationsAreSampledWithinTheMemoryBudget() throws {
        let gif = try gifFile(bouncingSquare(count: 30, delay: 0.04))
        // A budget for ~10 frames of 200×200 RGBA.
        let decoded = try AnimatedImageLoader.frames(from: gif, memoryBudget: 10 * 200 * 200 * 4)
        XCTAssertLessThanOrEqual(decoded.frames.count, 10)
        XCTAssertEqual(decoded.duration, 1.2, accuracy: 0.05, "dropped frames' time goes to the kept ones")
    }

    func testResamplingTargetsTheRateAndKeepsTheTiming() {
        let animation = bouncingSquare(count: 10, delay: 0.1)
        let eight = animation.resampled(toFramesPerSecond: 8)
        XCTAssertEqual(eight.frames.count, 8, "10 → 8 fps, not 5 as halving would give")
        XCTAssertEqual(eight.duration, 1.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(eight.framesPerSecond, 8 + 1e-9)
        XCTAssertEqual(animation.resampled(toFramesPerSecond: 4).frames.count, 4)
        XCTAssertEqual(animation.resampled(toFramesPerSecond: 4).duration, 1.0, accuracy: 1e-9)
        XCTAssertEqual(animation.resampled(toFramesPerSecond: 12).frames.count, 10, "already slower: unchanged")
    }

    func testResamplingThinsAFastBurstBeforeALongHold() {
        // 20 frames at 20 fps, then a 2 s hold: 7 fps on average, but the burst still runs at 20.
        let burst = bouncingSquare(count: 21, delay: 0.05)
        let animation = AnimatedFrames(frames: burst.frames, delays: Array(repeating: 0.05, count: 20) + [2.0])
        let thinned = animation.resampled(toFramesPerSecond: 8)
        XCTAssertEqual(thinned.frames.count, 9)
        XCTAssertEqual(thinned.duration, 3.0, accuracy: 1e-9)
        XCTAssertEqual(thinned.delays.last ?? 0, 2.0, accuracy: 1e-9, "the held frame is kept, with its time")
    }

    func testStillImagesHaveOneFrame() {
        XCTAssertEqual(AnimatedImageLoader.frameCount(of: TestImages.encode(TestImages.halves(width: 20, height: 20), type: .png)), 1)
        XCTAssertEqual(AnimatedImageLoader.frameCount(contentsOf: Samples.url("test.jpg")), 1)
    }

    func testStoreSavesGIFStickersAndCopiesThemAsGIF() throws {
        let directory = TestImages.temporaryDirectory().appendingPathComponent("Stickers", isDirectory: true)
        let store = StickerStore(directory: directory, changeNotificationName: "ai.qokka.stickerize.tests.\(UUID().uuidString)")
        let encoded = try AnimatedStickerEncoder.encode(bouncingSquare(count: 6))
        let sticker = try store.add(encoded, name: "Bounce")
        XCTAssertTrue(sticker.isAnimated)
        XCTAssertTrue(sticker.fileName.hasSuffix(".gif"))
        XCTAssertEqual(AnimatedImageLoader.frameCount(contentsOf: store.fileURL(for: sticker)), 6)
        let pasted = try store.pasteboardItem(for: sticker)
        XCTAssertEqual(pasted.type, .gif)
        XCTAssertEqual(pasted.data, encoded.data)
        // The first frame is what grids and the WhatsApp/Telegram still fallback decode.
        XCTAssertNotNil(ImageLoader.thumbnail(contentsOf: store.fileURL(for: sticker), maxPixelSize: 100))

        // A lost manifest is rebuilt with the right formats.
        _ = try store.add(try StickerEncoder.encode(TestImages.halves(width: 400, height: 300)), name: "Still")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("manifest.json"))
        let rebuilt = try store.stickers()
        XCTAssertEqual(Set(rebuilt.map(\.format)), [.gif, .png])
    }
}
