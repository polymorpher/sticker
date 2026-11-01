import CoreGraphics
import CoreTransferable
import Foundation
import StickerizeKit
import UniformTypeIdentifiers

/// An image waiting to become a sticker. It holds the encoded source, not pixels: decoding a batch up front costs
/// ~7 MB per image at 1536 px (more at 2048), which a Share extension can't afford for 10 images, so each image is
/// decoded only when its editor step appears.
struct ImportedImage: Identifiable, Sendable {
    enum Source: Sendable {
        case data(Data)
        /// A private copy in `ImageImport.temporaryDirectory`, removed by `ImageImport.discard(_:)`.
        case file(URL)
    }

    let id = UUID()
    let source: Source
    let suggestedName: String
    /// Longest side to decode stills at.
    let maxPixelSize: Int
    /// Animated GIF, APNG, WebP or HEICS (more than one frame), from the header.
    let isAnimated: Bool
    /// Bytes the decoded frames of an animation may take.
    let animationMemoryBudget: Int
    /// Folders to save it in, below where the import goes: its folders inside a ZIP archive (see `ImportFolders`).
    var folderPath: [String] = []

    /// The image as a still (an animation's first frame).
    func decode() throws -> CGImage {
        switch source {
        case let .data(data): try ImageLoader.image(from: data, maxPixelSize: maxPixelSize)
        case let .file(url): try ImageLoader.image(contentsOf: url, maxPixelSize: maxPixelSize)
        }
    }

    /// All frames, at sticker size.
    func decodeAnimation() throws -> AnimatedFrames {
        switch source {
        case let .data(data): try AnimatedImageLoader.frames(from: data, memoryBudget: animationMemoryBudget)
        case let .file(url): try AnimatedImageLoader.frames(contentsOf: url, memoryBudget: animationMemoryBudget)
        }
    }
}

/// Turns whatever the user hands us (photo data, files, pasteboard or drag items, share-sheet attachments) into
/// imported images. Everything is decoded by ImageIO, so any format it reads works, plus page 1 of a PDF. A ZIP archive
/// gives every image inside it, in subfolders and nested archives too (see `ImageFinder`).
enum ImageImport {
    static let supportedTypes: [UTType] = [.image, .pdf, .zip]

    /// Most images one import opens: each gets an editor step, and a ZIP archive can hold thousands.
    static let maxImagesPerImport = 500

    /// What an import brought in.
    struct Loaded: Sendable {
        var images: [ImportedImage] = []
        /// Items that couldn't be used, counted per image for ZIP archives (damaged, password-protected, unreadable).
        var failures = 0
        /// Files in ZIP archives skipped for a limit: larger than one file may be, or nested too deep.
        var overLimit = 0
        /// More images were there than `maxImagesPerImport`; the rest were left out.
        var reachedLimit = false
        /// Bytes unpacked from ZIP archives, against `ImageFinder.Limits.maxTotalBytes`.
        var unpackedBytes: UInt64 = 0
        /// Archive records read, against `ImageFinder.Limits.maxEntries`.
        var archiveEntries = 0
        /// Files left out because unpacking ZIP archives would have gone past `maxTotalBytes` (images, archives that
        /// may hold many, and the items picked after them), from `firstLeftOut` (with the picked archive's name) on.
        var leftOutAtByteLimit = 0
        var firstLeftOut: String?
        /// A ZIP archive had more files than the import's `ImageFinder.Limits.maxEntries`.
        var tooManyFiles = false
        /// Items that couldn't be copied or unpacked, with why (a full disk), in words to show.
        var unpackProblems: [(reason: String, item: String?)] = []

        mutating func add(_ other: Loaded) {
            images += other.images
            failures += other.failures
            overLimit += other.overLimit
            firstLeftOut = firstLeftOut ?? other.firstLeftOut
            reachedLimit = reachedLimit || other.reachedLimit
            unpackedBytes += other.unpackedBytes
            archiveEntries += other.archiveEntries
            leftOutAtByteLimit += other.leftOutAtByteLimit
            tooManyFiles = tooManyFiles || other.tooManyFiles
            unpackProblems += other.unpackProblems
        }

        /// Counts what loading one item (named `item`, if it has a name) threw: a limit or a failure to copy or unpack
        /// is said as such, anything else is an item that couldn't be read.
        mutating func add(_ error: Error, item: String?) {
            switch error {
            case ImageFinder.FinderError.tooManyFiles:
                tooManyFiles = true
            case let ImageFinder.FinderError.cannotUnpack(path, reason):
                // The whole item failed (what an archive had unpacked is dropped with it), so it is named, not the entry.
                unpackProblems.append((reason, item ?? path))
            case let error as CocoaError where error.code == .fileWriteOutOfSpace:
                // Copying the item failed for lack of space, before anything could be read: the same reason as unpacking.
                unpackProblems.append((ImageFinder.notEnoughSpace, item))
            default:
                failures += 1
            }
        }

        /// The import's byte budget ran out: by the same rule as within an archive, the items after are left out too.
        var isPastByteLimit: Bool { leftOutAtByteLimit > 0 }

        /// What's left for the rest of the same import: one budget of images, unpacked bytes and archive records for
        /// every file in it.
        var remaining: ImageFinder.Limits {
            var limits = ImageFinder.Limits()
            limits.maxImages = maxImagesPerImport
            return limits.remaining(images: images.count, unpackedBytes: unpackedBytes, archiveEntries: archiveEntries)
        }
    }

    /// Where imported files are copied until they're edited. Cleared by `discard(_:)` and `purgeTemporaryFiles()`.
    static let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true)

    static func image(from data: Data, name: String?, maxPixelSize: Int = StickerSpec.importMaxPixelDimension) throws -> ImportedImage {
        guard ImageLoader.isReadable(data) else { throw ImageLoadingError.unreadable }
        return ImportedImage(source: .data(data), suggestedName: suggestedName(from: name), maxPixelSize: maxPixelSize,
                             isAnimated: AnimatedImageLoader.frameCount(of: data) > 1,
                             animationMemoryBudget: animationMemoryBudget(forMaxPixelSize: maxPixelSize))
    }

    /// A file we already own (a temporary copy); validated from its header.
    static func image(ownedFile url: URL, name: String?, maxPixelSize: Int = StickerSpec.importMaxPixelDimension) throws -> ImportedImage {
        guard ImageLoader.isReadable(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            throw ImageLoadingError.unreadable
        }
        return ImportedImage(source: .file(url), suggestedName: suggestedName(from: name), maxPixelSize: maxPixelSize,
                             isAnimated: AnimatedImageLoader.frameCount(contentsOf: url) > 1,
                             animationMemoryBudget: animationMemoryBudget(forMaxPixelSize: maxPixelSize))
    }

    /// Callers that work at a reduced size (the Share extension) are memory-limited; give animations half the budget.
    private static func animationMemoryBudget(forMaxPixelSize maxPixelSize: Int) -> Int {
        maxPixelSize >= StickerSpec.importMaxPixelDimension
            ? AnimatedImageLoader.defaultMemoryBudget
            : AnimatedImageLoader.defaultMemoryBudget / 2
    }

    /// Copies a file picked with `.fileImporter` (possibly outside the sandbox, possibly still in iCloud) into our
    /// temporary directory, so it can be decoded later without holding security-scoped access. A ZIP archive is
    /// unpacked within `limits` (what's left of the import's).
    static func images(pickedFile url: URL, maxPixelSize: Int = StickerSpec.importMaxPixelDimension,
                       limits: ImageFinder.Limits = Loaded().remaining) async throws -> Loaded {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = try temporaryURL(pathExtension: url.pathExtension)
            var coordinationError: NSError?
            var copyError: Error?
            // Coordinated read so files still downloading from iCloud Drive are materialized first.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: copy) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
            if ImageFinder.isArchive(copy) {
                return try images(inArchive: copy, named: url.lastPathComponent, maxPixelSize: maxPixelSize, limits: limits)
            }
            return Loaded(images: [try image(ownedFile: copy, name: url.lastPathComponent, maxPixelSize: maxPixelSize)])
        }.value
    }

    /// Every image in a ZIP archive we own (a temporary copy, removed here) within `limits`, each named after its own
    /// file and given the archive's folders (see `ImportFolders`). `name` is the archive's own: it can name the top
    /// folder, and says where files were left out.
    static func images(inArchive archive: URL, named name: String?, maxPixelSize: Int, limits: ImageFinder.Limits) throws -> Loaded {
        defer { try? FileManager.default.removeItem(at: archive) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let found: ImageFinder.Result
        do {
            found = try ImageFinder.find(in: archive, workDirectory: temporaryDirectory, includingPDFs: true, limits: limits)
        } catch let ImageFinder.FinderError.cannotUnpack(path, reason) {
            // Named by the picked archive too, as several may be.
            throw ImageFinder.FinderError.cannotUnpack(path: name.map { $0 + "/" + path } ?? path, reason: reason)
        }
        var loaded = Loaded(failures: found.skipped.filter { !$0.exceedsLimit }.count,
                            overLimit: found.skipped.filter(\.exceedsLimit).count, reachedLimit: found.reachedImageLimit,
                            unpackedBytes: found.unpackedBytes, archiveEntries: found.archiveEntries,
                            leftOutAtByteLimit: found.leftOutAtByteLimit,
                            firstLeftOut: found.firstLeftOutAtByteLimit.map { first in name.map { $0 + "/" + first } ?? first })
        let folders = ImportFolders.paths(rootName: name, entries: found.images.map(\.path),
                                          complete: !found.reachedImageLimit && found.leftOutAtByteLimit == 0)
        for (item, folderPath) in zip(found.images, folders) {
            do {
                var imported = try image(ownedFile: item.url, name: item.fileName, maxPixelSize: maxPixelSize)
                imported.folderPath = folderPath
                loaded.images.append(imported)
            } catch {
                loaded.failures += 1
            }
        }
        guard !loaded.images.isEmpty || loaded.failures > 0 || loaded.overLimit > 0 || loaded.reachedLimit || loaded.leftOutAtByteLimit > 0 else {
            throw ImageLoadingError.unreadable
        }
        return loaded
    }

    /// Main-actor bound because NSItemProvider isn't Sendable; loading is callback based.
    @MainActor
    static func images(from providers: [NSItemProvider], maxPixelSize: Int = StickerSpec.importMaxPixelDimension) async -> Loaded {
        var loaded = Loaded()
        for provider in providers {
            let remaining = loaded.remaining
            guard remaining.maxImages > 0 else {
                loaded.reachedLimit = true
                break
            }
            if loaded.isPastByteLimit {
                loaded.leftOutAtByteLimit += 1
                continue
            }
            do {
                let copy = try await provider.copyImageFile()
                if ImageFinder.isArchive(copy.url) {
                    let name = provider.suggestedName ?? copy.originalName
                    loaded.add(try await Task.detached(priority: .userInitiated) {
                        try ImageImport.images(inArchive: copy.url, named: name, maxPixelSize: maxPixelSize, limits: remaining)
                    }.value)
                    continue
                }
                // Photos and Files give the file's name as suggestedName; otherwise use the delivered file's name.
                let name = StickerName.fromFileName(provider.suggestedName) != nil ? provider.suggestedName : copy.originalName
                loaded.images.append(try image(ownedFile: copy.url, name: name, maxPixelSize: maxPixelSize))
            } catch {
                loaded.add(error, item: provider.suggestedName)
            }
        }
        return loaded
    }

    /// Deletes the temporary copies behind `items` once they're saved or skipped.
    static func discard(_ items: [ImportedImage]) {
        for item in items {
            if case let .file(url) = item.source { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Removes copies left over from an earlier session (for example if the app was killed mid-edit).
    static func purgeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    static func temporaryURL(pathExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return pathExtension.isEmpty ? url : url.appendingPathExtension(pathExtension)
    }

    /// The file's name as a sticker name ("funny_cat.png" → "funny cat"); generated names such as IMG_1234 give
    /// the default name instead.
    static func suggestedName(from fileName: String?) -> String {
        StickerName.fromFileName(fileName) ?? StickerName.fallback
    }
}

/// A picked photo received as a file, so its bytes never have to sit in memory (`PhotosPickerItem.loadTransferable`).
struct ImportedFile: Transferable {
    let url: URL
    /// The name Photos delivered the file under (the asset's file name, e.g. "funny_cat.png").
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = try ImageImport.temporaryURL(pathExtension: received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return ImportedFile(url: copy, originalName: received.file.lastPathComponent)
        }
    }
}

extension NSItemProvider {
    var canLoadImage: Bool {
        ImageImport.supportedTypes.contains { hasItemConformingToTypeIdentifier($0.identifier) }
    }

    /// Copies the most specific image (or PDF) representation into our temporary directory. File representations
    /// are copied on disk; only providers that offer nothing but in-memory data are written out from memory.
    /// `originalName` is the name the file was delivered under, when there was a file.
    @MainActor
    func copyImageFile() async throws -> (url: URL, originalName: String?) {
        let registered = registeredTypeIdentifiers.compactMap(UTType.init)
        let type = registered.first { candidate in ImageImport.supportedTypes.contains { candidate.conforms(to: $0) } }
            ?? ImageImport.supportedTypes.first { hasItemConformingToTypeIdentifier($0.identifier) }
        guard let type else { throw ImageLoadingError.unreadable }
        let extensionHint = type.preferredFilenameExtension ?? ""
        do {
            return try await withCheckedThrowingContinuation { continuation in
                _ = loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                    // The provided file is deleted when this handler returns, so copy it now.
                    guard let url else { return continuation.resume(throwing: error ?? ImageLoadingError.unreadable) }
                    do {
                        let copy = try ImageImport.temporaryURL(pathExtension: url.pathExtension.isEmpty ? extensionHint : url.pathExtension)
                        try FileManager.default.copyItem(at: url, to: copy)
                        continuation.resume(returning: (copy, url.lastPathComponent))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw error // writing the same bytes from memory can't fit either
        } catch {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                _ = loadDataRepresentation(for: type) { data, error in
                    if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? ImageLoadingError.unreadable) }
                }
            }
            let copy = try ImageImport.temporaryURL(pathExtension: extensionHint)
            do {
                try data.write(to: copy)
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            return (copy, nil)
        }
    }
}
