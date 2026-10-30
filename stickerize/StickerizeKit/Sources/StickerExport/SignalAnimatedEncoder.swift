import CoreGraphics
import Foundation
import StickerizeKit

/// Animated Signal stickers. Signal's sticker creator takes an APNG only if it is square, 10–512 px, ≤ 300 KiB and loops
/// forever (Signal-Desktop sticker-creator/src/util/processImage.ts).
///
/// Content is centred on a square transparent canvas and scaled toward `maxSide` (upscaling at most
/// `StickerSpec.maxUpscale`). If the file is too big, it is reduced in the order that costs a sticker least:
/// 1. a 256-color palette (no loss at all for a GIF drawn at its own size),
/// 2. shrink, down to the source's own size or `comfortableSide`, whichever is smaller (pixels above the source's size
///    add no detail),
/// 3. drop frames down to `smoothFramesPerSecond`,
/// 4. shrink, down to `minimumSide`,
/// 5. drop frames down to `minimumFramesPerSecond`.
/// After dropping frames, the side grows back toward `comfortableSide` if the smaller file leaves room. If nothing
/// fits, `encode` returns nil and the caller keeps a still instead.
///
/// Every frame is rendered at canvas size at once, so a very long animation starts smaller, down to the comfortable
/// size, and then loses frames evenly, to keep the rendered frames within `renderBudget`.
enum SignalAnimatedEncoder {
    static let comfortableSide = 320.0
    static let minimumSide = 160.0
    static let smoothFramesPerSecond = 8.0
    static let minimumFramesPerSecond = 4.0
    /// Signal's MIN_IMAGE_SIZE: smaller APNGs are refused.
    static let minimumCanvas = 10
    static let defaultRenderBudget = 128 * 1024 * 1024

    struct Output {
        let data: Data
        /// Width and height of the square canvas.
        let side: Int
        let frameCount: Int
        /// Reduced to a 256-color palette, losing colors or soft edges (a palette that kept everything doesn't count).
        let colorsReduced: Bool
        /// Drawn smaller than the source (detail lost), to fit the byte or memory limit.
        let shrunk: Bool
    }

    static func encode(_ animation: AnimatedFrames, maxSide: Int, maxBytes: Int,
                       renderBudget: Int = defaultRenderBudget) throws -> Output? {
        guard let first = animation.frames.first else { throw StickerEncodingError.invalidImage }
        let longest = Double(animation.frames.map { max($0.width, $0.height) }.max() ?? max(first.width, first.height))
        let native = min(longest, Double(maxSide))
        let comfortable = min(comfortableSide, native)
        let minimum = min(minimumSide, comfortable)
        func affordable(_ side: Double, frames: Int) -> Bool {
            let canvas = Double(max(Int(side), minimumCanvas))
            return Double(frames) * canvas * canvas * 4 <= Double(renderBudget)
        }

        var current = animation
        var side = min(Double(maxSide), longest * StickerSpec.maxUpscale).rounded(.down)
        if !affordable(side, frames: current.frames.count) {
            let fitting = (Double(renderBudget) / (4 * Double(current.frames.count))).squareRoot().rounded(.down)
            side = max(fitting, comfortable)
            let canvas = max(Int(side), minimumCanvas)
            let frames = max(2, renderBudget / (4 * canvas * canvas))
            if current.frames.count > frames {
                current = current.keepingEvery(Int((Double(current.frames.count) / Double(frames)).rounded(.up)))
            }
        }

        var usesPalette = false
        var framesReduced = false
        func output(_ attempt: Attempt) -> Output {
            Output(data: attempt.data, side: attempt.canvas, frameCount: current.frames.count,
                   colorsReduced: usesPalette && !attempt.lossless, shrunk: attempt.contentLongest < Int(native))
        }
        while true {
            let attempt = try encodeOnce(current, side: side, longest: longest, palette: usesPalette)
            if attempt.data.count <= maxBytes {
                // Dropping frames can free much of the budget below the comfortable size: grow back into it.
                if framesReduced, side < comfortable, attempt.data.count < maxBytes * 85 / 100 {
                    let grown = min(comfortable, (side * (Double(maxBytes) / Double(attempt.data.count)).squareRoot() * 0.95).rounded(.down))
                    if grown > side + 4, affordable(grown, frames: current.frames.count) {
                        let bigger = try encodeOnce(current, side: grown, longest: longest, palette: usesPalette)
                        if bigger.data.count <= maxBytes { return output(bigger) }
                    }
                }
                return output(attempt)
            }
            if !usesPalette {
                usesPalette = true
                continue
            }
            // File size grows roughly with pixel count: aim for the side that would just fit, with a little margin,
            // while always making progress.
            let fitting = side * (Double(maxBytes) / Double(attempt.data.count)).squareRoot() * 0.95
            let smaller = min(fitting, side * 0.9).rounded(.down)
            let smooth = current.resampled(toFramesPerSecond: smoothFramesPerSecond)
            let choppy = current.resampled(toFramesPerSecond: minimumFramesPerSecond)
            if side > comfortable {
                side = max(smaller, comfortable)
            } else if smooth.frames.count >= 2, smooth.frames.count < current.frames.count {
                current = smooth
                framesReduced = true
            } else if side > minimum {
                side = max(smaller, minimum)
            } else if choppy.frames.count >= 2, choppy.frames.count < current.frames.count {
                current = choppy
                framesReduced = true
            } else {
                return nil
            }
        }
    }

    private struct Attempt {
        let data: Data
        let canvas: Int
        let contentLongest: Int
        /// Nothing lost to the palette (always true without one).
        let lossless: Bool
    }

    private static func encodeOnce(_ animation: AnimatedFrames, side: Double, longest: Double, palette: Bool) throws -> Attempt {
        let first = animation.frames[0]
        let scale = side / longest
        let contentWidth = max(1, Int((Double(first.width) * scale).rounded()))
        let contentHeight = max(1, Int((Double(first.height) * scale).rounded()))
        let canvas = max(contentWidth, contentHeight, minimumCanvas)
        let rendered = try AnimatedStickerEncoder.render(animation.frames, contentWidth: contentWidth,
                                                         contentHeight: contentHeight, canvasWidth: canvas,
                                                         canvasHeight: canvas)
        // Loop count 0 (forever) whatever the source said: Signal rejects APNGs that stop.
        let encoded: (data: Data, lossless: Bool) = palette
            ? try PaletteAPNG.data(frames: rendered, delays: animation.delays, loopCount: 0)
            : (try AnimatedStickerEncoder.apngData(frames: rendered, delays: animation.delays, loopCount: 0), true)
        // ImageIO adds an eXIf chunk (color space and size only). Signal uploads APNGs byte for byte, Android copies
        // pre-IDAT chunks into every frame it decodes and iOS applies EXIF orientation, so leave it out.
        guard let data = PNGChunks.removing("eXIf", from: encoded.data) else { throw StickerEncodingError.encodeFailed }
        return Attempt(data: data, canvas: canvas, contentLongest: max(contentWidth, contentHeight), lossless: encoded.lossless)
    }
}
