import CoreGraphics
import Foundation
import StickerizeKit
import UniformTypeIdentifiers

/// Signal sticker packs, made in Signal Desktop (File → Create/upload sticker pack). Unlike WhatsApp and Telegram there
/// is no import API on iOS: you prepare files on disk and upload them from Signal Desktop.
///
/// What Signal's sticker creator accepts (Signal-Desktop sticker-creator/src: constants.ts, util/processImage.ts,
/// util/useStickerDropzone.ts):
/// - 1–200 stickers per pack, dropped as .png, .apng or .webp files
/// - stills: Signal redraws them on a 512×512 canvas as WebP at quality 0.8, which must come to ≤ 300 KiB
/// - animated: APNG only (a GIF would show its first frame), square, 10–512 px, ≤ 300 KiB, looping forever
///
/// Typical input: a folder of WeChat favorite stickers from export-wechat-emoji (GIF / JPG / PNG). The input folder is
/// never written to; packs go to `pack-01`, `pack-02`, … in a separate output folder.
public enum SignalPackExport {
    public static let stickerCount = 1...200
    public static let maxFileBytes = 300 * 1024
    public static let pixelDimension = 512
    /// Decoded frames kept per animation. Higher than the app extensions' default: this runs on a Mac, and frames the
    /// loader drops never reach the size ladder, which would rather drop them by time.
    static let animationMemoryBudget = 128 * 1024 * 1024

    public struct StickerInfo: Sendable, Equatable {
        public let sourceName: String
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// Frames in the output (1 for a still) and in the source file.
        public let frameCount: Int
        public let sourceFrameCount: Int
        /// Colors (or soft edges) were lost to a 256-color palette to fit the byte limit.
        public let colorsReduced: Bool
        /// Drawn smaller than the source (or than 512 px), losing detail, to fit a limit.
        public let shrunk: Bool

        public var animated: Bool { frameCount > 1 }
        /// An animation that couldn't fit the byte limit and was kept as a still.
        public var isStillFallback: Bool { sourceFrameCount > 1 && frameCount == 1 }
        /// Colors, size or frames were given up to fit; worth a look before uploading.
        public var wasReduced: Bool { colorsReduced || shrunk || frameCount < sourceFrameCount }
        /// `apng` for animations (Signal accepts the extension; the file is a PNG with animation chunks).
        public var fileExtension: String { animated ? "apng" : "png" }
    }

    public struct PreparedSticker: Sendable {
        public let data: Data
        public let info: StickerInfo
    }

    public struct WrittenSticker: Sendable {
        public let fileURL: URL
        public let info: StickerInfo
    }

    public struct Pack: Sendable {
        public let directory: URL
        public let stickers: [WrittenSticker]
    }

    public struct Skipped: Sendable, Equatable {
        public let name: String
        public let reason: String
    }

    public struct Report: Sendable {
        public let packs: [Pack]
        /// Inputs that couldn't be converted, for the whole run.
        public let skipped: [Skipped]
    }

    private static let imageExtensions: Set<String> = ["gif", "png", "apng", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    // MARK: Converting

    /// Converts one image (still or animated) into a Signal-ready sticker, without writing to disk.
    public static func prepare(contentsOf url: URL) throws -> PreparedSticker {
        let name = url.deletingPathExtension().lastPathComponent
        let sourceFrames = AnimatedImageLoader.frameCount(contentsOf: url)
        if sourceFrames > 1 {
            let animation = try AnimatedImageLoader.frames(contentsOf: url, maxPixelSize: pixelDimension,
                                                           memoryBudget: animationMemoryBudget)
            if animation.frames.count > 1,
               let encoded = try SignalAnimatedEncoder.encode(animation, maxSide: pixelDimension, maxBytes: maxFileBytes) {
                return PreparedSticker(data: encoded.data, info: StickerInfo(
                    sourceName: name, pixelWidth: encoded.side, pixelHeight: encoded.side, frameCount: encoded.frameCount,
                    sourceFrameCount: sourceFrames, colorsReduced: encoded.colorsReduced, shrunk: encoded.shrunk))
            }
            // Too detailed to animate within the limit: a still beats leaving the sticker out. Many stickers start on
            // an empty frame, so use the one that shows the most.
            let still = try encodeStill(mostVisibleFrame(of: animation.frames))
            return PreparedSticker(data: still.data, info: StickerInfo(
                sourceName: name, pixelWidth: still.width, pixelHeight: still.height, frameCount: 1,
                sourceFrameCount: sourceFrames, colorsReduced: false, shrunk: still.shrunk))
        }
        let image = try ImageLoader.image(contentsOf: url, maxPixelSize: pixelDimension * 2)
        let still = try encodeStill(image)
        return PreparedSticker(data: still.data, info: StickerInfo(
            sourceName: name, pixelWidth: still.width, pixelHeight: still.height, frameCount: 1,
            sourceFrameCount: 1, colorsReduced: false, shrunk: still.shrunk))
    }

    /// A still as PNG, at 512 px on the long side (small images are scaled up at most 3×). Signal doesn't limit the
    /// PNG: it redraws the still on a 512×512 canvas as WebP and only that has to fit, so the still is shrunk only if
    /// Signal's WebP would come out too big (`signalWebPSize`, with a 10% margin for encoder differences).
    static func encodeStill(_ image: CGImage) throws -> (data: Data, width: Int, height: Int, shrunk: Bool) {
        guard image.width > 0, image.height > 0 else { throw StickerEncodingError.invalidImage }
        let longest = Double(max(image.width, image.height))
        let full = min(Double(pixelDimension), longest * StickerSpec.maxUpscale).rounded(.down)
        let opaque = !ImageOps.hasTransparency(image)
        var side = full
        while true {
            let width = max(1, Int((Double(image.width) * side / longest).rounded()))
            let height = max(1, Int((Double(image.height) * side / longest).rounded()))
            guard let rendered = ImageOps.redraw(image, width: width, height: height, opaque: opaque) else {
                throw StickerEncodingError.encodeFailed
            }
            let webp = try signalWebPSize(of: rendered)
            if webp <= maxFileBytes * 9 / 10 {
                // Like the animations, without ImageIO's eXIf chunk.
                guard let png = PNGChunks.removing("eXIf", from: try StickerEncoder.pngData(rendered)) else {
                    throw StickerEncodingError.encodeFailed
                }
                return (png, width, height, side < min(full, longest))
            }
            guard side > Double(StickerSpec.minContentDimension) else {
                throw StickerEncodingError.cannotFitByteLimit(bytes: webp, limit: maxFileBytes)
            }
            side = max(Double(StickerSpec.minContentDimension), (side * 0.85).rounded(.down))
        }
    }

    /// What Signal's sticker creator does to a still before checking its size: scale it to fit a transparent 512×512
    /// canvas, centred, and encode it as WebP at quality 0.8 (processImage.ts).
    static func signalWebPSize(of image: CGImage) throws -> Int {
        let side = pixelDimension
        guard let context = ImageOps.makeRGBAContext(width: side, height: side) else { throw StickerEncodingError.encodeFailed }
        let scale = Double(side) / Double(max(image.width, image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        guard let canvas = context.makeImage() else { throw StickerEncodingError.encodeFailed }
        return try WebPEncoder.encode(rgba: WebPEncoder.straightRGBA(canvas), width: side, height: side, quality: 80).count
    }

    /// The frame with the most visible (opaque) area, judged on a 32×32 thumbnail; the earliest wins a tie.
    static func mostVisibleFrame(of frames: [CGImage]) throws -> CGImage {
        var best: (frame: CGImage, coverage: Int)?
        for frame in frames {
            guard let context = ImageOps.makeRGBAContext(width: 32, height: 32), let base = context.data else { continue }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            var coverage = 0
            for y in 0..<32 {
                for x in 0..<32 { coverage += Int(pixels[y * context.bytesPerRow + x * 4 + 3]) }
            }
            if coverage > (best?.coverage ?? 0) { best = (frame, coverage) }
        }
        guard let best else { throw SignalPackError.emptyAnimation }
        return best.frame
    }

    // MARK: Writing packs

    /// Converts every image in `inputDirectory` (not recursive) and writes Signal-ready packs into `outputDirectory` as
    /// `pack-01`, `pack-02`, … of up to `maxPerPack` stickers each.
    ///
    /// The input folder is never written to. Pack folders that an earlier run left in the output (folders named
    /// pack-NN holding only this tool's sticker files) make this throw `SignalPackError.outputHasPacks`, unless
    /// `replacingExisting` is set; they are then replaced once the new packs are ready, moved to the Trash if
    /// `movingReplacedToTrash` is set and deleted otherwise. Anything else named pack-NN is never touched, and is an
    /// error only if a new pack might need its name. The packs are built in a temporary folder on the same volume and
    /// moved into place at the end, so a run that fails or is interrupted while converting leaves the output as it was.
    @discardableResult
    public static func writePacks(from inputDirectory: URL, to outputDirectory: URL,
                                  maxPerPack: Int = stickerCount.upperBound,
                                  replacingExisting: Bool = false,
                                  movingReplacedToTrash: Bool = false) throws -> Report {
        let maxPerPack = min(max(1, maxPerPack), stickerCount.upperBound)
        try checkLocations(input: inputDirectory, output: outputDirectory)
        let inputs = try listImages(in: inputDirectory)
        guard !inputs.isEmpty else { throw SignalPackError.noImages(directory: inputDirectory.path) }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let existing = try packDirectories(in: outputDirectory)
        let previous = existing.filter(isPackFromThisTool)
        guard previous.isEmpty || replacingExisting else {
            throw SignalPackError.outputHasPacks(previous.map(\.lastPathComponent))
        }
        // Something this tool didn't make, sitting where a new pack may go, is the user's: stop rather than touch it.
        let possibleNames = Set((1...((inputs.count + maxPerPack - 1) / maxPerPack)).map { packName($0).lowercased() })
        let blocking = existing.filter { !previous.contains($0) && possibleNames.contains($0.lastPathComponent.lowercased()) }
        guard blocking.isEmpty else { throw SignalPackError.outputHasOtherItems(blocking.map(\.lastPathComponent)) }
        let staging = try stagingDirectory(for: outputDirectory)
        defer { try? fileManager.removeItem(at: staging) }

        // Each sticker is written as soon as it is converted, so memory doesn't grow with the folder.
        var packs: [[WrittenSticker]] = []
        var skipped: [Skipped] = []
        for url in inputs {
            let sticker: PreparedSticker
            do {
                sticker = try prepare(contentsOf: url)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                skipped.append(Skipped(name: url.lastPathComponent, reason: reason))
                continue
            }
            if packs.last.map({ $0.count >= maxPerPack }) ?? true {
                packs.append([])
                try fileManager.createDirectory(at: staging.appendingPathComponent(packName(packs.count)),
                                                withIntermediateDirectories: false)
            }
            let fileName = String(format: "%03d-%@.%@", packs[packs.count - 1].count + 1,
                                  sanitizeFileName(sticker.info.sourceName), sticker.info.fileExtension)
            let relativePath = packName(packs.count) + "/" + fileName
            try sticker.data.write(to: staging.appendingPathComponent(relativePath))
            packs[packs.count - 1].append(WrittenSticker(fileURL: outputDirectory.appendingPathComponent(relativePath),
                                                         info: sticker.info))
        }
        guard !packs.isEmpty else { throw SignalPackError.nothingConverted(skipped: skipped.count) }

        try install(packCount: packs.count, from: staging, into: outputDirectory, replacing: previous,
                    trash: movingReplacedToTrash)
        return Report(packs: packs.enumerated().map { index, stickers in
            Pack(directory: outputDirectory.appendingPathComponent(packName(index + 1), isDirectory: true), stickers: stickers)
        }, skipped: skipped)
    }

    public static func listImages(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: physicalURL(directory), includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
            .filter { url in
                imageExtensions.contains(url.pathExtension.lowercased())
                    && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Items directly in `directory` named like this tool's pack folders (pack-01, pack-02, …, in any case), whoever
    /// made them.
    public static func packDirectories(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: physicalURL(directory), includingPropertiesForKeys: nil, options: [])
            .filter { isPackName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func packName(_ number: Int) -> String { String(format: "pack-%02d", number) }

    static func isPackName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        guard lowercased.hasPrefix("pack-") else { return false }
        let digits = lowercased.dropFirst(5)
        return digits.count >= 2 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A real folder (not a symlink) holding nothing but sticker files named the way this tool names them
    /// (`001-name.png`, `002-name.apng`, …) and Finder's .DS_Store.
    static func isPackFromThisTool(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return false }
        return names.allSatisfy { name in
            if name == ".DS_Store" { return true }
            let lowercased = name.lowercased()
            let digits = lowercased.prefix { $0.isASCII && $0.isNumber }
            return digits.count >= 3 && lowercased.dropFirst(digits.count).hasPrefix("-")
                && (lowercased.hasSuffix(".png") || lowercased.hasSuffix(".apng"))
        }
    }

    // MARK: Locations

    /// Refuses an output folder that is, or is inside, the input folder, and an input folder that is, or is inside, a
    /// pack folder this run would write or replace. Both paths are first resolved the way the kernel will resolve them
    /// (`physicalURL`) and folders are compared by file identity, so other spellings of a path (case, symlinks, `..`)
    /// can't slip past.
    static func checkLocations(input: URL, output: URL) throws {
        let input = physicalURL(input), output = physicalURL(output)
        guard let inputID = identity(of: input) else { return } // a missing input fails when it is listed
        for folder in selfAndAncestors(of: output) {
            if let id = identity(of: folder), id.isEqual(inputID) { throw SignalPackError.outputInsideInput }
        }
        guard let outputID = identity(of: output) else { return } // nothing can be inside an output that doesn't exist
        for folder in selfAndAncestors(of: input) where isPackName(folder.lastPathComponent) {
            if let id = identity(of: folder.deletingLastPathComponent()), id.isEqual(outputID) {
                throw SignalPackError.inputInsidePackFolder(folder.lastPathComponent)
            }
        }
    }

    /// Where `url` really is: the deepest part of its path that exists goes through realpath(3), which resolves
    /// symlinks and `..` the way the kernel does, and the rest is appended. (URL's own standardizing treats `..` as text
    /// when part of the path doesn't exist yet, so `link/../new` would look like it sits next to `link`.)
    static func physicalURL(_ url: URL) -> URL {
        var existing = url.path
        var rest: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                var result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                for component in rest { result.appendPathComponent(component) }
                return result.standardizedFileURL
            }
            let parent = (existing as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != existing else { return url.standardizedFileURL }
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = parent
        }
    }

    /// `url` and every folder above it, ending with `/`. (Repeated `deletingLastPathComponent()` doesn't stop at the
    /// root: it goes on to `/..`.)
    private static func selfAndAncestors(of url: URL) -> [URL] {
        let components = url.standardizedFileURL.pathComponents
        return (1...max(components.count, 1)).reversed().map { count in
            URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(count))))
        }
    }

    private static func identity(of url: URL) -> (any NSObjectProtocol)? {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }

    /// A temporary folder on the output's volume (so installing is a rename), outside the output itself so an
    /// interrupted run leaves nothing there. Falls back to a hidden folder in the output if the system has none.
    private static func stagingDirectory(for output: URL) throws -> URL {
        let fileManager = FileManager.default
        if let temporary = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: physicalURL(output), create: true) {
            return temporary
        }
        let hidden = output.appendingPathComponent(".signal-pack-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: hidden, withIntermediateDirectories: false)
        return hidden
    }

    /// Moves the staged packs into place. Packs being replaced are first moved into the staging folder; if anything
    /// fails, the new packs are removed and the old ones moved back. Once the new packs are in, the old ones go to the
    /// Trash if asked (deleted with the staging folder otherwise, or if the Trash refuses them).
    private static func install(packCount: Int, from staging: URL, into output: URL, replacing existing: [URL],
                                trash: Bool) throws {
        let fileManager = FileManager.default
        let previous = staging.appendingPathComponent("previous", isDirectory: true)
        try fileManager.createDirectory(at: previous, withIntermediateDirectories: false)
        var movedAside: [(original: URL, aside: URL)] = []
        var installed: [URL] = []
        do {
            for item in existing {
                let aside = previous.appendingPathComponent(item.lastPathComponent)
                try fileManager.moveItem(at: item, to: aside)
                movedAside.append((item, aside))
            }
            for number in 1...packCount {
                let target = output.appendingPathComponent(packName(number), isDirectory: true)
                try fileManager.moveItem(at: staging.appendingPathComponent(packName(number), isDirectory: true), to: target)
                installed.append(target)
            }
        } catch {
            for url in installed { try? fileManager.removeItem(at: url) }
            for (original, aside) in movedAside { try? fileManager.moveItem(at: aside, to: original) }
            throw error
        }
        if trash {
            for (_, aside) in movedAside { try? fileManager.trashItem(at: aside, resultingItemURL: nil) }
        }
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        return trimmed.isEmpty ? "sticker" : String(trimmed)
    }
}

public enum SignalPackError: LocalizedError, Equatable {
    case noImages(directory: String)
    case nothingConverted(skipped: Int)
    case outputInsideInput
    case inputInsidePackFolder(String)
    case outputHasPacks([String])
    case outputHasOtherItems([String])
    case emptyAnimation

    public var errorDescription: String? {
        switch self {
        case let .noImages(directory): "No images found in \(directory)."
        case let .nothingConverted(skipped): "None of the \(skipped) images could be converted."
        case .outputInsideInput: "The output folder must be outside the input folder, so the originals are never touched."
        case let .inputInsidePackFolder(name):
            "The input folder is, or is inside, \(name) in the output folder, which this run would write into or replace. Choose another output folder."
        case let .outputHasPacks(names):
            "The output folder already has \(names.joined(separator: ", ")) from an earlier run. Choose another folder or replace them."
        case let .outputHasOtherItems(names):
            "The output folder has \(names.joined(separator: ", ")), which this tool didn't make, where new packs would go. Move them or choose another folder."
        case .emptyAnimation: "Every frame of the animation is transparent."
        }
    }
}
