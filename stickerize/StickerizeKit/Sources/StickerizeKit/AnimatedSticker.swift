import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The frames of an animated image, upright and decoded at sticker size.
public struct AnimatedFrames: Sendable {
    public var frames: [CGImage]
    /// Seconds each frame is shown.
    public var delays: [Double]
    /// 0 loops forever.
    public var loopCount: Int

    public init(frames: [CGImage], delays: [Double], loopCount: Int = 0) {
        precondition(frames.count == delays.count, "one delay per frame")
        self.frames = frames
        self.delays = delays
        self.loopCount = loopCount
    }

    public var duration: Double { delays.reduce(0, +) }

    /// Keeps every `step`-th frame, adding the dropped frames' time to the kept ones so the timing is unchanged.
    public func keepingEvery(_ step: Int) -> AnimatedFrames {
        guard step > 1 else { return self }
        var frames: [CGImage] = []
        var delays: [Double] = []
        for start in stride(from: 0, to: self.frames.count, by: step) {
            frames.append(self.frames[start])
            delays.append(self.delays[start..<min(start + step, self.delays.count)].reduce(0, +))
        }
        return AnimatedFrames(frames: frames, delays: delays, loopCount: loopCount)
    }

    public var framesPerSecond: Double { Double(frames.count) / max(duration, 0.01) }

    /// Keeps at most one frame per 1/`target` second slot of the timeline (the first frame that starts in each slot),
    /// adding the dropped frames' time to the kept ones so the timing is unchanged. Unlike `keepingEvery(2)` this can go
    /// from 10 fps to 8 rather than to 5, and it thins a fast burst even when a long hold keeps the average rate low.
    /// Frames are dropped only where two start in the same slot.
    public func resampled(toFramesPerSecond target: Double) -> AnimatedFrames {
        guard target > 0, frames.count > 1 else { return self }
        let slot = 1 / target
        var frames: [CGImage] = []
        var delays: [Double] = []
        var time = 0.0
        var lastSlot = -1
        for (frame, delay) in zip(self.frames, self.delays) {
            let index = Int(((time + 1e-6) / slot).rounded(.down))
            if index > lastSlot {
                frames.append(frame)
                delays.append(delay)
                lastSlot = index
            } else {
                delays[delays.count - 1] += delay
            }
            time += delay
        }
        return AnimatedFrames(frames: frames, delays: delays, loopCount: loopCount)
    }
}

public enum AnimatedImageLoader {
    /// Number of frames: more than 1 for animated GIF, APNG, animated WebP and HEICS; 1 for stills (0 if unreadable).
    public static func frameCount(of data: Data) -> Int {
        CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
    }

    public static func frameCount(contentsOf url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
    }

    public static func frames(from data: Data, maxPixelSize: Int = StickerSpec.maxPixelDimension,
                              memoryBudget: Int = defaultMemoryBudget) throws -> AnimatedFrames {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ImageLoadingError.unreadable }
        return try frames(from: source, maxPixelSize: maxPixelSize, memoryBudget: memoryBudget)
    }

    public static func frames(contentsOf url: URL, maxPixelSize: Int = StickerSpec.maxPixelDimension,
                              memoryBudget: Int = defaultMemoryBudget) throws -> AnimatedFrames {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageLoadingError.unreadable }
        return try frames(from: source, maxPixelSize: maxPixelSize, memoryBudget: memoryBudget)
    }

    /// Decoded frames are kept within this many bytes (frames are sampled evenly if needed), so a long GIF can't
    /// exhaust an extension's memory.
    public static let defaultMemoryBudget = 48 * 1024 * 1024

    private static func frames(from source: CGImageSource, maxPixelSize: Int, memoryBudget: Int) throws -> AnimatedFrames {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ImageLoadingError.unreadable }
        let firstProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (firstProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? maxPixelSize
        let height = (firstProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? maxPixelSize
        let target = min(maxPixelSize, max(width, height, 1))
        let fitted = ImageOps.fittedSize(width: width, height: height, longestSide: target)
        let frameBytes = max(1, fitted.width * fitted.height * 4)
        let step = max(1, Int((Double(count * frameBytes) / Double(memoryBudget)).rounded(.up)))

        var frames: [CGImage] = []
        var delays: [Double] = []
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        for start in stride(from: 0, to: count, by: step) {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, start, options as CFDictionary) else { continue }
            frames.append(frame)
            // A sampled frame stays up for the frames it stands in for.
            delays.append((start..<min(start + step, count)).reduce(0) { $0 + delay(of: source, at: $1) })
        }
        guard !frames.isEmpty else { throw ImageLoadingError.unreadable }
        return AnimatedFrames(frames: frames, delays: delays, loopCount: loopCount(of: source))
    }

    /// Frame delay in seconds from whichever animation dictionary the format uses. Like browsers, delays under 20 ms
    /// (often written as 0) are shown for 100 ms.
    static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictionaryKey, unclamped, clamped) in keys {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            if let value = (dictionary[unclamped] as? NSNumber ?? dictionary[clamped] as? NSNumber)?.doubleValue {
                return value < 0.02 ? 0.1 : value
            }
        }
        return 0.1
    }

    static func loopCount(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let keys: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount),
        ]
        for (dictionaryKey, loopKey) in keys {
            if let dictionary = properties[dictionaryKey] as? [CFString: Any],
               let loops = (dictionary[loopKey] as? NSNumber)?.intValue {
                return loops
            }
        }
        return 0
    }
}

/// Animated stickers as GIF, under the same canvas rules as stills (`StickerCanvas`): content scaled toward the
/// longest-side limit (upscaling at most `maxUpscale`), each side padded to at least `minPixelDimension` on a
/// transparent canvas. If the GIF is over `maxBytes`, it is reduced in the order that hurts a sticker least: shrink a
/// little (to ~420 px), then drop every other frame while the animation keeps at least ~8 fps (the dropped frames'
/// time goes to the kept ones), then shrink further, then drop more frames.
public enum AnimatedStickerEncoder {
    /// Shrinking below this longest side comes after thinning frames down to `smoothFramesPerSecond`.
    static let comfortableLongestSide = 420.0
    static let smoothFramesPerSecond = 8.0

    public static func encode(_ animation: AnimatedFrames, canvas: StickerCanvas = .messages) throws -> EncodedSticker {
        guard let first = animation.frames.first else { throw StickerEncodingError.invalidImage }
        let longest = Double(animation.frames.map { max($0.width, $0.height) }.max() ?? max(first.width, first.height))
        var scale = min(Double(canvas.maxPixelDimension) / longest, canvas.maxUpscale)
        var current = animation
        let floor = min(Double(StickerSpec.minContentDimension), longest * scale)
        let comfortable = min(comfortableLongestSide, longest * scale)
        while true {
            let contentWidth = max(1, Int((Double(first.width) * scale).rounded()))
            let contentHeight = max(1, Int((Double(first.height) * scale).rounded()))
            let width = max(contentWidth, canvas.minPixelDimension)
            let height = max(contentHeight, canvas.minPixelDimension)
            let rendered = try render(current.frames, contentWidth: contentWidth, contentHeight: contentHeight,
                                      canvasWidth: width, canvasHeight: height)
            let data = try gifData(frames: rendered, delays: current.delays, loopCount: current.loopCount)
            if data.count <= canvas.maxBytes {
                return EncodedSticker(data: data, format: .gif, pixelWidth: width, pixelHeight: height)
            }
            let side = Double(max(contentWidth, contentHeight))
            let framesPerSecond = Double(current.frames.count) / max(current.duration, 0.01)
            let shrink = max(0.75, min(0.92, (Double(canvas.maxBytes) / Double(data.count)).squareRoot()))
            if side > comfortable + 1 {
                scale = max(scale * shrink, comfortable / longest)
            } else if current.frames.count > 2, framesPerSecond > smoothFramesPerSecond {
                current = current.keepingEvery(2)
            } else if side > floor + 1 {
                scale = max(scale * shrink, floor / longest)
            } else if current.frames.count > 2 {
                current = current.keepingEvery(2)
            } else {
                throw StickerEncodingError.cannotFitByteLimit(bytes: data.count, limit: canvas.maxBytes)
            }
        }
    }

    /// Writes an animated GIF (transparency kept as GIF's on/off transparency).
    public static func gifData(frames: [CGImage], delays: [Double], loopCount: Int) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw StickerEncodingError.encodeFailed
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount],
        ] as CFDictionary)
        for (frame, delay) in zip(frames, delays) {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw StickerEncodingError.encodeFailed }
        return data as Data
    }

    /// Writes an animated PNG (APNG). Signal Desktop sticker packs accept APNG, not GIF.
    public static func apngData(frames: [CGImage], delays: [Double], loopCount: Int) throws -> Data {
        guard !frames.isEmpty, frames.count == delays.count else { throw StickerEncodingError.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, frames.count, nil) else {
            throw StickerEncodingError.encodeFailed
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount],
        ] as CFDictionary)
        for (frame, delay) in zip(frames, delays) {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGDelayTime: delay,
                    kCGImagePropertyAPNGUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw StickerEncodingError.encodeFailed }
        return data as Data
    }

    /// Draws each frame scaled to `contentWidth`×`contentHeight` and centred on a transparent canvas.
    public static func render(_ frames: [CGImage], contentWidth: Int, contentHeight: Int,
                              canvasWidth: Int, canvasHeight: Int) throws -> [CGImage] {
        try frames.map { frame in
            guard let context = ImageOps.makeRGBAContext(width: canvasWidth, height: canvasHeight) else {
                throw StickerEncodingError.encodeFailed
            }
            context.interpolationQuality = .high
            context.draw(frame, in: CGRect(x: (canvasWidth - contentWidth) / 2, y: (canvasHeight - contentHeight) / 2,
                                           width: contentWidth, height: contentHeight))
            guard let image = context.makeImage() else { throw StickerEncodingError.encodeFailed }
            return image
        }
    }
}
