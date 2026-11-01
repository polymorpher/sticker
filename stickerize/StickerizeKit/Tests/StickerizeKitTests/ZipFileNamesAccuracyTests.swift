import Foundation
@testable import StickerizeKit
import XCTest

/// How often legacy-encoded names come out right, on thousands of generated names, decoded for users of different
/// languages. One name alone in an archive is the hard case; a real collection of a handful of names is easier.
///
/// Two Chinese corpora bracket real sticker names: "everyday" names use the frequent characters the decoder itself
/// knows (`FrequentCharacters`), which is what sticker names mostly are; "any level-1" names draw uniformly from all
/// 3,755 level-1 GB2312 hanzi, rare ones included. Where the same bytes read equally well in two code pages, the
/// user's language decides, so a lone short name in another script can come out wrong; those floors are lower.
final class ZipFileNamesAccuracyTests: XCTestCase {
    func testSimplifiedChineseFromWindows() {
        let everyday = words(FrequentCharacters.simplified.sorted(), count: 3000, length: 1...4)
        for language in ["en-US", "zh-Hans-CN", "ja-JP"] {
            XCTAssertGreaterThan(accuracy(everyday, .GB_18030_2000, language), 0.995, language)
        }
        // A lone name in GBK can read just as well as Korean or Big5, and those users' own code page then wins.
        XCTAssertGreaterThan(accuracy(everyday, .GB_18030_2000, "ko-KR"), 0.92)
        XCTAssertGreaterThan(accuracy(everyday, .GB_18030_2000, "zh-Hant-TW"), 0.92)

        // Rare hanzi alone can read as everyday Big5 or Korean, which then wins.
        let anyLevel1 = words(Self.gb2312Level1, count: 3000, length: 1...4)
        XCTAssertGreaterThan(accuracy(anyLevel1, .GB_18030_2000, "en-US"), 0.9)
        for language in ["en-US", "ko-KR", "zh-Hant-TW"] {
            XCTAssertGreaterThan(accuracy(anyLevel1, .GB_18030_2000, language, perArchive: 5), 0.99, language)
        }
        // Simplified Chinese users do at least as well as others on their own code page.
        XCTAssertGreaterThanOrEqual(accuracy(anyLevel1, .GB_18030_2000, "zh-Hans-CN"), accuracy(anyLevel1, .GB_18030_2000, "en-US"))

        // Latin words and characters mixed ("Tom猫", "猫doge"), as WeChat names often are.
        let latin = ["Tom", "cat", "LINE", "QQ", "Hello", "baby", "Kitty", "abc", "A", "OK"]
        let mixed = everyday.prefix(1000).map { next(2) == 0 ? latin[next(latin.count)] + $0 : $0 + latin[next(latin.count)] }
        for language in ["zh-Hans-CN", "en-US"] {
            XCTAssertGreaterThan(accuracy(mixed, .GB_18030_2000, language), 0.9, language)
            XCTAssertGreaterThan(accuracy(mixed, .GB_18030_2000, language, perArchive: 5), 0.99, language)
        }
    }

    func testTraditionalChinese() {
        // Some chat characters (囧, 嗝, 瞅) are in Big5's less frequent block.
        let everyday = words(FrequentCharacters.simplified.sorted(), count: 3000, length: 1...4).map(traditional)
        XCTAssertGreaterThan(accuracy(everyday, .big5_HKSCS_1999, "zh-Hant-TW"), 0.993)
        XCTAssertGreaterThan(accuracy(everyday, .big5_HKSCS_1999, "en-US"), 0.92)
        XCTAssertGreaterThan(accuracy(everyday, .big5_HKSCS_1999, "ru-RU"), 0.87)
        let anyLevel1 = words(Self.gb2312Level1, count: 3000, length: 1...4).map(traditional)
        XCTAssertGreaterThan(accuracy(anyLevel1, .big5_HKSCS_1999, "en-US", perArchive: 5), 0.99)
    }

    func testJapanese() {
        let names = (0..<3000).map { _ in
            String((0..<(1 + next(5))).map { _ in next(3) == 0 ? Self.kanji[next(Self.kanji.count)] : Self.kana[next(Self.kana.count)] })
        }
        XCTAssertGreaterThan(accuracy(names, .dosJapanese, "ja-JP"), 0.995)
        XCTAssertGreaterThan(accuracy(names, .dosJapanese, "en-US"), 0.92)
        XCTAssertGreaterThan(accuracy(names, .dosJapanese, "ru-RU"), 0.84)
        XCTAssertGreaterThan(accuracy(names, .dosJapanese, "en-US", perArchive: 5), 0.99)
        // Katakana bytes read as CP850 letters next to plain letters, which a Western user's own code page mustn't win.
        let katakana = (0..<3000).map { _ in String((0..<(2 + next(4))).map { _ in Self.kana[Self.kana.firstIndex(of: "ア")! + next(48)] }) }
        for language in ["ja-JP", "de-DE", "fr-FR"] {
            XCTAssertGreaterThan(accuracy(katakana, .dosJapanese, language, perArchive: 5), 0.99, language)
        }
    }

    func testKorean() {
        XCTAssertGreaterThan(accuracy(Self.korean, .dosKorean, "ko-KR"), 0.98)
        XCTAssertGreaterThan(accuracy(Self.korean, .dosKorean, "en-US"), 0.85)
        XCTAssertGreaterThan(accuracy(Self.korean, .dosKorean, "en-US", perArchive: 5), 0.99)
    }

    func testWestern() {
        for language in ["en-US", "pt-BR", "de-DE", "zh-Hans-CN", "ru-RU", "ko-KR"] {
            XCTAssertEqual(accuracy(Self.western, .dosLatin1, language), 1, language)
        }
        XCTAssertGreaterThan(accuracy(Self.western, .dosLatin1, "ja-JP"), 0.75)
        XCTAssertGreaterThan(accuracy(Self.western, .dosLatin1, "zh-Hant-TW"), 0.8)
        // Spanish names that open with ¡ or ¿.
        let spanish = (0..<500).map { _ in Self.spanish[next(Self.spanish.count)] }
        for language in ["es-ES", "en-US", "zh-Hant-TW"] {
            XCTAssertEqual(accuracy(spanish, .dosLatin1, language, perArchive: 5), 1, language)
        }
    }

    func testRussian() {
        for language in ["ru-RU", "en-US", "zh-Hans-CN", "ja-JP"] {
            XCTAssertEqual(accuracy(Self.russian, .dosRussian, language), 1, language)
        }
        XCTAssertGreaterThan(accuracy(Self.russian, .dosRussian, "zh-Hant-TW"), 0.9)
    }

    // MARK: Generating names

    private var state: UInt64 = 777

    private func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }

    private func words(_ alphabet: [Character], count: Int, length: ClosedRange<Int>) -> [String] {
        (0..<count).map { _ in
            String((0..<(length.lowerBound + next(length.count))).map { _ in alphabet[next(alphabet.count)] })
        }
    }

    private func traditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    /// The share of archives (of `perArchive` names each, as Windows writes them) whose names all decode exactly.
    private func accuracy(_ names: [String], _ encoding: CFStringEncodings, _ language: String, perArchive: Int = 1) -> Double {
        let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        var right = 0, total = 0
        for start in stride(from: 0, through: names.count - perArchive, by: perArchive) {
            let group = names[start..<start + perArchive].map { $0 + ".gif" }
            let raw = group.compactMap { $0.data(using: stringEncoding) }
            guard raw.count == group.count else { continue } // a character the code page doesn't have
            let decoded = ZipFileNames.decode(raw.map { .init(bytes: $0, isMarkedUTF8: false, unicodePath: nil) },
                                              preferredLanguages: [language]).names
            total += 1
            if decoded == group { right += 1 }
        }
        return Double(right) / Double(max(total, 1))
    }

    /// GB2312's 3,755 level-1 hanzi (rows B0–D7), in code order.
    private static let gb2312Level1: [Character] = {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return (0xB0...0xD7).flatMap { lead in
            (0xA1...0xFE).compactMap { trail in String(data: Data([UInt8(lead), UInt8(trail)]), encoding: encoding)?.first }
        }.filter { $0.isLetter }
    }()

    private static let korean = ["고양이", "강아지", "안녕하세요", "감사합니다", "사랑해", "좋아요", "화이팅", "대박", "헐", "웃음",
                                 "눈물", "축하해", "생일축하", "행복해", "귀여워", "맛있다", "미안해", "고마워", "보고싶어", "잘자", "굿밤",
                                 "최고", "짱", "멋져", "예뻐", "배고파", "졸려", "피곤해", "힘내", "응원해", "기분좋아", "아침", "점심",
                                 "저녁", "오늘", "내일", "친구", "엄마", "아빠", "언니", "오빠", "누나", "동생", "싫어", "몰라", "진짜",
                                 "우와", "헉", "흑흑", "어떡해", "괜찮아", "안돼", "제발", "부탁해", "축하합니다", "새해복많이받으세요",
                                 "메리크리스마스", "수고했어", "잘했어", "화났어", "무서워", "놀랐어", "심심해", "바빠", "기다려", "가자",
                                 "먹자", "자자", "놀자", "출근", "퇴근", "주말", "여행", "커피", "치킨", "맥주", "떡볶이", "라면", "김치"]
    private static let western = ["café", "über", "niño", "Müller", "naïve", "smörgåsbord", "Größe", "jalapeño", "crème brûlée",
                                  "Ångström", "façade", "señor", "Zürich", "Köln", "Málaga", "déjà vu", "Ægir", "piñata", "Ärger",
                                  "résumé", "Gödel", "fiancé", "mañana", "Ölfarbe", "coração", "não", "São Paulo", "Søren",
                                  "København", "À BIENTÔT", "pão de queijo", "ação", "Ótimo", "ÉTÉ", "Île-de-France", "Ñandú", "Øl",
                                  "smørrebrød", "bom dia irmão", "Ação de Graças"]
    private static let spanish = ["¡Hola!", "¡Feliz cumpleaños!", "¡Ánimo!", "¡Buenas noches!", "¡Gracias!", "¿Qué?", "¡Adiós!",
                                  "Mañana", "Niño", "Señor", "Año Nuevo", "¡Olé!", "¿Cómo estás?", "¡Qué bien!"]
    private static let russian = ["привет", "кот", "котики", "спокойной ночи", "доброе утро", "спасибо", "люблю тебя", "ура",
                                  "смешно", "мем", "пёс", "Москва", "в бане", "ну и ну", "жесть", "огонь", "класс", "пока", "да",
                                  "нет", "Котики/Спокойной ночи"]
    private static let kana = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんがぎぐげござじずぜぞだでどばびぶべぼぱぴぷぺぽアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンガギグゲゴザジズゼゾダデドバビブベボパピプペポー")
    private static let kanji = Array("猫犬日本人大中小山川田上下月火水木金土年時分今何私好愛笑泣怒顔目口手足心気元天雨雪花草木森林海空雲星夜朝昼晩春夏秋冬東西南北左右前後外内国語学校先生友達家族父母兄弟姉妹子供男女")
}
