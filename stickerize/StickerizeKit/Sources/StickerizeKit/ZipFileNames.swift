import Foundation

/// Decodes the file names in a ZIP archive.
///
/// ZIP has no reliable name encoding. Archives that mark a name as UTF-8 (flag bit 11), or carry Info-ZIP's UTF-8 copy
/// of it, are easy, and so are tools that write UTF-8 without saying so (Finder's Compress, `zip`). Windows' "Send to
/// compressed folder" and many older tools write the system's legacy code page instead: GBK on Chinese Windows, which is
/// how most sticker collections from WeChat arrive, Big5 for Traditional Chinese, Shift_JIS, Korean CP949, and the DOS
/// code pages CP850 (Western Europe, the Americas) and CP866 (Russian).
///
/// The choice is made once for the whole archive, because one name is little evidence: about one GBK character in
/// eight is also a valid UTF-8 sequence, so a short GBK name can pass for UTF-8 on its own. Where each name was made
/// helps: tools on macOS and Linux write UTF-8, and Windows tools that write UTF-8 mark it, so an unmarked name made on
/// Unix is UTF-8 (in an archive from Windows, another tool added it) and one made on Windows is likely legacy. An
/// archive with any name that isn't valid UTF-8 is legacy-encoded. One whose names are all valid UTF-8 stays UTF-8
/// unless most of its names don't read as text in UTF-8 (unassigned characters, lone letters, Greek glued to Cyrillic;
/// names made on Unix are judged leniently) while a legacy code page reads well, and words of an alphabet ("caffè",
/// "кабан") count against switching: misread legacy bytes rarely spell one. In a legacy archive, a name that is valid
/// UTF-8 stays UTF-8 when it reads as such a word, or when only its UTF-8 reading looks like text (another tool may
/// have added it).
///
/// Among legacy code pages, each candidate must decode every legacy name exactly, and the one whose characters are most
/// typical of real text wins. Typical means the encoding's own frequently-used block (GB2312's hanzi, Big5's common
/// characters, kana and level-1 kanji, KS X 1001 Hangul, accented Latin and Cyrillic letters inside words). Text in one
/// of these encodings read as another mostly lands in rare blocks, so this tells them apart even for short names.
///
/// Some bytes read equally well as GBK, Big5 or Korean. Those ties go to the reading far likelier to be real text, judged
/// by how many of its characters are everyday ones (`FrequentCharacters`): real names use common characters, a
/// misreading lands on arbitrary ones. Otherwise the code page of the user's own language wins, then Simplified Chinese.
/// (`ZipFileNamesAccuracyTests` measures how often this is right.)
enum ZipFileNames {
    struct RawName {
        let bytes: Data
        /// General-purpose flag bit 11.
        let isMarkedUTF8: Bool
        /// Info-ZIP Unicode Path extra field (0x7075), already checked against `bytes`.
        let unicodePath: String?
        /// Made on Unix or macOS, where a backslash is an ordinary file-name character rather than a folder separator.
        var madeOnUnix = false
    }

    enum Legacy: CaseIterable {
        case gb18030, big5, shiftJIS, korean, westernDOS, cyrillicDOS

        var encoding: String.Encoding {
            let cf: CFStringEncodings = switch self {
            case .gb18030: .GB_18030_2000 // a superset of GBK and GB2312
            case .big5: .big5_HKSCS_1999
            case .shiftJIS: .dosJapanese // CP932, what Windows writes
            case .korean: .dosKorean // CP949, a superset of EUC-KR
            case .westernDOS: .dosLatin1 // CP850: Windows' OEM page in Western Europe and Latin America
            case .cyrillicDOS: .dosRussian // CP866
            }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
        }
    }

    /// Longer names aren't judged, only decoded: no real file name comes near, and judging is the slow part.
    private static let judgedNameBytes = 1_024
    /// How many bytes of names are judged at most. The rest of a huge archive is decoded the way its first names are.
    private static let judgedTotalBytes = 256 * 1_024
    /// Longer names aren't read as legacy text at all (macOS and iOS paths stop at 1,024 bytes, Windows' at 260
    /// characters): they are hostile.
    private static let decodedNameBytes = ZipArchive.maxNameBytes

    static func decode(_ names: [RawName], preferredLanguages: [String] = Locale.preferredLanguages)
        -> (names: [String], legacyEncoding: String.Encoding?) {
        decode(names, preferredLanguages: preferredLanguages, checkCancelled: {})
    }

    /// `checkCancelled` is called every thousand names; what it throws stops decoding.
    static func decode(_ names: [RawName], preferredLanguages: [String],
                       checkCancelled: () throws -> Void) rethrows -> (names: [String], legacyEncoding: String.Encoding?) {
        func undecided(_ name: RawName) -> Bool {
            !name.isMarkedUTF8 && name.unicodePath == nil && !name.bytes.allSatisfy { $0 < 0x80 }
        }
        let open = names.indices.filter { undecided(names[$0]) }
        var judged: [Int] = []
        var judgedBytes = 0
        for index in open where names[index].bytes.count <= judgedNameBytes {
            judgedBytes += names[index].bytes.count
            if judgedBytes > judgedTotalBytes { break }
            judged.append(index)
        }
        // Names that are surely UTF-8 stay UTF-8 whatever the rest of the archive is.
        let surely = Set(judged.filter { isSurelyUTF8([UInt8](names[$0].bytes)) })
        let legacyIndices = judged.filter { !surely.contains($0) }
        let legacyNames = legacyIndices.map { [UInt8](names[$0].bytes) }
        let invalid = open.filter { String(data: names[$0].bytes, encoding: .utf8) == nil }
        // An archive with names from Windows or DOS (none of its invalid UTF-8 from Unix), and a name made on Unix or
        // macOS: that name was added by another tool, in UTF-8 ("50°.png" added with macOS's zip to a GBK archive). It
        // takes no part in choosing the code page.
        let legacyFromWindows = open.contains { !names[$0].madeOnUnix } && invalid.allSatisfy { !names[$0].madeOnUnix }
        func addedOnUnix(_ index: Int) -> Bool { legacyFromWindows && names[index].madeOnUnix }
        var legacy: Legacy?
        if !invalid.isEmpty {
            // Names added on Unix take no part, and neither does another name that is valid UTF-8 and reads as text:
            // another tool may have added it ("Größe" in a Big5 archive). Counting it would weigh against the code
            // pages that can read its bytes and for those that can't.
            let invalidSet = Set(invalid)
            var required = legacyIndices.filter { index in
                !addedOnUnix(index) && (invalidSet.contains(index) || !looksLikeText(String(decoding: names[index].bytes, as: UTF8.self)))
            }
            // A valid UTF-8 name that none of the double-byte code pages reading the others well can decode would leave
            // only CP850 and CP866, which read anything ("墨.png", "(ˆˆ).png" added by another Windows tool): it is
            // decided on its own.
            let invalidRequired = required.filter(invalidSet.contains).map { [UInt8](names[$0].bytes) }
            let readers = [Legacy.gb18030, .big5, .shiftJIS, .korean].filter { page in
                guard !invalidRequired.isEmpty, let weights = Optional(invalidRequired.compactMap { plausibility(of: $0, as: page) }),
                      weights.count == invalidRequired.count, invalidRequired.allSatisfy({ decodeExactly($0, as: page) != nil })
                else { return false }
                let all = weights.flatMap { $0 }
                return !all.isEmpty && all.reduce(0, +) / Double(all.count) >= 0.6
            }
            if !readers.isEmpty {
                required = required.filter { index in
                    invalidSet.contains(index) || readers.contains { decodeExactly([UInt8](names[index].bytes), as: $0) != nil }
                }
            }
            legacy = detect((required.isEmpty ? legacyIndices : required).map { [UInt8](names[$0].bytes) },
                            preferredLanguages: preferredLanguages)?.legacy
        } else if !legacyNames.isEmpty {
            // All valid UTF-8, as Finder, zip and most tools write today. Switch only if most names don't read as text,
            // counting each folder once and words of an alphabet against it, and only to a code page that reads well
            // (Western and Cyrillic DOS text is rarely valid UTF-8, and their tables read UTF-8 CJK as letters, so those
            // need more). A lone letter or character is a name ("ñ", "в", "桜") rather than a misreading when made on
            // Unix or macOS, whose tools write UTF-8; Windows tools that write UTF-8 mark it, and unmarked they write the
            // legacy code page.
            var madeOnUnix: [Substring: Bool] = [:]
            for index in judged where !addedOnUnix(index) {
                for component in String(decoding: names[index].bytes, as: UTF8.self).split(separator: "/")
                where !component.allSatisfy(\.isASCII) {
                    madeOnUnix[component] = (madeOnUnix[component] ?? true) && names[index].madeOnUnix
                }
            }
            let reading = madeOnUnix.map { component, unix in
                (component, looksLikeText(String(component), lenient: unix))
            }
            let failing = reading.filter { !$0.1 }.count
            let words = reading.filter { $0.1 && hasWord(String($0.0)) }.count
            if failing * 2 > reading.count + 2 * words,
               let detected = detect(legacyIndices.filter { !addedOnUnix($0) }.map { [UInt8](names[$0].bytes) },
                                     preferredLanguages: preferredLanguages),
               detected.score >= ([.westernDOS, .cyrillicDOS].contains(detected.legacy) ? 0.9 : 0.8) {
                legacy = detected.legacy
            }
        }
        let judgedSet = Set(judged)
        let decoded = try names.indices.map { index -> String in
            if index % 1_000 == 999 { try checkCancelled() }
            let name = names[index]
            // A name longer than any file system allows is hostile: kept short, so nothing done with it later is slow.
            guard name.bytes.count <= decodedNameBytes, (name.unicodePath?.utf8.count ?? 0) <= decodedNameBytes else {
                return composed(String(decoding: (name.unicodePath.map { Data($0.utf8) } ?? name.bytes).prefix(decodedNameBytes),
                                       as: UTF8.self) + "…")
            }
            let text = name.unicodePath ?? (undecided(name)
                ? text(of: [UInt8](name.bytes), legacy: legacy, surelyUTF8: surely.contains(index),
                       judged: judgedSet.contains(index), addedOnUnix: addedOnUnix(index))
                : String(decoding: name.bytes, as: UTF8.self))
            // Windows tools sometimes separate folders with backslashes; macOS writes decomposed accents.
            return composed(name.madeOnUnix ? text : text.replacingOccurrences(of: "\\", with: "/"))
        }
        return (decoded, legacy?.encoding)
    }

    /// A name not marked UTF-8, in an archive whose legacy code page is `legacy` (nil for UTF-8). Only `judged` names
    /// are weighed one by one; the rest of a huge archive goes the archive's way.
    private static func text(of bytes: [UInt8], legacy: Legacy?, surelyUTF8: Bool, judged: Bool, addedOnUnix: Bool) -> String {
        let utf8 = String(bytes: bytes, encoding: .utf8)
        guard let legacy, bytes.count <= decodedNameBytes, let legacyText = decodeExactly(bytes, as: legacy) else {
            return utf8 ?? String(decoding: bytes.map { $0 < 0x80 ? $0 : UInt8(ascii: "_") }, as: UTF8.self)
        }
        guard let utf8 else { return legacyText }
        if surelyUTF8 || addedOnUnix { return utf8 }
        // Valid UTF-8 in a legacy archive is either a name another tool added or a short legacy name that happens to
        // be valid UTF-8 too. The first reads as text where the legacy reading doesn't, or as a word ("Größe") where
        // the legacy reading looks misread ("Gr枚脽e"; but "Tom猫" is a real name, not "Tomè").
        guard judged, looksLikeText(utf8) else { return legacyText }
        if !looksLikeText(legacyText) || hasWord(utf8, inner: true) && looksMisread(legacyText, as: legacy) { return utf8 }
        return legacyText
    }

    /// Whether a Chinese or Korean reading looks misread: a character that isn't an everyday one, or one inside a Latin
    /// word ("caf茅" is "café", "se帽or" is "señor"). Other code pages have no list of everyday characters to tell.
    private static func looksMisread(_ text: String, as legacy: Legacy) -> Bool {
        guard [.gb18030, .big5, .korean].contains(legacy) else { return true }
        let scalars = Array(text.unicodeScalars)
        func isASCIILetter(_ index: Int) -> Bool { scalars.indices.contains(index) && scalars[index].isASCII && isLetter(scalars[index]) }
        for (index, scalar) in scalars.enumerated() where !scalar.isASCII && isLetter(scalar) {
            if !FrequentCharacters.isEveryday(Character(scalar), in: legacy) { return true }
            if isASCIILetter(index - 1), isASCIILetter(index + 1) { return true }
        }
        return false
    }

    /// NFC, with runs of combining marks cut to 30: Unicode's limit for stream-safe text (UAX #15), which no name
    /// exceeds. Longer runs cost time quadratic in their length every time the name is normalized or compared.
    private static func composed(_ text: String) -> String {
        var run = 0
        guard text.unicodeScalars.contains(where: { run = isMark($0) ? run + 1 : 0; return run > 30 }) else {
            return text.precomposedStringWithCanonicalMapping
        }
        var kept = String.UnicodeScalarView()
        run = 0
        for scalar in text.unicodeScalars {
            run = isMark(scalar) ? run + 1 : 0
            if run <= 30 { kept.append(scalar) }
        }
        return String(kept).precomposedStringWithCanonicalMapping
    }

    /// Whether `text` has a word of three or more letters of one alphabet, at least one of them beyond ASCII ("più",
    /// "кабан"). Legacy bytes misread as UTF-8 make one letter per character, from scattered blocks, and rarely spell
    /// one. With `inner`, the word needs four letters and two different ones beyond ASCII, or one between plain letters
    /// ("Größe", "señor"): a Chinese character after a Latin word ("Tom猫") reads as a word ending in one accented
    /// letter, and a Korean syllable repeated ("큭큭큭큭") as one accented letter repeated.
    static func hasWord(_ text: String, inner: Bool = false) -> Bool {
        var word: [(scalar: Unicode.Scalar, beyond: Bool)] = []
        var alphabet = 0
        func isWord() -> Bool {
            let beyond = word.indices.filter { word[$0].beyond }
            guard !beyond.isEmpty else { return false }
            if !inner { return word.count >= 3 }
            return word.count >= 4 && (Set(beyond.map { word[$0].scalar }).count >= 2 || beyond.contains { index in
                index > 0 && index < word.count - 1 && !word[index - 1].beyond && !word[index + 1].beyond
            })
        }
        for scalar in text.unicodeScalars {
            if isMark(scalar), !word.isEmpty {
                word[word.count - 1].beyond = true // a decomposed accent
                continue
            }
            guard isLetter(scalar), scalar.value < 0x800 else {
                if isWord() { return true }
                word = []
                continue
            }
            let own = scalar.isASCII ? Script.latin : script(of: scalar.value)
            if !word.isEmpty, own != alphabet {
                if isWord() { return true }
                word = []
            }
            alphabet = own
            word.append((scalar, !scalar.isASCII))
        }
        return isWord()
    }

    /// Valid UTF-8 that reads as text, with characters past U+0800 that legacy bytes rarely form by accident: kana,
    /// Hangul, everyday hanzi, symbols and emoji, or words of another script. (Short CP866 words such as "раб" are valid
    /// UTF-8 too, for a single Samaritan letter, "так" for a Braille pattern and "ход" for an everyday hanzi; GBK can
    /// read as one rare hanzi.)
    private static func isSurelyUTF8(_ bytes: [UInt8]) -> Bool {
        guard bytes.contains(where: { $0 >= 0xE0 }), let text = String(bytes: bytes, encoding: .utf8), looksLikeText(text) else {
            return false
        }
        let scalars = Array(text.unicodeScalars)
        // Lengths of runs of scalars from the same 128-character block, for words of other scripts.
        var runs = [Int](repeating: 1, count: scalars.count)
        var start = 0
        for index in scalars.indices where index == scalars.count - 1 || scalars[index + 1].value >> 7 != scalars[index].value >> 7 {
            for member in start...index { runs[member] = index - start + 1 }
            start = index + 1
        }
        var han = 0, everyday = 0, others = 0
        for (index, scalar) in scalars.enumerated() where scalar.value >= 0x800 {
            switch scalar.value {
            // Symbols that names use (not Braille or the further math and arrows, where CP866 "т" lands).
            case 0x1100...0x11FF, 0x2000...0x27BF, 0x2900...0x297F, 0x2B00...0x2B2F, 0x2B50...0x2B59, 0x3000...0x30FF,
                 0x3130...0x318F, 0x31F0...0x31FF, 0xAC00...0xD7A3, 0xFE00...0xFE0F, 0xFF00...0xFFEF, 0x1F000...0x1FAFF:
                others += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
                han += 1
                if FrequentCharacters.isEveryday(Character(scalar)) { everyday += 1 }
            default:
                if runs[index] < 3 { return false }
            }
        }
        // One hanzi alone is three bytes, as many as a three-letter CP866 word ("ход" is also "室").
        return everyday * 2 >= han && (han >= 2 || others > 0 || han == 0)
    }

    // MARK: Choosing a legacy code page

    /// The legacy code page that decodes every name and reads most like real text, with its score: the average
    /// typicality of the non-ASCII characters, 0…1.
    static func detect(_ names: [[UInt8]], preferredLanguages: [String] = Locale.preferredLanguages,
                       among candidates: [Legacy] = Legacy.allCases) -> (legacy: Legacy, score: Double)? {
        guard !names.isEmpty else { return nil }
        var scored: [(legacy: Legacy, score: Double)] = []
        var texts: [Legacy: [String]] = [:]
        for legacy in order(for: preferredLanguages) where candidates.contains(legacy) {
            var total = 0.0, characters = 0
            var decoded: [String] = []
            var valid = true
            for name in names {
                guard let weights = plausibility(of: name, as: legacy), let text = decodeExactly(name, as: legacy) else {
                    valid = false
                    break
                }
                total += weights.reduce(0, +)
                characters += weights.count
                decoded.append(text)
            }
            if valid {
                scored.append((legacy, characters == 0 ? 0 : total / Double(characters)))
                texts[legacy] = decoded
            }
        }
        guard let best = scored.map(\.score).max() else { return nil }
        // GBK, Big5 and Korean share byte ranges, so the same bytes can be common characters in each: how much likelier
        // each reading is to be real than misread, from how many of its characters are everyday ones.
        var evidence: [Legacy: Double] = [:]
        for candidate in scored {
            evidence[candidate.legacy] = FrequentCharacters.evidence(in: texts[candidate.legacy] ?? [], for: candidate.legacy)
        }
        let tied = scored.filter { $0.score > best - 1e-9 }
        // Chinese and Korean readings close to the best are compared by evidence too, if they look real: a symbol or two
        // that one code page rates higher ("①" in a Korean name) says less than whether the letters are everyday ones.
        let bestIsCJK = tied.contains { evidence[$0.legacy] != nil }
        let ranked = scored.filter { $0.score > best - (bestIsCJK ? 0.15 : 1e-9) }
            .compactMap { candidate in evidence[candidate.legacy].map { (candidate: candidate, evidence: $0) } }
            .filter { entry in entry.evidence > 0 || tied.contains { $0.legacy == entry.candidate.legacy } }
            .sorted { $0.evidence > $1.evidence }
        // The code page of the user's own language wins when it reads nearly as well (as well, if its Chinese or Korean
        // reading looks misread itself, or if it is a Western or Cyrillic page against a double-byte reading where
        // every character is typical, as katakana is), unless another reading is likelier real by more than the odds
        // of an archive being in the user's language: high for Simplified Chinese (WeChat collections), moderate
        // otherwise (a Korean or Taiwanese user may well get a WeChat collection).
        if let own = userLegacy(preferredLanguages), let candidate = scored.first(where: { $0.legacy == own }), candidate.score >= 0.6 {
            let ownEvidence = evidence[own]
            let margin: Double
            if [.westernDOS, .cyrillicDOS].contains(own) {
                // Kana reads typical, and a Chinese or Korean reading counts if it also looks real.
                let typicalDoubleByte = scored.contains { candidate in
                    candidate.score >= 0.95 && (candidate.legacy == .shiftJIS || (evidence[candidate.legacy] ?? 0) > 0)
                }
                margin = typicalDoubleByte ? 1e-9 : 0.15
            } else {
                margin = (ownEvidence ?? 1) > 0 ? 0.15 : 1e-9
            }
            if candidate.score > best - margin {
                let odds = own == .gb18030 ? 20.0 : 5.0
                // For Simplified Chinese users the other reading must also be clearly the likeliest of the rest, as
                // for everyone else: rare hanzi can read as Korean and Big5 alike, and neither is convincing then.
                // Nor, for Simplified Chinese users, by one character alone ("疯" is also Korean "룩").
                if let ownEvidence, let strongest = ranked.first, strongest.candidate.legacy != own,
                   own != .gb18030 || Set((texts[strongest.candidate.legacy] ?? []).joined().filter { !$0.isASCII && $0.isLetter }).count >= 2,
                   strongest.evidence - ownEvidence > log(odds),
                   own != .gb18030 || ranked.dropFirst().allSatisfy({ entry in
                       entry.candidate.legacy == own || strongest.evidence - entry.evidence >= log(20)
                   }) {
                    return strongest.candidate
                }
                return candidate
            }
        }
        // Otherwise a tie goes to a reading 10 times likelier real than any other.
        if ranked.count > 1, ranked[0].evidence - ranked[1].evidence >= log(10) { return ranked[0].candidate }
        // A Chinese or Korean reading likelier misread than real loses a tie to a reading of another kind ("привет" in
        // CP866 also reads as three Big5 characters).
        if let first = tied.first, (evidence[first.legacy] ?? 1) <= 0, let other = tied.first(where: { evidence[$0.legacy] == nil }) {
            return other
        }
        return tied[0]
    }

    /// Candidates in tie-break order: the code page of the first of the user's languages that has one, then Simplified
    /// Chinese (WeChat collections), Western, Traditional Chinese, Japanese, Korean, Russian.
    static func order(for preferredLanguages: [String]) -> [Legacy] {
        var order: [Legacy] = [.gb18030, .westernDOS, .big5, .shiftJIS, .korean, .cyrillicDOS]
        if let preferred = userLegacy(preferredLanguages) {
            order.removeAll { $0 == preferred }
            order.insert(preferred, at: 0)
        }
        return order
    }

    /// The code page of the first of the user's languages that has one of its own.
    private static func userLegacy(_ preferredLanguages: [String]) -> Legacy? {
        preferredLanguages.lazy.compactMap { legacy(for: Locale.Language(identifier: $0)) }.first
    }

    private static func legacy(for language: Locale.Language) -> Legacy? {
        switch language.languageCode?.identifier {
        case "zh", "yue":
            // An explicit script wins: mainland users in Hong Kong run zh-Hans-HK and get GBK collections.
            switch language.script?.identifier {
            case "Hans": .gb18030
            case "Hant": .big5
            default: ["TW", "HK", "MO"].contains(language.region?.identifier ?? "") ? .big5 : .gb18030
            }
        case "ja": .shiftJIS
        case "ko": .korean
        case "ru", "uk", "be", "bg", "kk", "ky", "mk", "mn", "tg": .cyrillicDOS
        case "sr": language.script?.identifier == "Latn" ? nil : .cyrillicDOS
        // Western European languages: CP850. (English keeps the default order, led by WeChat's GBK.)
        case "de", "fr", "es", "pt", "it", "nl", "sv", "da", "nb", "nn", "no", "fi", "is", "ca", "gl", "eu", "ga", "af":
            .westernDOS
        default: nil
        }
    }

    /// `bytes` in `legacy`, only if it converts back to exactly the same bytes (some converters drop bytes they can't
    /// map instead of failing).
    static func decodeExactly(_ bytes: [UInt8], as legacy: Legacy) -> String? {
        if legacy == .gb18030, let euro = gbkEuroPositions(bytes), !euro.isEmpty {
            // CP936 (Windows' GBK) has a single-byte euro sign, 0x80, which GB18030 writes as A2 E3: read it as that, in
            // one pass.
            var swapped: [UInt8] = []
            swapped.reserveCapacity(bytes.count + euro.count)
            var start = 0
            for position in euro {
                swapped += bytes[start..<position]
                swapped += [0xA2, 0xE3]
                start = position + 1
            }
            swapped += bytes[start...]
            return decodeExactly(swapped, as: .gb18030)
        }
        let data = Data(bytes)
        guard let text = String(data: data, encoding: legacy.encoding), text.data(using: legacy.encoding) == data else {
            return nil
        }
        return text
    }

    /// Where 0x80 stands as a character of its own (not as a trail byte) in GBK text, or nil if the bytes aren't GBK.
    private static func gbkEuroPositions(_ bytes: [UInt8]) -> [Int]? {
        var positions: [Int] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x00...0x7F: index += 1
            case 0x80: positions.append(index); index += 1
            case 0xFF: return nil
            default:
                guard index + 1 < bytes.count else { return nil }
                index += (0x30...0x39).contains(bytes[index + 1]) ? 4 : 2
            }
        }
        return positions
    }

    // MARK: Reading as text

    /// Whether text decoded as UTF-8 reads like a real name: no unassigned, private-use or control characters, and
    /// letters from one writing system besides Latin (Japanese mixes kanji, kana and full-width letters; Korean may mix
    /// in hanja). GBK that happens to be valid UTF-8 comes out as unassigned code points or a jumble of Greek, Cyrillic
    /// and Hebrew.
    ///
    /// Two-byte UTF-8 (U+0080–U+07FF: accented Latin, Greek, Cyrillic, Hebrew, Arabic, Latin-1 signs) is also where a
    /// single GBK character lands by accident, as one lone letter or sign. A lone letter (or one letter repeated, as
    /// "猫猫" reads "èè" and "크크" reads "ũũ"; digits beside it don't help: "猫1" reads "è1") reads as text only as a word
    /// among others ("è vero", "в бане"); a run of signs only next to a letter, space or a
    /// digit before it ("¡¡Hola", "50°", but not "·1", which is "路1"), or as kaomoji interleaving Latin-1 signs and
    /// ASCII punctuation or mixing them with signs past U+0800 ("°_°", "^°^", "(´∀`)"). Braille and the further arrows
    /// and lone letters of alphabets past U+0800 are where 3- and 4-byte misreadings land, and follow the same rules;
    /// so does a name of one hanzi that isn't an everyday one. `lenient` skips the rules for lone letters, signs and
    /// hanzi, for names made where UTF-8 is the norm.
    static func looksLikeText(_ text: String, lenient: Bool = false) -> Bool {
        text.split(separator: "/").allSatisfy { looksLikeName(Array($0.unicodeScalars), lenient: lenient) }
    }

    /// Linear in the length of the name: archive names can be 64 KB.
    private static func looksLikeName(_ scalars: [Unicode.Scalar], lenient: Bool) -> Bool {
        // The part before an extension such as ".gif".
        let stemEnd = scalars.lastIndex(of: ".").flatMap { dot in
            scalars.count - dot - 1 <= 5 && scalars[(dot + 1)...].allSatisfy { $0.isASCII && $0.properties.isAlphabetic } ? dot : nil
        } ?? scalars.count
        let stemLetters = scalars[..<stemEnd].reduce(0) { $0 + (isLetter($1) ? 1 : 0) }
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.numericType == .decimal }
        func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .spaceSeparator }
        func isSign(_ scalar: Unicode.Scalar) -> Bool { !isLetter(scalar) && !isMark(scalar) && !isDigit(scalar) && !isSpace(scalar) }
        // Whether each run of signs within the stem touches a letter, mark, space or a digit before it.
        var signRunJoined = [Bool](repeating: false, count: scalars.count)
        var runStart = 0
        while runStart < stemEnd {
            guard isSign(scalars[runStart]) else { runStart += 1; continue }
            var runEnd = runStart
            while runEnd < stemEnd, isSign(scalars[runEnd]) { runEnd += 1 }
            let before = runStart > 0 ? scalars[runStart - 1] : nil, after = runEnd < stemEnd ? scalars[runEnd] : nil
            var joined = [before, after].contains { $0.map { isLetter($0) || isMark($0) || isSpace($0) } ?? false }
                || before.map(isDigit) == true
            // Kaomoji: Latin-1 signs (not the spacing modifiers a GBK character lands on, "˭?") alternating with ASCII
            // punctuation inside the run, or mixed with signs past U+0800 ("(´∀`)").
            let run = scalars[runStart..<runEnd]
            if !joined, run.allSatisfy({ $0.isASCII || $0.value >= 0x800 || (0xA1...0xFF).contains($0.value) }) {
                joined = run.contains { (0xA1...0xFF).contains($0.value) } && run.contains { $0.value >= 0x800 }
                    || (runStart..<runEnd).contains { index in
                        index > runStart && index + 1 < runEnd
                            && scalars[index].isASCII != scalars[index - 1].isASCII && scalars[index].isASCII != scalars[index + 1].isASCII
                    }
            }
            for index in runStart..<runEnd { signRunJoined[index] = joined }
            runStart = runEnd
        }
        // Words of the stem: runs of letters and marks. A run of one letter repeated counts as one letter alone, and so
        // does a short run of accented letters that turns capital in the middle ("ġŲ" is Korean "치킨").
        var wordOf = [Int](repeating: -1, count: scalars.count)
        var aloneWords = Set<Int>(), stemWords = 0
        var wordStart = 0
        while wordStart < scalars.count {
            guard isLetter(scalars[wordStart]) else { wordStart += 1; continue }
            var wordEnd = wordStart
            while wordEnd < scalars.count, isLetter(scalars[wordEnd]) || isMark(scalars[wordEnd]) { wordEnd += 1 }
            let letters = scalars[wordStart..<wordEnd].filter(isLetter)
            let turnsCapital = (2...3).contains(letters.count) && letters.allSatisfy { !$0.isASCII && $0.value < 0x800 }
                && zip(letters, letters.dropFirst()).contains { $0.properties.isLowercase && $1.properties.isUppercase }
            // (In Arabic or Hebrew, a letter written three times or more is a word, laughter such as "ههه"; twice, it is
            // a doubled GBK character as in any two-byte script: "转转" reads "תת". Scripts past U+0800, where GBK doesn't
            // land, write laughter doubled: "हाहा".)
            // (Modifier letters repeated are judged below, as kaomoji may write them: "(ˆˆ)".)
            let repeated = letters.allSatisfy { $0 == letters[0] } && !letters[0].isASCII
                && (letters.count == 1 || !isModifierLetter(letters[0].value) && letters[0].value < 0x800)
                && (letters.count <= 2 || letters[0].properties.isLowercase || letters[0].properties.isUppercase)
            if repeated || turnsCapital { aloneWords.insert(stemWords) }
            for index in wordStart..<wordEnd { wordOf[index] = stemWords }
            if wordStart < stemEnd { stemWords += 1 }
            wordStart = wordEnd
        }
        func isJoinedLetter(_ index: Int) -> Bool { !aloneWords.contains(wordOf[index]) }
        // Scripts of the words, and of letters standing alone between signs, as in Japanese kaomoji ("(^ω^)", "(´Д`)").
        var scripts = Set<Int>(), aloneScripts = Set<Int>()
        for (index, scalar) in scalars.enumerated() where !scalar.isASCII {
            switch scalar.properties.generalCategory {
            case .unassigned where (0x1F000...0x1FAFF).contains(scalar.value):
                continue // an emoji newer than this system's Unicode tables
            case .unassigned, .privateUse, .control, .surrogate:
                return false
            default:
                break
            }
            let before = index > 0 ? scalars[index - 1] : nil
            // Letters no name uses: archaic Cyrillic and Greek, Latin Extended-B and IPA beyond the few that languages
            // write (Vietnamese ơ ư, Romanian ș ț, pinyin tones, ə ɛ ɔ). Two-byte GBK misread as UTF-8 lands on them.
            if isRareLetter(scalar.value) { return false }
            // Two spacing modifier letters in a row, at the start or end of a name or next to a letter or digit ("ʵʱ1",
            // "OKʵʱ" are "实时1", "OK实时"): GBK lands there, names write one (ʻ, ʼ) at most. Kaomoji put them between
            // signs: "(ˇˍˇ)".
            if !lenient, isModifierLetter(scalar.value), let before, isModifierLetter(before.value),
               index < 2 || !isModifierLetter(scalars[index - 2].value) {
                var end = index + 1
                while end < scalars.count, isModifierLetter(scalars[end].value) { end += 1 }
                let start = index - 1
                let touchesWord = [start > 0 ? scalars[start - 1] : nil, end < scalars.count ? scalars[end] : nil]
                    .contains { $0.map { isLetter($0) && !isModifierLetter($0.value) || isDigit($0) } ?? false }
                if start == 0 || end >= stemEnd || touchesWord { return false }
            }
            if isMark(scalar) {
                // A combining mark belongs on a letter (as in macOS's decomposed "é"). Emoji presentation selectors and
                // the keycap mark follow symbols and digits ("❤️", "1️⃣"). Of the general diacritics, names use those
                // that make a letter in use when composed ("ț" from "t" and a comma below), and the common accents.
                if (0x0300...0x036F).contains(scalar.value), !Self.nameDiacritics.contains(scalar.value) {
                    let composed = before.map { String(String.UnicodeScalarView([$0, scalar])).precomposedStringWithCanonicalMapping }
                    guard let letter = composed?.unicodeScalars.first, composed?.unicodeScalars.count == 1,
                          !isRareLetter(letter.value) else { return false }
                }
                let emojiMark = (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
                    || scalar.value == 0x20E3
                guard let before, emojiMark || isLetter(before) || isMark(before) else { return false }
                // Hebrew points, Arabic vowels and the like belong to their own script's letters (the general
                // diacritics, U+0300–U+036F, go on any).
                if (0x0483..<0x0800).contains(scalar.value), isLetter(before), script(of: before.value) != script(of: scalar.value) {
                    return false
                }
                continue
            }
            let letter = isLetter(scalar)
            if letter {
                let own = script(of: scalar.value)
                if scalar.value < 0x800, !isJoinedLetter(index) { aloneScripts.insert(own) } else { scripts.insert(own) }
                // Two alphabets back to back ("ǹӢ") is a misreading; only CJK scripts mix inside a word.
                // (Names made on Unix may put a modifier letter in a Latin word: "Saʿīd".)
                if let before, !before.isASCII, isLetter(before),
                   !(lenient && (isModifierLetter(before.value) || isModifierLetter(scalar.value))) {
                    let previous = script(of: before.value)
                    let cjk: Set<Int> = [Script.han, Script.kana, Script.hangul, Script.fullwidthLatin]
                    if previous != own, !(cjk.contains(previous) && cjk.contains(own)) { return false }
                }
            }
            let ownScript = letter ? script(of: scalar.value) : 0
            // A name of one rare hanzi alone: real ones use everyday characters.
            if !lenient, letter, ownScript == Script.han, stemLetters == 1, !FrequentCharacters.isEveryday(Character(scalar)) {
                return false
            }
            let alphabetic = scalar.value < 0x800
                || letter && scalar.value < 0x2E80 && ![Script.han, Script.kana, Script.hangul].contains(ownScript)
            let misreadSign = !letter && (0x2800...0x2BFF).contains(scalar.value) && !Self.emojiArrows.contains(scalar.value)
            guard alphabetic || misreadSign else { continue }
            if letter {
                // Part of a word, or a one-letter word among other words.
                if !lenient, !isJoinedLetter(index), stemWords < 2 { return false }
            } else if !lenient, !isDigit(scalar), !signRunJoined[index] {
                return false
            }
        }
        // Letters standing alone count as words of their own, except Greek and Cyrillic ones among Japanese, Chinese or
        // Korean words, where kaomoji put them.
        let eastAsian: Set<Int> = [Script.han, Script.kana, Script.hangul]
        if !scripts.isDisjoint(with: eastAsian) { aloneScripts.subtract([Script.greek, Script.cyrillic]) }
        scripts.formUnion(aloneScripts)
        scripts.remove(Script.latin)
        scripts.remove(Script.fullwidthLatin)
        return scripts.count <= 1 || scripts == [Script.han, Script.kana] || scripts == [Script.han, Script.hangul]
    }

    /// Arrows and shapes past U+2800 that are emoji (⤴ ⤵ ⬅ ⬆ ⬇ ⬛ ⬜ ⭐ ⭕).
    private static let emojiArrows: Set<UInt32> = [0x2934, 0x2935, 0x2B05, 0x2B06, 0x2B07, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55]

    /// Accents names are written with, decomposed: grave, acute, circumflex, tilde, macron, breve, dot, diaeresis, hook,
    /// ring, double acute, caron, horn, dot below, cedilla, ogonek.
    private static let nameDiacritics: Set<UInt32> = [0x300, 0x301, 0x302, 0x303, 0x304, 0x306, 0x307, 0x308, 0x309, 0x30A,
                                                      0x30B, 0x30C, 0x31B, 0x323, 0x327, 0x328]

    /// Spacing modifier letters other than the ʻokina and the modifier apostrophe.
    private static func isModifierLetter(_ value: UInt32) -> Bool {
        (0x02B0...0x02FF).contains(value) && value != 0x02BB && value != 0x02BC
    }

    private static func isRareLetter(_ value: UInt32) -> Bool {
        switch value {
        case 0x0186, 0x018F, 0x0190, 0x0192, 0x01A0, 0x01A1, 0x01AF, 0x01B0, 0x01C4...0x01DC, 0x01E6, 0x01E7, 0x0218...0x021B,
             0x0254, 0x0259, 0x025B:
            false // used by Azerbaijani, Vietnamese, Croatian, pinyin, Romanian, African languages
        case 0x0180...0x02AF: true // the rest of Latin Extended-B and IPA
        case 0x0370...0x0385, 0x03CF...0x03FF: true // archaic Greek, Coptic
        case 0x0460...0x0489: true // historic Cyrillic letters and marks
        default: false
        }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    private enum Script {
        static let latin = -1, han = -2, kana = -3, hangul = -4, fullwidthLatin = -5
        static let greek = -6, cyrillic = -7, armenian = -8, hebrew = -9, arabic = -10
        static let tibetan = -11, myanmar = -12, georgian = -13, ethiopic = -14
        static let canadianSyllabics = -15, mongolian = -16, yi = -17, vai = -18
    }

    /// A writing system for a letter: the common ones by their blocks (some span several 128-character blocks), any
    /// other by its 128-character block.
    private static func script(of value: UInt32) -> Int {
        switch value {
        // With IPA and the modifier letters languages write (Hawaiian ʻokina, Uzbek ʼ); the other modifier letters are
        // where GBK lands ("女士" reads "Ůʿ").
        case 0x00C0...0x02AF, 0x02BB, 0x02BC, 0x1E00...0x1EFF: Script.latin
        case 0xFF21...0xFF3A, 0xFF41...0xFF5A: Script.fullwidthLatin
        case 0x2E80...0x2FDF, 0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: Script.han
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: Script.kana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF: Script.hangul
        case 0x0370...0x03FF, 0x1F00...0x1FFF: Script.greek
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: Script.cyrillic
        case 0x0530...0x058F, 0xFB13...0xFB17: Script.armenian
        case 0x0590...0x05FF, 0xFB1D...0xFB4F: Script.hebrew
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: Script.arabic
        case 0x0F00...0x0FFF: Script.tibetan
        case 0x1000...0x109F, 0xA9E0...0xA9FF, 0xAA60...0xAA7F: Script.myanmar
        case 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F: Script.georgian
        case 0x1200...0x139F, 0x2D80...0x2DDF: Script.ethiopic
        case 0x1400...0x167F, 0x18B0...0x18FF: Script.canadianSyllabics
        case 0x1800...0x18AF: Script.mongolian
        case 0xA000...0xA4CF: Script.yi
        case 0xA500...0xA63F: Script.vai
        default: Int(value >> 7)
        }
    }

    // MARK: Typical characters per code page

    /// CP850's accented letters.
    private static func isCP850Letter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x80...0x9B, 0x9D, 0xA0...0xA5, 0xB5...0xB7, 0xC6, 0xC7, 0xD0...0xD8, 0xDE, 0xE0...0xE5, 0xE7...0xED: true
        default: false
        }
    }

    /// CP850's accented capitals.
    private static let cp850Capitals: Set<UInt8> = [0x80, 0x8E, 0x8F, 0x90, 0x92, 0x99, 0x9A, 0x9D, 0xA5, 0xB5, 0xB6, 0xB7, 0xC7,
                                                    0xD1, 0xD2, 0xD3, 0xD4, 0xD6, 0xD7, 0xD8, 0xDE, 0xE0, 0xE2, 0xE3, 0xE5, 0xE8,
                                                    0xE9, 0xEA, 0xEB, 0xED]

    /// How typical each non-ASCII character of `bytes` is in `legacy` (1 = common, 0 = rare or symbol), or nil if the
    /// bytes aren't valid there.
    static func plausibility(of bytes: [UInt8], as legacy: Legacy) -> [Double]? {
        var weights: [Double] = []
        var index = 0
        var validUTF8: Bool?
        var asciiLetterBefore = false, previousJamo: UInt8?, previousBopomofo = false, previousSyllable = false
        func at(_ offset: Int) -> UInt8? { index + offset < bytes.count ? bytes[index + offset] : nil }
        func isASCIILetter(_ byte: UInt8?) -> Bool { byte.map { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) } ?? false }
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 {
                asciiLetterBefore = isASCIILetter(lead)
                previousJamo = nil
                previousBopomofo = false
                previousSyllable = false
                index += 1
                continue
            }
            let previous = index > 0 ? bytes[index - 1] : nil
            let afterASCIILetter = asciiLetterBefore, afterBopomofo = previousBopomofo, afterSyllable = previousSyllable
            asciiLetterBefore = false
            previousBopomofo = false
            previousSyllable = false
            if !(lead == 0xA4 && at(1).map({ (0xA1...0xD3).contains($0) }) == true) { previousJamo = nil }
            switch legacy {
            case .westernDOS:
                switch lead {
                case 0x80...0x9B, 0x9D, 0xA0...0xA5, 0xB5...0xB7, 0xC6, 0xC7, 0xD0...0xD8, 0xDE, 0xE0...0xE5, 0xE7...0xED:
                    // Accented letters: in Western names they sit next to plain letters ("café", "São", "Größe"), in
                    // the same case or after a capital. A run of them, or a small letter before a capital ("öLç@"), is
                    // more likely double-byte text, such as kanji, read one byte at a time.
                    func isLower(_ byte: UInt8?) -> Bool { byte.map { (0x61...0x7A).contains($0) } ?? false }
                    func isUpper(_ byte: UInt8?) -> Bool { byte.map { (0x41...0x5A).contains($0) } ?? false }
                    // A small one before a capital or "@" ("Rç@" is "コ①") is no Western letter either.
                    let capital = cp850Capitals.contains(lead)
                    let beforeCapital = !capital && (isUpper(at(1)) || at(1) == 0x40)
                    let afterLetter = isASCIILetter(previous) && !(isLower(previous) && capital) && !beforeCapital
                    let beforeLetter = isASCIILetter(at(1)) && !beforeCapital
                    weights.append(afterLetter || beforeLetter ? 1 : 0.5)
                case 0xA8, 0xAD:
                    // ¿ and ¡ open a Spanish sentence, right before its first letter, sometimes doubled ("¡¡Hola!!").
                    var end = index + 1
                    while end < bytes.count, [0xA8, 0xAD].contains(bytes[end]) { end += 1 }
                    let next = end < bytes.count ? bytes[end] : nil
                    weights.append(contentsOf: repeatElement(isASCIILetter(next) || next.map(Self.isCP850Letter) == true ? 1 : 0.3,
                                                             count: end - index))
                    index = end
                    continue
                case 0x9C, 0x9E, 0x9F, 0xA6, 0xA7, 0xA9...0xAC, 0xAE, 0xAF, 0xB8, 0xBD, 0xBE, 0xCF, 0xE6, 0xF1, 0xF3...0xFA:
                    weights.append(0.3) // £ × ƒ ª º ® ½ « » © ¢ ¥ ¤ µ ± ¾ ¶ § ÷ ° ·
                default:
                    weights.append(0) // box drawing
                }
                index += 1

            case .cyrillicDOS:
                func isCyrillic(_ byte: UInt8) -> Bool { (0x80...0xAF).contains(byte) || (0xE0...0xF7).contains(byte) }
                guard isCyrillic(lead) else {
                    weights.append(0) // box drawing, signs
                    index += 1
                    continue
                }
                // Russian words are runs of these. A run glued to Latin letters is Western accented letters read as
                // Cyrillic ("cafВ" is "café", "GrФсe" is "Größe" in CP850); one letter alone is a one-letter word
                // ("в") or a misreading.
                // Double-byte text read one byte at a time alternates small letters and capitals: UTF-8 (lead bytes
                // small, continuation bytes capital), Shift_JIS ("ВдВё" is "うん") and Big5 ("лЇлЇ" is "拜拜").
                func isSmall(_ byte: UInt8) -> Bool { (0xA0...0xAF).contains(byte) || (0xE0...0xEF).contains(byte) || [0xF1, 0xF3, 0xF5, 0xF7].contains(byte) }
                var end = index
                var mixed = false
                while end < bytes.count, isCyrillic(bytes[end]) {
                    // A small letter that starts the run or follows a capital, then a capital ("уБ", "уБВуВК"); CamelCase
                    // has a small letter before ("ДобройНочи").
                    if end > index, isSmall(bytes[end - 1]), !isSmall(bytes[end]), end - 1 == index || !isSmall(bytes[end - 2]) {
                        mixed = true
                    }
                    end += 1
                }
                // CamelCase with short words does it too ("ТыМоя", "НуПогоди"): words that each start with a capital,
                // one of them three letters or more (one small letter may lead a long word: "вКонтакте"), or one word
                // of two repeated ("ХаХа", "МиМиМи": А to Ч, as Shift_JIS symbols and kana lead with Б, В and Г, and
                // level-2 kanji and GBK's last rows with Ш to Я and Ё). Double-byte text makes words of two letters, and repeats them for
                // one character doubled; UTF-8 isn't CamelCase.
                if mixed {
                    if validUTF8 == nil { validUTF8 = String(bytes: bytes, encoding: .utf8) != nil }
                    var words: [Int] = [] // lengths
                    for (offset, byte) in bytes[index..<end].enumerated() {
                        if offset == 0 || !isSmall(byte) { words.append(1) } else { words[words.count - 1] += 1 }
                    }
                    let leadingSmall = isSmall(bytes[index])
                    let repeatedPair = !leadingSmall && words.count >= 2 && words.allSatisfy { $0 == 2 }
                        && (0x80...0x97).contains(bytes[index]) && ![0x81, 0x82, 0x83].contains(bytes[index])
                        && stride(from: index, to: end, by: 2).allSatisfy { bytes[$0] == bytes[index] && bytes[$0 + 1] == bytes[index + 1] }
                    let camelCase = leadingSmall ? words.count > 1 && words[0] == 1 && words[1] >= 4
                        : words.contains { $0 >= 3 } || repeatedPair
                    mixed = validUTF8 == true || !camelCase
                }
                let glued = isASCIILetter(previous) || isASCIILetter(end < bytes.count ? bytes[end] : nil)
                let weight = mixed ? 0.1 : glued ? 0.3 : end - index > 1 ? 1 : 0.5
                weights.append(contentsOf: repeatElement(weight, count: end - index))
                index = end

            case .gb18030:
                if lead == 0x80 {
                    weights.append(0.8) // CP936's euro sign
                    index += 1
                    continue
                }
                guard (0x81...0xFE).contains(lead), let second = at(1) else { return nil }
                if (0x30...0x39).contains(second) {
                    guard let third = at(2), let fourth = at(3), (0x81...0xFE).contains(third), (0x30...0x39).contains(fourth)
                    else { return nil }
                    weights.append(0)
                    index += 4
                    continue
                }
                guard (0x40...0x7E).contains(second) || (0x80...0xFE).contains(second) else { return nil }
                switch (lead, second) {
                case (0xB0...0xF7, 0xA1...0xFE): weights.append(1) // GB2312 hanzi
                case (0xA1, 0xA1...0xFE), (0xA3, 0xA1...0xFE): weights.append(0.8) // punctuation, full-width forms
                case (0xA2, 0xA1...0xFE): weights.append(0.4)
                // Greek, Cyrillic, box drawing and GBK's added symbols: kaomoji ("(╥﹏╥)", "(ಥ_ಥ)", "(´Д`)").
                case (0xA6, 0xA1...0xFE), (0xA7, 0xA1...0xFE), (0xA9, 0xA1...0xFE), (0xA8...0xA9, 0x40...0xA0): weights.append(0.4)
                default: weights.append(0) // GBK extensions, kana
                }
                index += 2

            case .big5:
                guard (0x81...0xFE).contains(lead), let second = at(1),
                      (0x40...0x7E).contains(second) || (0xA1...0xFE).contains(second) else { return nil }
                func isBopomofo(_ lead: UInt8?, _ trail: UInt8?) -> Bool {
                    lead == 0xA3 && trail.map { (0x74...0x7E).contains($0) || (0xA1...0xBA).contains($0) } == true
                }
                let nextIsBopomofo = isBopomofo(at(2), at(3))
                defer { previousBopomofo = isBopomofo(lead, second) }
                var weight: Double = switch (lead, second) {
                case (0xA4...0xC5, _), (0xC6, 0x40...0x7E): 1 // frequently used characters
                case (0xC9...0xF9, _): 0.5 // less frequently used characters
                case (0xA1, _): 0.8 // punctuation
                // Bopomofo, as Taiwanese chat writes it ("ㄏㄏ", "好ㄉ", "ㄘㄨㄚ"): the initials fully; the rest share
                // bytes with GBK's and Korean's full-width punctuation and digits ("（1）", "！"), so only next to more
                // bopomofo.
                case (0xA3, 0x74...0x7E): 1
                case (0xA3, 0xA1...0xAF): afterBopomofo || nextIsBopomofo ? 1 : 0.5
                case (0xA3, 0xB0...0xBA): 0.5
                case (0xA2, _): 0.4
                default: 0
                }
                // CP850's ¡ and ¿ opening a Spanish word ("胄ola" is "¡Hola", "限Hola" is "¡¡Hola"), or a character inside a
                // Latin word ("se寸r" is "señor"): Chinese names put characters before and after words ("愛you"), not
                // inside them.
                let opening = [0xA8, 0xAD].contains(lead)
                    && (isASCIILetter(second) && at(2).map { (0x61...0x7A).contains($0) } == true
                        || [0xA8, 0xAD].contains(second) && isASCIILetter(at(2)))
                let inside = afterASCIILetter && isASCIILetter(second) && at(2).map { (0x61...0x7A).contains($0) } == true
                if opening || inside { weight = min(weight, 0.5) }
                weights.append(weight)
                index += 2

            case .shiftJIS:
                if (0xA1...0xDF).contains(lead) {
                    weights.append(0.2) // half-width katakana
                    index += 1
                    continue
                }
                guard (0x81...0x9F).contains(lead) || (0xE0...0xFC).contains(lead), let second = at(1),
                      (0x40...0x7E).contains(second) || (0x80...0xFC).contains(second) else { return nil }
                switch (lead, second) {
                case (0x81, 0x5B): weights.append(1) // ー, part of katakana words
                case (0x81, _): weights.append(0.8) // punctuation
                case (0x82, 0x9F...0xF1), (0x83, 0x40...0x96): weights.append(1) // hiragana, katakana
                case (0x82, _): weights.append(0.6) // full-width digits and letters
                case (0x88, 0x9F...), (0x89...0x97, _), (0x98, ...0x72): weights.append(1) // level-1 kanji
                case (0x87, 0x40...0x9C): weights.append(0.8) // NEC specials: circled numbers, Roman numerals, ㈱
                case (0x98, 0x9F...), (0x99...0x9F, _), (0xE0...0xEA, _): weights.append(0.5) // level-2 kanji
                case (0xED...0xEE, _), (0xFA...0xFC, _): weights.append(0.5) // NEC and IBM extended kanji
                default: weights.append(0)
                }
                index += 2

            case .korean:
                guard (0x81...0xFE).contains(lead), let second = at(1),
                      (0x41...0x5A).contains(second) || (0x61...0x7A).contains(second) || (0x81...0xFE).contains(second)
                else { return nil }
                switch (lead, second) {
                case (0xB0...0xC8, 0xA1...0xFE):
                    weights.append(1) // KS X 1001 Hangul
                    previousSyllable = true
                case (0xA4, 0xA1...0xD3):
                    // Jamo on their own, as chat writes laughter, tears and short answers ("ㅋㅋ", "ㅠㅠ", "ㅗㅜㅑ"). A
                    // consonant next to a vowel would have been typed as a syllable: "ㅅㅡ" is Big5's "今天".
                    func isVowel(_ trail: UInt8) -> Bool { trail >= 0xBF }
                    let next = at(2) == 0xA4 ? at(3).flatMap { (0xA1...0xD3).contains($0) ? $0 : nil } : nil
                    let composable = [previousJamo, next].contains { $0.map { isVowel($0) != isVowel(second) } ?? false }
                    weights.append(composable ? 0 : 1)
                    previousJamo = second
                    index += 2
                    continue
                case (0x81...0xC6, ...0xA0): weights.append(0.6) // the other Hangul syllables (CP949)
                case (0xA1, 0xA1...0xFE): weights.append(0.8) // punctuation, ★ ☆
                case (0xA2, 0xA1...0xFE): weights.append(0.4) // symbols such as ♥ and ♡
                case (0xA3, 0xA1...0xFE):
                    // Full-width forms beside a syllable, as typical as in GBK ("（토닥）", "마늘！"); among other
                    // signs they are more likely a GBK kaomoji.
                    let nextIsSyllable = at(2).map { (0xB0...0xC8).contains($0) } == true && at(3).map { $0 >= 0xA1 } == true
                    weights.append(afterSyllable || nextIsSyllable ? 0.8 : 0.6)
                case (0xA8...0xA9, 0xA1...0xFE): weights.append(0.6) // circled ①, ㉠
                case (0xCA...0xFD, 0xA1...0xFE): weights.append(0.3) // hanja
                default: weights.append(0)
                }
                index += 2
            }
        }
        return weights
    }
}
