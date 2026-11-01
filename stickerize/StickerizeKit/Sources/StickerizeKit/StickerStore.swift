import CoreGraphics
import Foundation
import UniformTypeIdentifiers

public struct Sticker: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// Shown to VoiceOver and used as the MSSticker `localizedDescription`.
    public var name: String
    /// Up to three emoji describing the sticker, used when exporting to WhatsApp / Telegram. Nil in older manifests.
    public var emoji: String?
    public let createdAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
    /// PNG for stills, GIF for animated stickers.
    public let format: StickerFormat
    /// The folder it's in; nil for the top level. Nil in manifests from before folders.
    public var folderID: UUID?

    public var fileName: String { id.uuidString + "." + format.fileExtension }
    public var isAnimated: Bool { format == .gif }

    public init(id: UUID = UUID(), name: String, emoji: String? = nil, createdAt: Date = Date(),
                pixelWidth: Int, pixelHeight: Int, byteCount: Int, format: StickerFormat = .png, folderID: UUID? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.format = format
        self.folderID = folderID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        // Manifests written before animated stickers existed have no format: everything was PNG.
        format = try container.decodeIfPresent(StickerFormat.self, forKey: .format) ?? .png
        // Lenient: a bad value puts the sticker at the top level instead of failing the whole manifest.
        folderID = try? container.decodeIfPresent(UUID.self, forKey: .folderID)
    }
}

struct StickerManifest: Codable, Equatable {
    /// 2 added folders. The value is the newest schema that may have written the file, not a promise that the file
    /// has that schema's data: a version 1 build decodes a version 2 file, drops what it doesn't know, and writes it
    /// back still saying 2.
    static let currentVersion = 2
    var version = currentVersion
    /// Display order: index 0 is shown first. A folder shows its stickers in this order too.
    var stickers: [Sticker] = []
    /// In no particular order: siblings are shown sorted by name.
    var folders: [StickerFolder] = []

    init(version: Int = currentVersion, stickers: [Sticker] = [], folders: [StickerFolder] = []) {
        self.version = version
        self.stickers = stickers
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        stickers = try container.decode([Sticker].self, forKey: .stickers)
        // One folder that can't be read is dropped (its stickers end up at the top level); it never costs the stickers.
        folders = (try? container.decodeIfPresent([Lossy<StickerFolder>].self, forKey: .folders))?.compactMap(\.value) ?? []
    }

    /// Repairs what a bad write, a downgrade or a bug could leave behind, without ever dropping a sticker: in order,
    /// duplicate folders (the first wins), folders whose parent is gone (to the top level), parent cycles (each
    /// folder, in array order, whose parent chain comes back to it moves to the top level), duplicate stickers (the
    /// first wins), and stickers whose folder is gone (to the top level).
    func normalized() -> StickerManifest {
        var seenFolders = Set<UUID>()
        var folders = self.folders.filter { seenFolders.insert($0.id).inserted }
        for index in folders.indices where folders[index].parentID.map({ !seenFolders.contains($0) }) ?? false {
            folders[index].parentID = nil
        }
        var parents = Dictionary(folders.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        for index in folders.indices {
            var visited = Set<UUID>()
            var next = folders[index].parentID
            while let current = next {
                if current == folders[index].id {
                    folders[index].parentID = nil
                    parents[current] = .some(nil)
                    break
                }
                // A cycle further up that doesn't come back here: its own folders break it on their turn.
                guard visited.insert(current).inserted else { break }
                next = parents[current] ?? nil
            }
        }
        var seenStickers = Set<UUID>()
        var stickers = self.stickers.filter { seenStickers.insert($0.id).inserted }
        for index in stickers.indices where stickers[index].folderID.map({ !seenFolders.contains($0) }) ?? false {
            stickers[index].folderID = nil
        }
        return StickerManifest(version: version, stickers: stickers, folders: folders)
    }
}

/// Decodes to nil instead of throwing, so one bad element doesn't fail a whole array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Just the schema version, read before anything else.
private struct ManifestVersion: Decodable {
    let version: Int?
}

/// What this build can read of a manifest from a newer one: every sticker and folder it understands.
private struct LenientManifest: Decodable {
    let stickers: [Lossy<Sticker>]?
    let folders: [Lossy<StickerFolder>]?
}

public enum StickerStoreError: LocalizedError, Equatable {
    case notFound(UUID)
    case folderNotFound(UUID)
    case folderNameTaken(String)
    /// A folder can't go inside itself or one of its own folders.
    case folderCycle
    /// The library was last written by a newer version of Stickerize; writing it here could lose what that version added.
    case manifestFromNewerVersion

    public var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "That sticker no longer exists.")
        case .folderNotFound: String(localized: "That folder no longer exists.")
        case let .folderNameTaken(name): String(localized: "There's already a folder named “\(name)” here.")
        case .folderCycle: String(localized: "A folder can't go inside itself.")
        case .manifestFromNewerVersion:
            String(localized: "Your stickers were last changed by a newer version of Stickerize. Update the app to change them.")
        }
    }
}

/// Sticker library shared by the app and its extensions.
///
/// Layout: `<container>/Stickers/<uuid>.png` plus `<container>/Stickers/manifest.json`. The container is the App Group
/// when the entitlement is present, otherwise the process's own Application Support directory (so the app still works,
/// but the extensions see their own empty library). Every mutation is a coordinated read-modify-write of the manifest
/// followed by a Darwin notification, so other processes can reload.
public final class StickerStore: Sendable {
    public enum Location: Sendable, Equatable {
        case appGroup(String)
        /// The App Group container wasn't available; data is private to this process.
        case local
    }

    /// Info.plist key whose value is the App Group identifier (filled from the `APP_GROUP` build setting).
    public static let appGroupInfoKey = "StickerizeAppGroup"
    public static let defaultGroupIdentifier = "group.ai.qokka.stickerize"

    public let location: Location
    public let directory: URL
    public let changeNotificationName: String
    private let manifestURL: URL

    /// The store configured by this bundle's Info.plist.
    public static func makeDefault(bundle: Bundle = .main) -> StickerStore {
        let group = (bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
        return StickerStore(appGroupIdentifier: group)
    }

    public convenience init(appGroupIdentifier: String?) {
        let fileManager = FileManager.default
        if let appGroupIdentifier,
           let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            self.init(directory: container.appendingPathComponent("Stickers", isDirectory: true),
                      location: .appGroup(appGroupIdentifier),
                      changeNotificationName: "\(appGroupIdentifier).stickers-changed")
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.init(directory: support.appendingPathComponent("Stickers", isDirectory: true),
                      location: .local,
                      changeNotificationName: "\(appGroupIdentifier ?? Self.defaultGroupIdentifier).local-stickers-changed")
        }
    }

    public init(directory: URL, location: Location = .local, changeNotificationName: String) {
        self.directory = directory
        self.location = location
        self.changeNotificationName = changeNotificationName
        self.manifestURL = directory.appendingPathComponent("manifest.json")
    }

    // MARK: Reading

    /// The stickers and folders, read together. Stickers whose image file is missing are left out.
    ///
    /// A plain read, never coordinated: writers replace the manifest atomically, so a read never sees half a write,
    /// and it can't block behind a writer (the app reads on the main thread) or need write access (a keyboard
    /// extension without Full Access can only read the App Group). Reading never changes anything on disk; a
    /// manifest that can't be decoded is rebuilt in memory and repaired by the next write.
    public func library() throws -> StickerLibrary {
        guard FileManager.default.fileExists(atPath: directory.path) else { return StickerLibrary() }
        let manifest = try loadManifest(at: manifestURL, repairing: false)
        // One directory listing instead of a check per sticker.
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return StickerLibrary(stickers: manifest.stickers.filter { files.contains($0.fileName) }, folders: manifest.folders)
    }

    /// All stickers in display order. Entries whose image file is missing are skipped.
    public func stickers() throws -> [Sticker] {
        try library().stickers
    }

    public func fileURL(for sticker: Sticker) -> URL {
        directory.appendingPathComponent(sticker.fileName)
    }

    public func data(for sticker: Sticker) throws -> Data {
        try Data(contentsOf: fileURL(for: sticker))
    }

    /// What to put on the pasteboard for pasting into other apps. Stills: a PNG scaled to fit
    /// `StickerSpec.pasteMaxPixelDimension`, alpha kept. Animated: the GIF as stored (Signal sends a pasted GIF as an
    /// animated image, Telegram as a GIF animation).
    public func pasteboardItem(for sticker: Sticker) throws -> (data: Data, type: UTType) {
        let data = try data(for: sticker)
        guard sticker.format == .png,
              max(sticker.pixelWidth, sticker.pixelHeight) > StickerSpec.pasteMaxPixelDimension else {
            return (data, sticker.format.type)
        }
        let image = try ImageLoader.image(from: data, maxPixelSize: StickerSpec.pasteMaxPixelDimension)
        return (try StickerEncoder.pngData(image), .png)
    }

    // MARK: Writing

    /// Saves an encoded sticker at the front of the library, or right after `after` if that sticker still exists (so
    /// a batch saved one by one keeps its own order).
    ///
    /// It goes into `folder` (the top level when nil, or when that folder has since been deleted), in the subfolder
    /// chain `path` below it: each level is the first subfolder whose name matches (`FolderName.key`), or a new one.
    /// Folders are created only here, in the same write as the sticker, so skipping images never leaves empty ones.
    /// The returned sticker's `folderID` is where it actually went.
    @discardableResult
    public func add(_ encoded: EncodedSticker, name: String, emoji: String? = nil, in folder: UUID? = nil,
                    path: [String] = [], after: UUID? = nil) throws -> Sticker {
        var sticker = Sticker(name: Self.cleanName(name), emoji: Self.cleanEmoji(emoji), pixelWidth: encoded.pixelWidth,
                              pixelHeight: encoded.pixelHeight, byteCount: encoded.data.count, format: encoded.format)
        try createDirectoryIfNeeded()
        let url = fileURL(for: sticker)
        try encoded.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try mutate { manifest in
                var parent = folder.flatMap { id in manifest.folders.contains { $0.id == id } ? id : nil }
                for component in path {
                    let name = FolderName.clean(component)
                    guard !name.isEmpty else { continue }
                    let key = FolderName.key(name)
                    if let existing = manifest.folders.first(where: { $0.parentID == parent && FolderName.key($0.name) == key }) {
                        parent = existing.id
                    } else {
                        let created = StickerFolder(name: name, parentID: parent)
                        manifest.folders.append(created)
                        parent = created.id
                    }
                }
                sticker.folderID = parent
                // A missing manifest is rebuilt from the image files on disk, which already include this one.
                manifest.stickers.removeAll { $0.id == sticker.id }
                let index = after.flatMap { id in manifest.stickers.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
                manifest.stickers.insert(sticker, at: index)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return sticker
    }

    public func rename(_ id: UUID, to name: String) throws {
        try mutate { manifest in
            guard let index = manifest.stickers.firstIndex(where: { $0.id == id }) else { throw StickerStoreError.notFound(id) }
            manifest.stickers[index].name = Self.cleanName(name)
        }
    }

    public func update(_ id: UUID, name: String, emoji: String?) throws {
        try mutate { manifest in
            guard let index = manifest.stickers.firstIndex(where: { $0.id == id }) else { throw StickerStoreError.notFound(id) }
            manifest.stickers[index].name = Self.cleanName(name)
            manifest.stickers[index].emoji = Self.cleanEmoji(emoji)
        }
    }

    public func delete(_ ids: Set<UUID>) throws {
        var removed: [Sticker] = []
        try mutate { manifest in
            removed = manifest.stickers.filter { ids.contains($0.id) }
            manifest.stickers.removeAll { ids.contains($0.id) }
        }
        for sticker in removed { try? FileManager.default.removeItem(at: fileURL(for: sticker)) }
    }

    /// Reorders to match `ids`. Stickers not mentioned keep their relative order after the mentioned ones.
    public func reorder(_ ids: [UUID]) throws {
        try mutate { manifest in
            let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let indexed = manifest.stickers.enumerated().map { (offset: $0.offset, sticker: $0.element) }
            manifest.stickers = indexed.sorted { a, b in
                (rank[a.sticker.id] ?? Int.max, a.offset) < (rank[b.sticker.id] ?? Int.max, b.offset)
            }.map(\.sticker)
        }
    }

    // MARK: Folders

    /// A new folder in `parent` (the top level when nil). A name already used there gets a number (“Cats 2”).
    @discardableResult
    public func createFolder(named name: String, in parent: UUID? = nil) throws -> StickerFolder {
        var folder = StickerFolder(name: FolderName.cleanOrDefault(name), parentID: parent)
        try mutate { manifest in
            if let parent, !manifest.folders.contains(where: { $0.id == parent }) { throw StickerStoreError.folderNotFound(parent) }
            folder.name = FolderName.unique(folder.name, among: manifest.folders.filter { $0.parentID == parent }.map(\.name))
            manifest.folders.append(folder)
        }
        return folder
    }

    /// Throws `folderNameTaken` if another folder in the same place has the name.
    public func renameFolder(_ id: UUID, to name: String) throws {
        let name = FolderName.cleanOrDefault(name)
        try mutate { manifest in
            guard let index = manifest.folders.firstIndex(where: { $0.id == id }) else { throw StickerStoreError.folderNotFound(id) }
            let parent = manifest.folders[index].parentID
            let key = FolderName.key(name)
            if manifest.folders.contains(where: { $0.id != id && $0.parentID == parent && FolderName.key($0.name) == key }) {
                throw StickerStoreError.folderNameTaken(name)
            }
            manifest.folders[index].name = name
        }
    }

    /// Moves a folder, with everything in it, into `parent` (the top level when nil). A name already used there gets
    /// a number.
    public func moveFolder(_ id: UUID, into parent: UUID?) throws {
        try mutate { manifest in
            guard let index = manifest.folders.firstIndex(where: { $0.id == id }) else { throw StickerStoreError.folderNotFound(id) }
            guard manifest.folders[index].parentID != parent else { return }
            if let parent {
                guard manifest.folders.contains(where: { $0.id == parent }) else { throw StickerStoreError.folderNotFound(parent) }
                if StickerLibrary(stickers: [], folders: manifest.folders).subtree(of: id).contains(parent) {
                    throw StickerStoreError.folderCycle
                }
            }
            let siblings = manifest.folders.filter { $0.parentID == parent && $0.id != id }.map(\.name)
            manifest.folders[index].name = FolderName.unique(manifest.folders[index].name, among: siblings)
            manifest.folders[index].parentID = parent
        }
    }

    /// Deletes a folder. Keeping its contents moves its stickers and subfolders up to its parent (subfolder names
    /// already used there get a number); otherwise every folder and sticker inside it is deleted too.
    public func deleteFolder(_ id: UUID, keepingContents: Bool) throws {
        var removed: [Sticker] = []
        try mutate { manifest in
            guard let folder = manifest.folders.first(where: { $0.id == id }) else { throw StickerStoreError.folderNotFound(id) }
            if keepingContents {
                var siblings = manifest.folders.filter { $0.parentID == folder.parentID && $0.id != id }.map(\.name)
                for index in manifest.folders.indices where manifest.folders[index].parentID == id {
                    manifest.folders[index].name = FolderName.unique(manifest.folders[index].name, among: siblings)
                    manifest.folders[index].parentID = folder.parentID
                    siblings.append(manifest.folders[index].name)
                }
                for index in manifest.stickers.indices where manifest.stickers[index].folderID == id {
                    manifest.stickers[index].folderID = folder.parentID
                }
                manifest.folders.removeAll { $0.id == id }
            } else {
                let subtree = StickerLibrary(stickers: [], folders: manifest.folders).subtree(of: id)
                removed = manifest.stickers.filter { $0.folderID.map(subtree.contains) ?? false }
                manifest.stickers.removeAll { $0.folderID.map(subtree.contains) ?? false }
                manifest.folders.removeAll { subtree.contains($0.id) }
            }
        }
        for sticker in removed { try? FileManager.default.removeItem(at: fileURL(for: sticker)) }
    }

    /// Moves stickers into `folder` (the top level when nil), keeping their place in the overall order.
    public func move(_ ids: Set<UUID>, to folder: UUID?) throws {
        try mutate { manifest in
            if let folder, !manifest.folders.contains(where: { $0.id == folder }) { throw StickerStoreError.folderNotFound(folder) }
            for index in manifest.stickers.indices where ids.contains(manifest.stickers[index].id) {
                manifest.stickers[index].folderID = folder
            }
        }
    }

    /// Starts observing changes made by any process using this store. Keep the returned object alive.
    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> StickerChangeObserver {
        StickerChangeObserver(name: changeNotificationName, handler: handler)
    }

    // MARK: Private

    /// A coordinated read-modify-write of the manifest (coordination serializes writers across processes), then a
    /// change notification.
    private func mutate(_ body: (inout StickerManifest) throws -> Void) throws {
        try createDirectoryIfNeeded()
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: manifestURL, options: [], error: &coordinationError) { url in
            result = Result {
                var manifest = try loadManifest(at: url, repairing: true)
                // Written by a newer build: rewriting it with this build's types would drop what that build added.
                guard manifest.version <= StickerManifest.currentVersion else { throw StickerStoreError.manifestFromNewerVersion }
                try body(&manifest)
                manifest.version = StickerManifest.currentVersion
                assert(manifest == manifest.normalized(), "a store operation left the manifest inconsistent")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(manifest).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        StickerChangeObserver.post(name: changeNotificationName)
    }

    /// Reads the manifest, normalized. A missing one is rebuilt from the image files on disk, so a bad write can never
    /// strand the user's stickers (no files means an empty library). One that can't be decoded is rebuilt the same
    /// way, in memory only unless `repairing` (the coordinated writer), which first sets it aside. Any other read error
    /// is thrown, so a file that exists but can't be read right now is never overwritten with a rebuilt library.
    /// A manifest from a newer version is never repaired: the writer throws, and readers get what they can read of it.
    private func loadManifest(at url: URL, repairing: Bool) throws -> StickerManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return rebuildManifest()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let version = (try? decoder.decode(ManifestVersion.self, from: data))?.version, version > StickerManifest.currentVersion {
            guard !repairing else { throw StickerStoreError.manifestFromNewerVersion }
            if let manifest = try? decoder.decode(StickerManifest.self, from: data) { return manifest.normalized() }
            let lenient = try? decoder.decode(LenientManifest.self, from: data)
            return StickerManifest(version: version, stickers: lenient?.stickers?.compactMap(\.value) ?? [],
                                   folders: lenient?.folders?.compactMap(\.value) ?? []).normalized()
        }
        if let manifest = try? decoder.decode(StickerManifest.self, from: data) { return manifest.normalized() }
        if repairing {
            let backup = directory.appendingPathComponent("manifest.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
        }
        return rebuildManifest()
    }

    private func rebuildManifest() -> StickerManifest {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let stickers: [Sticker] = files.compactMap { url in
            guard let format = StickerFormat(rawValue: url.pathExtension.lowercased()),
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let size = ImageLoader.orientedPixelSize(contentsOf: url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            return Sticker(id: id, name: "Sticker", createdAt: values?.creationDate ?? Date(),
                           pixelWidth: Int(size.width), pixelHeight: Int(size.height), byteCount: values?.fileSize ?? 0,
                           format: format)
        }
        return StickerManifest(stickers: stickers.sorted { $0.createdAt > $1.createdAt })
    }

    private func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sticker" : String(trimmed.prefix(StickerSpec.maxNameLength))
    }

    static func cleanEmoji(_ emoji: String?) -> String? {
        guard let trimmed = emoji?.filter({ !$0.isWhitespace }), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(3))
    }
}
