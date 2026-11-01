import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finds the images in a folder or ZIP archive. Subfolders are searched, ZIP archives inside are opened (and ZIP
/// archives inside those), and files without an extension are recognized by their contents (WeChat's own sticker files
/// have none). Hidden files, macOS's `__MACOSX` resource copies and files ImageIO can't decode are left out.
///
/// Images in a folder are used in place; images in an archive are unpacked into `workDirectory`, one file each, named
/// by a UUID so archive paths can never escape it. If the search throws, the files it unpacked are removed. Everything
/// is visited in name order (numbers by value, "2.gif" before "10.gif"), with an archive's contents where the archive
/// is, so limits keep the first images in that order.
public enum ImageFinder {
    public struct Found: Sendable, Equatable {
        /// The image file: in place for a folder, a copy in the work directory for an archive.
        public let url: URL
        /// Where it came from, relative to what was searched: "1_50_组/abc.gif", "more.zip/猫/ok.png".
        public let path: String

        /// The original file name, for naming a sticker after it.
        public var fileName: String { (path as NSString).lastPathComponent }
    }

    public struct Skipped: Sendable, Equatable {
        public let path: String
        public let reason: String
        /// Skipped for a limit (too large, nested too deep), not because anything is wrong with it.
        public var exceedsLimit = false
    }

    public struct Result: Sendable {
        /// In the order they were found: by name, folder by folder and archive by archive.
        public var images: [Found] = []
        /// Images and archives that couldn't be used: encrypted, damaged, too large, nested too deep.
        public var skipped: [Skipped] = []
        /// Files that aren't images ImageIO can decode (text, video, design files, …), left alone.
        public var otherFiles = 0
        /// The search stopped at `Limits.maxImages`; there may be more.
        public var reachedImageLimit = false
        /// Images and archives left out because unpacking them would have gone past `Limits.maxTotalBytes`: the first
        /// one that didn't fit and every image and archive found after it, in archives or not, so "the rest" is a tail
        /// of the order found.
        public var leftOutAtByteLimit = 0
        /// The path of the first of those.
        public var firstLeftOutAtByteLimit: String?
        /// What was unpacked, as counted against `Limits.maxTotalBytes`.
        public var unpackedBytes: UInt64 = 0
        /// Archive records read, as counted against `Limits.maxEntries`.
        public var archiveEntries = 0
    }

    public struct Limits: Sendable {
        /// Largest single file to unpack.
        public var maxFileBytes: UInt64 = 256 * 1024 * 1024
        /// Everything unpacked in one search, from every archive in it (each file counts at least 4 KB, a disk block).
        public var maxTotalBytes: UInt64 = 2 * 1024 * 1024 * 1024
        /// Archives inside archives, counting the outermost one.
        public var maxNesting = 4
        /// Archive entries (of any kind) in one search, from every archive in it. Past it the search fails.
        public var maxEntries = 200_000
        /// Images to find; the search stops there and says so.
        public var maxImages = 10_000

        public init() {}

        /// What is left of these limits after `result`, for searching more as part of the same import.
        public func remaining(after result: Result) -> Limits {
            remaining(images: result.images.count, unpackedBytes: result.unpackedBytes, archiveEntries: result.archiveEntries)
        }

        /// What is left of these limits once an import has used this much of them.
        public func remaining(images: Int, unpackedBytes: UInt64, archiveEntries: Int) -> Limits {
            var limits = self
            limits.maxImages = max(0, maxImages - images)
            limits.maxTotalBytes -= min(unpackedBytes, maxTotalBytes)
            limits.maxEntries = max(0, maxEntries - archiveEntries)
            return limits
        }
    }

    public enum FinderError: LocalizedError, Equatable {
        case tooManyFiles(Int)
        /// Writing an unpacked file failed (a full disk, say).
        case cannotUnpack(path: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case let .tooManyFiles(limit):
                "There are more than \(limit.formatted()) files in the archives, more than one import can take."
            case let .cannotUnpack(path, reason):
                "\(ImageFinder.displayPath(path)) couldn't be unpacked: \(reason)"
            }
        }
    }

    /// Searches `url`: a folder, a ZIP archive (by extension or contents), or a single image. PDFs count as images if
    /// `includingPDFs` is set. `checkCancelled` is called before each file; what it throws ends the search.
    public static func find(in url: URL, workDirectory: URL, includingPDFs: Bool = false,
                            limits: Limits = Limits(), checkCancelled: @escaping () throws -> Void = {}) throws -> Result {
        var search = Search(workDirectory: workDirectory, includingPDFs: includingPDFs, limits: limits, checkCancelled: checkCancelled)
        do {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try search.searchFolder(url)
            } else if isArchive(url) {
                try search.searchArchive(url, path: "", nesting: 1)
            } else if search.kind(ofFile: url, name: url.lastPathComponent) == .image {
                search.result.images.append(Found(url: url, path: url.lastPathComponent))
            } else {
                throw ImageLoadingError.unreadable
            }
        } catch is Search.ReachedImageLimit {
            search.result.reachedImageLimit = true
        } catch {
            for unpacked in search.unpacked { try? FileManager.default.removeItem(at: unpacked) }
            throw error
        }
        search.result.unpackedBytes = search.unpackedBytes
        search.result.archiveEntries = search.entriesSeen
        return search.result
    }

    /// Why writing a file failed on a full disk.
    public static let notEnoughSpace = "There isn't enough space on the disk."

    /// A path from what was searched, safe and short enough to show: a hostile archive can name thousands of files with
    /// a kilobyte each, and put control characters in them (escape sequences for a terminal, or bidirectional overrides
    /// that reorder a message), which are replaced.
    public static func displayPath(_ path: String) -> String {
        let safe = String(String.UnicodeScalarView(path.unicodeScalars.map { scalar -> Unicode.Scalar in
            scalar.properties.generalCategory == .control || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) ? "\u{FFFD}" : scalar
        }))
        let scalars = safe.unicodeScalars
        return scalars.count <= 160 ? safe : String(scalars.prefix(100)) + "…" + String(scalars.suffix(50))
    }

    /// Whether `url` is a ZIP archive, by extension or contents (attachments saved as ".bin", downloads with no
    /// extension).
    public static func isArchive(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension) == .zip || contentType(of: url) == .zip
    }

    // MARK: Search

    enum Kind {
        case image, archive, other
    }

    private struct Search {
        struct ReachedImageLimit: Error {}

        let workDirectory: URL
        let includingPDFs: Bool
        let limits: Limits
        let checkCancelled: () throws -> Void
        var result = Result()
        /// Files this search unpacked and handed out in `result.images`, removed if the search fails.
        var unpacked: [URL] = []
        var unpackedBytes: UInt64 = 0
        var entriesSeen = 0
        /// An entry didn't fit the byte budget: everything after it is left out too.
        var reachedByteLimit = false

        init(workDirectory: URL, includingPDFs: Bool, limits: Limits, checkCancelled: @escaping () throws -> Void) {
            self.workDirectory = workDirectory
            self.includingPDFs = includingPDFs
            self.limits = limits
            self.checkCancelled = checkCancelled
        }

        private static func inNameOrder(_ a: String, _ b: String) -> Bool {
            a.localizedStandardCompare(b) == .orderedAscending
        }

        mutating func searchFolder(_ folder: URL) throws {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
            // Folders that can't be opened (no permission) are reported, not passed over in silence.
            final class Unreadable { var urls: [URL] = [] }
            let unreadable = Unreadable()
            // Symlinked folders aren't entered (no cycles); symlinked files are used if they lead to a regular file.
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                                  errorHandler: { url, _ in unreadable.urls.append(url); return true })
            else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: folder.path]) }
            var files: [(url: URL, path: String)] = []
            for case let url as URL in enumerator {
                // The enumerator may spell the folder's own path differently (/var vs /private/var), so count levels.
                let path = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    result.skipped.append(Skipped(path: path, reason: "The file couldn't be read."))
                    continue
                }
                let isFile = values.isRegularFile == true
                    || (values.isSymbolicLink == true
                        && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true)
                guard isFile else { continue }
                files.append((url, path))
            }
            let root = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            for url in unreadable.urls {
                let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard components.count > root.count, Array(components.prefix(root.count)) == root else {
                    // The folder searched itself.
                    throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
                }
                result.skipped.append(Skipped(path: components.dropFirst(root.count).joined(separator: "/"),
                                              reason: "The folder couldn't be opened."))
            }
            files.sort { Self.inNameOrder($0.path, $1.path) }
            for (url, path) in files {
                try checkCancelled()
                // Without an extension the contents decide, which takes reading the file.
                if kind(ofName: url.lastPathComponent) == nil, !FileManager.default.isReadableFile(atPath: url.path) {
                    result.skipped.append(Skipped(path: path, reason: "The file couldn't be read."))
                    continue
                }
                let kind = kind(ofFile: url, name: url.lastPathComponent)
                // Past the byte budget everything after is left out, files beside the archives too: "from X on" holds.
                if kind != .other, reachedByteLimit {
                    result.leftOutAtByteLimit += 1
                    continue
                }
                switch kind {
                case .image:
                    try add(Found(url: url, path: path), unpacked: false)
                case .archive:
                    do {
                        try searchArchive(url, path: path, nesting: 1)
                    } catch let error as ZipError {
                        // This archive is damaged or can't be read; limits, cancelling and write failures end the search.
                        result.skipped.append(Skipped(path: path, reason: describe(error)))
                    }
                case .other:
                    result.otherFiles += 1
                }
            }
        }

        /// `path` is the archive's own path in the search ("" for the archive searched itself).
        mutating func searchArchive(_ url: URL, path: String, nesting: Int) throws {
            // Every record counts, folders and hidden files too: they cost parsing all the same.
            let remaining = limits.maxEntries - entriesSeen
            let archive: ZipArchive
            var recordsRead = 0
            do {
                archive = try ZipArchive(contentsOf: url, maxEntries: remaining, preferredLanguages: Locale.preferredLanguages,
                                         recordsRead: &recordsRead, checkCancelled: checkCancelled)
            } catch ZipError.tooManyEntries {
                throw FinderError.tooManyFiles(limits.maxEntries)
            } catch {
                // One that fails after reading its directory has cost the records read, so damaged archives can't each
                // cost the whole allowance.
                entriesSeen += recordsRead
                throw error
            }
            entriesSeen += archive.entries.count
            // Names longer than any real file's are hostile, and costly to sort and compare. Sorting a few hundred
            // thousand names still takes a while: it can be stopped.
            var files: [ZipArchive.Entry] = []
            for (index, entry) in archive.entries.enumerated() {
                if index % 4_096 == 4_095 { try checkCancelled() }
                guard !entry.isDirectory, !entry.isSymbolicLink, !isHiddenOrResourceCopy(entry.path) else { continue }
                if entry.hasOverlongName {
                    let entryPath = (path.isEmpty ? "" : path + "/") + String(entry.path.prefix(60)) + "…"
                    result.skipped.append(Skipped(path: entryPath, reason: "Its name is longer than any real file's."))
                } else {
                    files.append(entry)
                }
            }
            var comparisons = 0
            let sorted = try files.sorted { a, b in
                comparisons += 1
                if comparisons % 4_096 == 0 { try checkCancelled() }
                return Self.inNameOrder(a.path, b.path)
            }
            for entry in sorted {
                try checkCancelled()
                let entryPath = path.isEmpty ? entry.path : path + "/" + entry.path
                var known = kind(ofName: entry.fileName)
                if known == .other {
                    result.otherFiles += 1
                    continue
                }
                do {
                    if known == nil {
                        // No extension, or one nobody declared: tell from the first bytes, unpacking the rest only for
                        // an image or (with no extension at all) a ZIP archive, so a large non-image isn't "too large".
                        try archive.checkCanExtract(entry, maxBytes: .max)
                        known = kind(ofContent: ImageFinder.contentType(ofPrefix: try archive.prefix(of: entry, count: 512)),
                                     name: entry.fileName)
                    }
                    // What can be told without unpacking: encrypted, unsupported compression, too large.
                    if known != .other { try archive.checkCanExtract(entry, maxBytes: limits.maxFileBytes) }
                } catch let error as ZipError {
                    result.skipped.append(Skipped(path: entryPath, reason: describe(error), exceedsLimit: isLimit(error)))
                    continue
                }
                guard let kind = known, kind != .other else {
                    result.otherFiles += 1
                    continue
                }
                if kind == .archive, nesting >= limits.maxNesting {
                    result.skipped.append(Skipped(path: entryPath, reason: tooDeep, exceedsLimit: true))
                    continue
                }
                // Charged before unpacking, whatever happens next: a damaged entry costs as much inflating as a good
                // one, and unpacking never goes past the declared size.
                let charge = max(entry.uncompressedSize, 4096)
                guard !reachedByteLimit, charge <= limits.maxTotalBytes - unpackedBytes else {
                    reachedByteLimit = true
                    result.leftOutAtByteLimit += 1
                    if result.firstLeftOutAtByteLimit == nil { result.firstLeftOutAtByteLimit = entryPath }
                    continue
                }
                unpackedBytes += charge
                // Keep the extension ImageIO and PDF loading go by: the entry's own, or one for what its content is.
                let ext = (entry.fileName as NSString).pathExtension
                let declared = !ext.isEmpty && UTType(filenameExtension: ext)?.isDeclared == true
                let target = workDirectory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(declared ? ext : (kind == .archive ? "zip" : "img"))
                do {
                    try archive.extract(entry, to: target, maxBytes: limits.maxFileBytes, checkCancelled: checkCancelled)
                } catch let error as ZipError {
                    result.skipped.append(Skipped(path: entryPath, reason: describe(error), exceedsLimit: isLimit(error)))
                    continue
                } catch let error as CocoaError {
                    // Named by the entry, not the temporary file it was going into.
                    throw FinderError.cannotUnpack(path: entryPath, reason: Self.reason(error))
                }
                // Anything else (a full disk, an unwritable work folder) ends the search.
                switch kind {
                case .image:
                    var image = target
                    if !declared, let type = ImageFinder.contentType(of: target)?.preferredFilenameExtension {
                        let named = target.deletingPathExtension().appendingPathExtension(type)
                        if (try? FileManager.default.moveItem(at: target, to: named)) != nil { image = named }
                    }
                    try add(Found(url: image, path: entryPath), unpacked: true)
                case .archive:
                    defer { try? FileManager.default.removeItem(at: target) }
                    do {
                        try searchArchive(target, path: entryPath, nesting: nesting + 1)
                    } catch let error as ZipError {
                        result.skipped.append(Skipped(path: entryPath, reason: describe(error)))
                    }
                case .other:
                    break
                }
            }
        }

        private mutating func add(_ found: Found, unpacked isUnpacked: Bool) throws {
            guard result.images.count < limits.maxImages else {
                if isUnpacked { try? FileManager.default.removeItem(at: found.url) }
                throw ReachedImageLimit()
            }
            if isUnpacked { unpacked.append(found.url) }
            result.images.append(found)
        }

        private var tooDeep: String { "It's a ZIP archive inside more than \(limits.maxNesting - 1) others." }

        private func isLimit(_ error: ZipError) -> Bool {
            if case .entryTooLarge = error { true } else { false }
        }

        /// Why writing failed, in words that don't name the temporary file.
        private static func reason(_ error: CocoaError) -> String {
            if error.code == .fileWriteOutOfSpace { return ImageFinder.notEnoughSpace }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return underlying.localizedDescription + "." }
            return (error as NSError).localizedFailureReason ?? error.localizedDescription
        }

        /// By extension: nil when the extension says nothing (none, or one no app has declared), so the contents decide.
        func kind(ofName name: String) -> Kind? {
            let ext = (name as NSString).pathExtension
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.isDeclared else { return nil }
            // Only plain ZIP archives: Office documents, .jar, .epub and the like are ZIPs too, of something else.
            if type == .zip { return .archive }
            return isUsable(type) ? .image : .other
        }

        func kind(ofFile url: URL, name: String) -> Kind {
            kind(ofName: name) ?? kind(ofContent: ImageFinder.contentType(of: url), name: name)
        }

        func kind(ofContent type: UTType?, name: String) -> Kind {
            guard let type else { return .other }
            // A ZIP with an extension nobody declared is a document of some app (.procreate, .kra, .sketch): its
            // previews aren't stickers. Without an extension it is an archive someone saved bare.
            if type == .zip { return (name as NSString).pathExtension.isEmpty ? .archive : .other }
            return isUsable(type) ? .image : .other
        }

        /// Image types ImageIO can decode here (SVG, Illustrator and others are declared images but can't be), and
        /// PDFs if asked for. A plain `.image` is one ImageIO read that the system has no type for.
        private func isUsable(_ type: UTType) -> Bool {
            (includingPDFs && type.conforms(to: .pdf)) || type == .image || ImageFinder.decodableTypes.contains { type.conforms(to: $0) }
        }

        private func isHiddenOrResourceCopy(_ path: String) -> Bool {
            path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
        }

        private func describe(_ error: Error) -> String {
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static let decodableTypes: [UTType] = imageIOTypes.compactMap(UTType.init)

    /// The type of a file from its first bytes: ZIP, PDF, or any image ImageIO recognizes.
    static func contentType(of url: URL) -> UTType? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return contentType(ofPrefix: (try? handle.read(upToCount: 512)) ?? Data())
    }

    /// The type from a file's first bytes (512 are enough for every format ImageIO reads). An image type ImageIO reads
    /// but the system doesn't declare (AVIF image sequences, "public.avis") comes back as plain `.image`.
    static func contentType(ofPrefix prefix: Data) -> UTType? {
        let header = [UInt8](prefix.prefix(5))
        // A local file header, or the end record of an empty archive.
        if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) || header.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if header.elementsEqual("%PDF-".utf8) { return .pdf }
        guard let source = CGImageSourceCreateWithData(prefix as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier) ?? (imageIOTypes.contains(identifier) ? .image : nil)
    }

    private static let imageIOTypes = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
}
