import CoreGraphics
import Foundation
import StickerizeKit

/// Animated PNG with one shared 8-bit palette, about a quarter the size of a truecolor APNG: the same trade-off GIF
/// makes. Alpha becomes on/off at 50%, as in GIF, with palette entry 0 as the transparent color.
///
/// ImageIO writes palette PNGs (color type 3) for indexed `CGImage`s and keeps the palette order, but indexed color
/// spaces carry no alpha, so the transparency (`tRNS`) chunk is added to the encoded file afterwards.
enum PaletteAPNG {
    /// `lossless` is true when every color fit the palette and every pixel was fully opaque or fully transparent.
    static func data(frames: [CGImage], delays: [Double], loopCount: Int) throws -> (data: Data, lossless: Bool) {
        let indexed = try PaletteQuantizer.quantize(frames)
        let png = try AnimatedStickerEncoder.apngData(frames: indexed.frames, delays: delays, loopCount: loopCount)
        // tRNS lists alpha for palette entries from index 0; entries past its end stay opaque.
        guard let withAlpha = PNGChunks.inserting("tRNS", data: Data([0]), after: "PLTE", in: png) else {
            throw StickerEncodingError.encodeFailed
        }
        return (withAlpha, indexed.lossless)
    }
}

/// Reduces RGBA frames to one palette shared by every frame (APNG has a single PLTE): entry 0 is transparent, then at
/// most 255 opaque colors. If the frames use 255 colors or fewer (a GIF source drawn 1:1), they are kept exactly;
/// otherwise the palette comes from median cut over a 5-bit-per-channel histogram. No dithering: it flickers from
/// frame to frame and compresses worse.
enum PaletteQuantizer {
    static let maxOpaqueColors = 255

    /// 8-bit indexed images sharing one color space, the same sizes as `frames`, and whether nothing was lost (all
    /// colors kept exactly, no partly transparent pixels). Pixels are read one frame at a time in each pass, so memory
    /// stays at about one frame on top of `frames` and the result.
    static func quantize(_ frames: [CGImage]) throws -> (frames: [CGImage], lossless: Bool) {
        // Pass 1: count colors.
        var exact = ExactColors()
        var histogram = Histogram()
        var partialAlpha = false
        for frame in frames {
            let colors = try opaqueColors(of: frame, partialAlpha: &partialAlpha)
            colors.withUnsafeBufferPointer { buffer in
                var previous: UInt32 = 0
                for color in buffer where color != 0 {
                    histogram.add(color)
                    // Neighbouring pixels usually repeat, so skip the table for runs.
                    if color != previous, exact.isActive { exact.insert(color) }
                    previous = color
                }
            }
        }

        // Palette: entry 0 transparent, then the opaque colors.
        let palette: [UInt32]
        let lookup: (UInt32) -> UInt8
        if exact.isActive {
            palette = exact.colors
            let indices = exact.indices
            lookup = { indices[$0] ?? 0 }
        } else {
            let cut = histogram.medianCut(maxColors: maxOpaqueColors)
            palette = cut.palette
            let binToIndex = cut.binToIndex
            lookup = { binToIndex[Histogram.bin(of: $0)] }
        }
        var table: [UInt8] = [0, 0, 0]
        for color in palette {
            table += [UInt8(truncatingIfNeeded: color >> 16), UInt8(truncatingIfNeeded: color >> 8), UInt8(truncatingIfNeeded: color)]
        }
        guard let space = CGColorSpace(indexedBaseSpace: ImageOps.sRGB, last: palette.count, colorTable: table) else {
            throw StickerEncodingError.encodeFailed
        }

        // Pass 2: map pixels to palette indices.
        let indexed = try frames.map { frame in
            var ignored = false
            let colors = try opaqueColors(of: frame, partialAlpha: &ignored)
            var indices = [UInt8](repeating: 0, count: colors.count)
            colors.withUnsafeBufferPointer { source in
                indices.withUnsafeMutableBufferPointer { target in
                    var previous: UInt32 = 0
                    var previousIndex: UInt8 = 0
                    for i in 0..<source.count {
                        let color = source[i]
                        if color == 0 { continue }
                        if color != previous {
                            previous = color
                            previousIndex = lookup(color) &+ 1 // +1: entry 0 is the transparent one
                        }
                        target[i] = previousIndex
                    }
                }
            }
            guard let provider = CGDataProvider(data: Data(indices) as CFData),
                  let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                      bytesPerRow: frame.width, space: space, bitmapInfo: CGBitmapInfo(rawValue: 0),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw StickerEncodingError.encodeFailed }
            return image
        }
        return (indexed, exact.isActive && !partialAlpha)
    }

    /// The frame's pixels, top row first, as 0x01RRGGBB (un-premultiplied) for pixels at least half opaque and 0 for
    /// the rest.
    private static func opaqueColors(of image: CGImage, partialAlpha: inout Bool) throws -> [UInt32] {
        let width = image.width, height = image.height
        guard let context = ImageOps.makeRGBAContext(width: width, height: height) else { throw StickerEncodingError.encodeFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { throw StickerEncodingError.encodeFailed }
        let bytesPerRow = context.bytesPerRow
        var colors = [UInt32](repeating: 0, count: width * height)
        var partial = false
        colors.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base + y * bytesPerRow
                for x in 0..<width {
                    let pixel = row + x * 4
                    let alpha = UInt32(pixel[3])
                    if alpha != 0, alpha != 255 { partial = true }
                    guard alpha >= 128 else { continue }
                    var red = UInt32(pixel[0]), green = UInt32(pixel[1]), blue = UInt32(pixel[2])
                    if alpha < 255 { // un-premultiply
                        red = min(255, (red * 255 + alpha / 2) / alpha)
                        green = min(255, (green * 255 + alpha / 2) / alpha)
                        blue = min(255, (blue * 255 + alpha / 2) / alpha)
                    }
                    out[y * width + x] = 0x0100_0000 | red << 16 | green << 8 | blue
                }
            }
        }
        if partial { partialAlpha = true }
        return colors
    }

    /// Distinct colors, until there are more than `maxOpaqueColors`.
    private struct ExactColors {
        private(set) var isActive = true
        private(set) var colors: [UInt32] = []
        private(set) var indices: [UInt32: UInt8] = [:]

        mutating func insert(_ color: UInt32) {
            guard indices[color] == nil else { return }
            guard colors.count < PaletteQuantizer.maxOpaqueColors else {
                isActive = false
                colors = []
                indices = [:]
                return
            }
            indices[color] = UInt8(colors.count)
            colors.append(color)
        }
    }

    /// Counts and color sums per 5-bit-per-channel bin.
    private struct Histogram {
        static let binCount = 1 << 15
        var counts = [Int](repeating: 0, count: binCount)
        var sums = [Int](repeating: 0, count: binCount * 3)

        static func bin(of color: UInt32) -> Int {
            Int((color >> 19) & 0x1F) << 10 | Int((color >> 11) & 0x1F) << 5 | Int((color >> 3) & 0x1F)
        }

        mutating func add(_ color: UInt32) {
            let bin = Self.bin(of: color)
            counts[bin] += 1
            sums[bin * 3] += Int((color >> 16) & 0xFF)
            sums[bin * 3 + 1] += Int((color >> 8) & 0xFF)
            sums[bin * 3 + 2] += Int(color & 0xFF)
        }

        /// Splits the populated bins into at most `maxColors` boxes, each time cutting the box with the largest
        /// (longest channel range × pixel count) at its weighted median. The palette is each box's mean color, and
        /// every bin maps to its own box.
        func medianCut(maxColors: Int) -> (palette: [UInt32], binToIndex: [UInt8]) {
            var boxes = [Box(bins: counts.indices.filter { counts[$0] > 0 }, histogram: self)]
            while boxes.count < maxColors {
                guard let (index, _) = boxes.enumerated()
                    .filter({ $0.element.bins.count > 1 })
                    .max(by: { $0.element.score < $1.element.score })
                else { break }
                let (low, high) = boxes[index].split(histogram: self)
                boxes[index] = low
                boxes.append(high)
            }
            var binToIndex = [UInt8](repeating: 0, count: Self.binCount)
            for (index, box) in boxes.enumerated() {
                for bin in box.bins { binToIndex[bin] = UInt8(index) }
            }
            return (boxes.map { $0.meanColor(histogram: self) }, binToIndex)
        }
    }

    private struct Box {
        var bins: [Int]
        var count = 0
        var axis = 0
        var range = 0

        init(bins: [Int], histogram: Histogram) {
            self.bins = bins
            var lowRed = 31, lowGreen = 31, lowBlue = 31, highRed = 0, highGreen = 0, highBlue = 0
            for bin in bins {
                count += histogram.counts[bin]
                let red = bin >> 10 & 0x1F, green = bin >> 5 & 0x1F, blue = bin & 0x1F
                lowRed = min(lowRed, red); highRed = max(highRed, red)
                lowGreen = min(lowGreen, green); highGreen = max(highGreen, green)
                lowBlue = min(lowBlue, blue); highBlue = max(highBlue, blue)
            }
            let ranges = [highRed - lowRed, highGreen - lowGreen, highBlue - lowBlue]
            range = ranges.max() ?? 0
            axis = ranges.firstIndex(of: range) ?? 0
        }

        var score: Double { Double(range) * Double(count) }

        func split(histogram: Histogram) -> (Box, Box) {
            let shift = [10, 5, 0][axis]
            let sorted = bins.sorted { ($0 >> shift) & 0x1F < ($1 >> shift) & 0x1F }
            // Cut at the weighted median, keeping at least one bin on each side.
            var running = 0
            var cut = 1
            for (offset, bin) in sorted.enumerated() {
                running += histogram.counts[bin]
                if running * 2 >= count { cut = offset + 1; break }
            }
            cut = min(max(cut, 1), sorted.count - 1)
            return (Box(bins: Array(sorted[..<cut]), histogram: histogram), Box(bins: Array(sorted[cut...]), histogram: histogram))
        }

        func meanColor(histogram: Histogram) -> UInt32 {
            var red = 0, green = 0, blue = 0
            for bin in bins {
                red += histogram.sums[bin * 3]
                green += histogram.sums[bin * 3 + 1]
                blue += histogram.sums[bin * 3 + 2]
            }
            let total = max(count, 1)
            return UInt32(red / total) << 16 | UInt32(green / total) << 8 | UInt32(blue / total)
        }
    }
}

/// Minimal PNG chunk editing.
enum PNGChunks {
    /// Inserts a chunk right after the first chunk of type `anchor`, or returns nil if there is none.
    static func inserting(_ type: String, data: Data, after anchor: String, in png: Data) -> Data? {
        let bytes = [UInt8](png)
        guard bytes.count > 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let chunkType = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let end = offset + 12 + length
            guard end <= bytes.count else { return nil }
            if chunkType == anchor {
                var result = Data(bytes[..<end])
                result.append(chunk(type, data: data))
                result.append(contentsOf: bytes[end...])
                return result
            }
            offset = end
        }
        return nil
    }

    /// Drops every chunk of type `type`, or returns nil if `png` isn't a well-formed PNG.
    static func removing(_ type: String, from png: Data) -> Data? {
        let bytes = [UInt8](png)
        guard bytes.count > 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
        var result = Data(bytes[0..<8])
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let end = offset + 12 + length
            guard end <= bytes.count else { return nil }
            if String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self) != type {
                result.append(contentsOf: bytes[offset..<end])
            }
            offset = end
        }
        return offset == bytes.count ? result : nil
    }

    static func chunk(_ type: String, data: Data) -> Data {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4, "PNG chunk types are four ASCII letters")
        var chunk = Data()
        chunk.append(bigEndian: UInt32(data.count))
        chunk.append(contentsOf: typeBytes)
        chunk.append(data)
        chunk.append(bigEndian: crc32(typeBytes + [UInt8](data)))
        return chunk
    }

    /// CRC-32 (ISO 3309), as the PNG spec computes it over a chunk's type and data.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
