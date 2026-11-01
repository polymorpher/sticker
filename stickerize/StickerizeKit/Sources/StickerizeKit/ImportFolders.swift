import Foundation

/// Folders for the images in an imported ZIP archive: the archive's own layout, tidied up.
///
/// The same rule applies to the picked archive and to every archive inside it:
/// - When every image is inside the same folder (a zipped folder, a zip made with full paths), the innermost folder
///   they all share names the level and the folders above it are dropped, so "Cats.zip" holding "Cats/a.png" gives
///   "Cats", not "Cats › Cats", and "Users/me/Desktop/Cats/…" gives "Cats".
/// - Otherwise, or when that folder's name is a default one ("New folder", "Archive"), the archive's own name is the
///   folder ("Cats.zip" holding loose images gives "Cats"), unless that is a name nobody chose too: "Archive",
///   "download (3)", a hash, a camera name, a WeChat export page, or the name of one of its own top-level items
///   alongside others (Windows names a zip of several items after the one that was right-clicked). A zip holding just
///   another zip with such a name takes the outer one's name.
/// - Folders inside keep their names, except ones nobody would choose: UUIDs, hashes, camera folders ("DCIM",
///   "100APPLE") and the pages WeChat sticker exporters make ("1_50_组"), whose images go to the folder above.
/// - At most `maxDepth` levels; deeper images go into the deepest level kept.
public enum ImportFolders {
    public static let maxDepth = 3

    /// For each entry (an image's path inside the archive, as `ImageFinder.Found.path` gives it: "a/b.png",
    /// "more.zip/猫/ok.png"), the folder path to save it in, relative to where the import goes. `rootName` is the
    /// picked archive's file name, if known. Pass `complete: false` when the import stopped before the end of the
    /// archive (a limit): the common folder of the images found may not be the archive's, so it isn't collapsed.
    public static func paths(rootName: String?, entries: [String], complete: Bool = true) -> [[String]] {
        let items = entries.enumerated().map { Item(index: $0.offset, components: $0.element.split(separator: "/").map(String.init)) }
        let mapped = map(archive: rootName, items: items, complete: complete, fallback: nil)
        return entries.indices.map { Array((mapped[$0] ?? []).prefix(maxDepth)) }
    }

    /// `path` without a first level named like the folder the import goes into (importing "Cats.zip" inside "Cats").
    public static func relative(_ path: [String], toDestinationNamed destination: String?) -> [String] {
        guard let destination, let first = path.first, FolderName.key(first) == FolderName.key(destination) else { return path }
        return Array(path.dropFirst())
    }

    /// The folder name for an archive's own file name, or nil when nobody chose it.
    public static func archiveFolderName(_ fileName: String?, looseImages: [String] = []) -> String? {
        guard var name = fileName.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if isArchive(name) { name = String(name.dropLast(4)) }
        let cleaned = clean(name)
        guard !cleaned.isEmpty, StickerName.fromFileName(name) != nil, !isGeneric(cleaned), !isExportPage(name), !isCameraFolder(name)
        else { return nil }
        let key = FolderName.key(cleaned)
        guard !looseImages.contains(where: { FolderName.key(clean(($0 as NSString).deletingPathExtension)) == key }) else { return nil }
        return cleaned
    }

    /// The folder name for a folder inside an archive, or nil when its images should go to the folder above.
    public static func directoryFolderName(_ name: String) -> String? {
        let cleaned = clean(name)
        guard !cleaned.isEmpty, !isExportPage(name), !isCameraFolder(name),
              !generatedDirectoryPatterns.contains(where: { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil })
        else { return nil }
        return cleaned
    }

    // MARK: Private

    private struct Item {
        let index: Int
        /// What's left of the entry's path below the archive being mapped; the last component is the file.
        var components: [String]
    }

    private static let generatedDirectoryPatterns = [
        #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
        // Hashes have digits and letters (a name of only a–f letters, like "facade", is a word).
        #"^(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{16,}$"#,
    ]

    /// Names systems give archives and folders by default: "Archive", "download (3)", "New folder", "Untitled 2".
    private static func isGeneric(_ cleaned: String) -> Bool {
        cleaned.range(of: #"^(archive|archiv|download|downloads|untitled|new folder|compressed|files?)( \d+| ?\(\d+\))?$"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// export-wechat-emoji's pages, which it always names "<first>_<last>_组" ("1_50_组", "51_100_组"). Bare ranges
    /// ("2023-2024", "1-50") are names someone chose.
    private static func isExportPage(_ name: String) -> Bool {
        guard name.hasSuffix("组") else { return false }
        var text = name.dropLast()
        if text.last == "_" || text.last == " " { text = text.dropLast() }
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { "_ -".contains($0) })
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else { return false }
        return start >= 1 && end >= start
    }

    /// Camera roll folders: "DCIM", the DCF folders inside it ("100APPLE", "101_PANA", "100D3500") and iPhone's
    /// month folders ("202310__").
    private static func isCameraFolder(_ name: String) -> Bool {
        // A DCF folder's five characters have a letter or "_" ("100D3500"); eight digits are a date someone chose.
        name == "DCIM" || name.range(of: #"^(\d{3}(?=[A-Z0-9_]*[A-Z_])[A-Z0-9_]{5}|\d{6}__)$"#, options: .regularExpression) != nil
    }

    /// Underscores read as spaces, as in sticker names, then the folder-name rules.
    private static func clean(_ name: String) -> String {
        FolderName.clean(name.replacingOccurrences(of: "_", with: " "))
    }

    private static func isArchive(_ component: String) -> Bool {
        component.count > 4 && component.lowercased().hasSuffix(".zip")
    }

    /// `fallback`: the name to use when this archive has none of its own (an outer archive holding only this one).
    private static func map(archive name: String?, items: [Item], complete: Bool, fallback: String?) -> [Int: [String]] {
        // Where each item sits in this archive: its folders, ending at a nested archive if it is inside one.
        func local(_ item: Item) -> [String] {
            let folders = item.components.dropLast()
            if let inner = folders.firstIndex(where: isArchive) { return Array(folders[...inner]) }
            return Array(folders)
        }
        var common: [String] = []
        if complete, var prefix = items.first.map(local) {
            for item in items.dropFirst() { prefix = Array(zip(prefix, local(item)).prefix { $0 == $1 }.map(\.0)) }
            common = prefix
        }
        // Everything is inside one nested archive: that archive stands for this one, named after it or, if its name
        // is one nobody chose, after the folder it's in or this archive.
        if let last = common.last, isArchive(last) {
            let outer = common.dropLast().reversed().lazy.compactMap(directoryFolderName).first.flatMap { isGeneric($0) ? nil : $0 }
                ?? archiveFolderName(name) ?? fallback
            return map(archive: last, items: items.map { Item(index: $0.index, components: Array($0.components.dropFirst(common.count))) },
                       complete: complete, fallback: outer)
        }
        // The common folders are dropped either way. The innermost one that's a real folder names the level, unless
        // it's a default name ("New folder"); then the archive does. Folders above it (Users/me/…) never do.
        let commonName = common.reversed().lazy.compactMap(directoryFolderName).first.flatMap { isGeneric($0) ? nil : $0 }
        // What the level holds, below the dropped common folders: images and folders.
        let looseImages = items.filter { $0.components.count == common.count + 1 }.map { $0.components[common.count] }
        var level = commonName ?? archiveFolderName(name, looseImages: looseImages)
        // Windows names a zip of several items after the one that was right-clicked: then they're siblings.
        let topFolders = Set(items.compactMap { local($0).dropFirst(common.count).first }
            .map { FolderName.key(clean(isArchive($0) ? String($0.dropLast(4)) : $0)) })
        if commonName == nil, let named = level, topFolders.count + (looseImages.isEmpty ? 0 : 1) >= 2,
           topFolders.contains(FolderName.key(named)) {
            level = nil
        }
        level = level ?? fallback

        var result: [Int: [String]] = [:]
        var nested: [String: [Item]] = [:]
        var nestedOrder: [String] = []
        for item in items {
            let below = Array(local(item).dropFirst(common.count))
            var folders = (isArchive(below.last ?? "") ? below.dropLast() : below[...]).compactMap(directoryFolderName)
            if let level, let first = folders.first, FolderName.key(first) == FolderName.key(level) { folders.removeFirst() }
            result[item.index] = (level.map { [$0] } ?? []) + folders
            if let inner = below.last, isArchive(inner) {
                let key = (common + below).joined(separator: "/")
                if nested[key] == nil { nestedOrder.append(key) }
                nested[key, default: []].append(Item(index: item.index, components: Array(item.components.dropFirst(common.count + below.count))))
            }
        }
        for key in nestedOrder {
            let items = nested[key] ?? []
            let archive = String(key.split(separator: "/").last ?? "")
            for (index, inner) in map(archive: archive, items: items, complete: complete, fallback: nil) {
                result[index, default: []] += inner
            }
        }
        return result
    }
}
