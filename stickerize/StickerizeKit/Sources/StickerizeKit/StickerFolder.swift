import Foundation

/// A folder of stickers. Folders exist only in the manifest: sticker files stay in one directory, so a folder's name is
/// never a file path and may hold any character, "/" included.
public struct StickerFolder: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// The folder it's in; nil for the top level.
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Lenient: a bad parent puts the folder at the top level instead of dropping it.
        parentID = try? container.decodeIfPresent(UUID.self, forKey: .parentID)
    }
}

/// Folder name rules, shared by the store, imports and the UI.
public enum FolderName {
    public static let maxLength = 100
    /// Also a cap on Unicode scalars, so a name of a few characters stacked with combining marks stays small.
    static let maxScalars = 400

    /// Used when a name is empty.
    public static var fallback: String { String(localized: "Folder") }

    /// NFC, without control characters or text-direction overrides (names from ZIP archives are stored and shown
    /// everywhere), whitespace runs collapsed to one space, trimmed, at most `maxLength` characters and `maxScalars`
    /// scalars. Idempotent.
    public static func clean(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars where !isDirectionControl(scalar) {
            scalars.append(scalar.properties.generalCategory == .control || scalar.properties.isWhitespace ? " " : scalar)
        }
        let collapsed = String(scalars).split(separator: " ").joined(separator: " ")
        var kept = Substring(collapsed.prefix(maxLength))
        while kept.unicodeScalars.count > maxScalars { kept = kept.dropLast() }
        return String(kept).trimmingCharacters(in: .whitespaces)
    }

    /// `clean`, or `fallback` when nothing is left.
    public static func cleanOrDefault(_ name: String) -> String {
        let cleaned = clean(name)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// What makes two names in the same folder the same: case and width are ignored ("Cats", "CATS", "ＣＡＴＳ"), accents
    /// are not ("Bär" and "Bar" are different words), like a case-insensitive file system.
    public static func key(_ name: String) -> String {
        clean(name).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// `name`, or with the first free number appended (“Cats 2”), so no name in `siblings` has the same key.
    public static func unique(_ name: String, among siblings: [String]) -> String {
        let taken = Set(siblings.map(key))
        guard taken.contains(key(name)) else { return name }
        for number in 2...(siblings.count + 2) {
            let candidate = fitted(name, suffix: " \(number)")
            if !taken.contains(key(candidate)) { return candidate }
        }
        // Unreachable: there are fewer siblings than numbers tried. A last resort that can't clash.
        return fitted(name, suffix: " " + UUID().uuidString.prefix(8))
    }

    /// `name` shortened so that with `suffix` it is still within both limits, so cleaning keeps the suffix.
    private static func fitted(_ name: String, suffix: String) -> String {
        var base = Substring(name)
        while !base.isEmpty, base.count + suffix.count > maxLength || base.unicodeScalars.count + suffix.unicodeScalars.count > maxScalars {
            base = base.dropLast()
        }
        let kept = String(base).trimmingCharacters(in: .whitespaces)
        return (kept.isEmpty ? fallback : kept) + suffix
    }

    /// Bidirectional embedding, override, isolate and mark characters, which can make a name display as something else.
    private static func isDirectionControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }
}

/// A snapshot of the library: stickers in display order and the folders they're in, with the lookups the screens need.
public struct StickerLibrary: Equatable, Sendable {
    public let stickers: [Sticker]
    public let folders: [StickerFolder]

    private let foldersByID: [UUID: StickerFolder]
    /// Children of each folder (nil key: the top level), sorted by name.
    private let childrenByParent: [UUID?: [StickerFolder]]
    /// Stickers directly in each folder (nil key: the top level), in display order.
    private let stickersByFolder: [UUID?: [Sticker]]
    private let positions: [UUID: Int]
    private let foldedFields = FoldedFieldCache()

    public init(stickers: [Sticker] = [], folders: [StickerFolder] = []) {
        self.stickers = stickers
        self.folders = folders
        foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        childrenByParent = Dictionary(grouping: folders, by: \.parentID).mapValues { $0.sorted(by: Self.nameOrder) }
        stickersByFolder = Dictionary(grouping: stickers, by: \.folderID)
        positions = Dictionary(stickers.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func == (lhs: StickerLibrary, rhs: StickerLibrary) -> Bool {
        lhs.stickers == rhs.stickers && lhs.folders == rhs.folders
    }

    public var isEmpty: Bool { stickers.isEmpty && folders.isEmpty }

    public func folder(_ id: UUID) -> StickerFolder? { foldersByID[id] }

    /// The folders directly in `parent` (the top level when nil), sorted by name as Finder does ("Folder 2" before
    /// "Folder 10").
    public func children(of parent: UUID?) -> [StickerFolder] { childrenByParent[parent] ?? [] }

    /// The stickers directly in `folder` (the top level when nil), in display order.
    public func stickers(in folder: UUID?) -> [Sticker] { stickersByFolder[folder] ?? [] }

    /// The stickers in `folder` and all its subfolders, in display order. Nil means the whole library.
    public func stickers(inTree folder: UUID?) -> [Sticker] {
        guard let folder else { return stickers }
        let subtree = subtree(of: folder)
        return stickers.filter { $0.folderID.map(subtree.contains) ?? false }
    }

    /// How many stickers `folder` and its subfolders hold.
    public func count(inTree folder: UUID) -> Int {
        subtree(of: folder).reduce(0) { $0 + (stickersByFolder[$1]?.count ?? 0) }
    }

    /// The first sticker of `folder`'s tree in display order, to stand for the folder (like an album's key photo).
    public func cover(of folder: UUID) -> Sticker? {
        subtree(of: folder).compactMap { stickersByFolder[$0]?.first }.min { positions[$0.id, default: 0] < positions[$1.id, default: 0] }
    }

    /// The folder and every folder inside it, at any depth.
    public func subtree(of folder: UUID) -> Set<UUID> {
        var result: Set<UUID> = [folder]
        var pending = [folder]
        while let next = pending.popLast() {
            for child in children(of: next) where result.insert(child.id).inserted { pending.append(child.id) }
        }
        return result
    }

    /// From the top-level folder down to `folder` itself; empty for nil or a folder that's gone.
    public func path(to folder: UUID?) -> [StickerFolder] {
        var path: [StickerFolder] = []
        var seen = Set<UUID>()
        var next = folder
        while let id = next, let current = foldersByID[id], seen.insert(id).inserted {
            path.insert(current, at: 0)
            next = current.parentID
        }
        return path
    }

    /// Every folder, depth first, each followed by its subfolders, with its depth (0 for top-level folders).
    public func outline(under parent: UUID? = nil) -> [(folder: StickerFolder, depth: Int)] {
        var result: [(folder: StickerFolder, depth: Int)] = []
        var visited = Set<UUID>()
        func visit(_ parent: UUID?, depth: Int) {
            for child in children(of: parent) where visited.insert(child.id).inserted {
                result.append((child, depth))
                visit(child.id, depth: depth + 1)
            }
        }
        visit(parent, depth: 0)
        return result
    }

    // MARK: Search

    /// Stickers in `scope`'s tree (the whole library when nil) matching `query`, in display order. Every word of the
    /// query has to appear in the sticker's name, its emoji, or the name of a folder it's in (relative to `scope`, so
    /// searching inside "Cats" for "cats" doesn't match everything). Case, accents and width are ignored, and words
    /// match anywhere, so Chinese and Japanese need no spaces.
    public func search(_ query: String, in scope: UUID? = nil) -> [Sticker] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        let scopeDepth = path(to: scope).count
        var folderText: [UUID: [String]] = [:]
        func names(_ folder: UUID?) -> [String] {
            guard let folder else { return [] }
            if let cached = folderText[folder] { return cached }
            let names = path(to: folder).dropFirst(scopeDepth).map(\.name)
            folderText[folder] = names
            return names
        }
        return stickers(inTree: scope).filter { sticker in
            let fields = [sticker.name, sticker.emoji ?? ""] + names(sticker.folderID)
            return words.allSatisfy { word in fields.contains { Self.contains($0, word) } }
        }
    }

    /// Folders in `scope`'s tree (not `scope` itself) whose name contains every word of `query`.
    public func searchFolders(_ query: String, in scope: UUID? = nil) -> [StickerFolder] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        return outline(under: scope).map(\.folder).filter { folder in words.allSatisfy { Self.contains(folder.name, $0) } }
    }

    /// The word just typed before the cursor in `text` (what a keyboard reads from the text field), the part a
    /// sticker search uses: the last run of one kind of writing, so "我好开心happy" gives "happy" and "lol😂" gives "😂".
    /// Nil when there is none, including after a sentence ended ("Great!"). A space typed after the word is fine.
    public static func typedWord(in text: String?) -> String? {
        typedToken(in: text)?.word
    }

    /// The typed word, and whether it is all of what was typed since the last space (not cut out of a longer run or
    /// following punctuation, as in "嗯，好").
    private static func typedToken(in text: String?) -> (word: String, isWhole: Bool)? {
        // Symbols other than emoji ("～", "♪", "^") separate words like punctuation.
        func separates(_ character: Character) -> Bool {
            character.isWhitespace || character.isPunctuation || (character.isSymbol && !character.isEmoji)
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), let last = text.last, !last.isPunctuation,
              let token = text.split(whereSeparator: separates).last
        else { return nil }
        let kind = TypedKind(token.last!)
        let run = String(token.reversed().prefix { TypedKind($0) == kind }.reversed())
        let sinceSpace = text.split(whereSeparator: \.isWhitespace).last.map(String.init)
        return (String(run.suffix(20)), run == sinceSpace)
    }

    /// Stickers matching the word just typed before the cursor (see `typedWord(in:)`), with the part that matched; nil
    /// when nothing matches. A word in a script written with spaces needs three letters (two in Korean) and has to
    /// start a word of the sticker's name, emoji or folders ("cat" finds "Happy cat", "at" finds nothing), so ordinary
    /// text rarely takes over. Text without spaces (Chinese, Japanese, Thai…) is matched by its longest ending found
    /// anywhere, down to two characters (one only when that one character is all that was typed, so "あと10分" doesn't
    /// look for "分"), so "我好开心" finds "开心". Emoji match anywhere, the last one alone too. Only the folder shown
    /// (`scope`) is searched.
    public func suggestions(forTextBefore text: String?, in scope: UUID? = nil) -> (word: String, stickers: [Sticker])? {
        guard let (token, isWhole) = Self.typedToken(in: text) else { return nil }
        let candidates: [(word: String, wordStart: Bool)]
        switch TypedKind(token.last!) {
        case .spaced(let korean):
            candidates = token.count >= (korean ? 2 : 3) ? [(token, true)] : []
        case .unspaced:
            let longest = min(token.count, 8)
            let shortest = token.count == 1 && isWhole ? 1 : 2
            candidates = longest < shortest ? [] : (shortest...longest).reversed().map { (String(token.suffix($0)), false) }
        case .symbol:
            candidates = [(token, false)] + (token.count > 1 ? [(String(token.last!), false)] : [])
        }
        guard !candidates.isEmpty else { return nil }
        // Fields are folded once per snapshot and folder shown, then each candidate is plain comparisons: this runs
        // each time the keyboard appears or the text changes.
        let pool = stickers(inTree: scope)
        let fields = foldedFields.fields(for: scope) {
            let scopeDepth = path(to: scope).count
            var folderNames: [UUID: [String]] = [:]
            return pool.map { sticker -> [String] in
                var names: [String] = []
                if let folder = sticker.folderID {
                    if let cached = folderNames[folder] {
                        names = cached
                    } else {
                        names = path(to: folder).dropFirst(scopeDepth).map { Self.fold($0.name) }
                        folderNames[folder] = names
                    }
                }
                return [Self.fold(sticker.name), Self.fold(sticker.emoji ?? "")] + names
            }
        }
        for candidate in candidates {
            let word = Self.fold(candidate.word)
            let found = zip(pool, fields).filter { _, fields in
                fields.contains { field in
                    candidate.wordStart
                        ? field.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(word) }
                        : field.contains(word)
                }
            }.map(\.0)
            if !found.isEmpty { return (candidate.word, found) }
        }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func contains(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    private static func nameOrder(_ a: StickerFolder, _ b: StickerFolder) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.id.uuidString < b.id.uuidString
        }
    }
}

/// How a typed character's script separates words, for `StickerLibrary.suggestions`.
private enum TypedKind: Equatable {
    /// Letters and digits of scripts written with spaces between words; Korean is one of them, with short words.
    case spaced(korean: Bool)
    /// Chinese, Japanese, Thai, Lao, Khmer and Burmese, written without spaces.
    case unspaced
    /// Emoji.
    case symbol

    init(_ character: Character) {
        let value = character.unicodeScalars.first!.value
        switch value {
        // Thai, Lao, Myanmar, Khmer; 々〆〇, kana repeat marks and 〻; kana; Han.
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3005...0x3007, 0x3031...0x3035, 0x303B,
             0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3FFFF:
            self = .unspaced
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
            self = .spaced(korean: true)
        default:
            self = character.isLetter || character.isNumber ? .spaced(korean: false) : .symbol
        }
    }
}

/// The folded search fields of a library snapshot, per folder shown, kept with the snapshot (which is immutable).
private final class FoldedFieldCache: @unchecked Sendable {
    private let lock = NSLock()
    private var fieldsByScope: [UUID?: [[String]]] = [:]

    func fields(for scope: UUID?, make: () -> [[String]]) -> [[String]] {
        if let cached = lock.withLock({ fieldsByScope[scope] }) { return cached }
        let fields = make()
        lock.withLock { fieldsByScope[scope] = fields }
        return fields
    }
}

private extension Character {
    /// Drawn as an emoji: an emoji-presentation character, one asking for emoji style (U+FE0F), or a sequence (flags,
    /// skin tones, ZWJ families). Not text symbols like "～" or "♪".
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || unicodeScalars.contains("\u{FE0F}")
            || (unicodeScalars.count > 1 && first.properties.isEmoji && !first.properties.isASCIIHexDigit)
    }
}
