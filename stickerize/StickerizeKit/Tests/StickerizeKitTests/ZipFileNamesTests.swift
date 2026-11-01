import Foundation
@testable import StickerizeKit
import StickerizeTestSupport
import XCTest

/// File-name decoding cases from real archives: what Finder, Windows and other tools write, and the ways a decoder can
/// confuse them.
final class ZipFileNamesTests: XCTestCase {
    // MARK: UTF-8 archives must stay UTF-8

    /// Finder's Compress and `zip` write UTF-8 without a flag. Accented and Cyrillic names, one-letter words included,
    /// are made of 2-byte sequences that GBK can also read.
    func testUnflaggedUTF8FromAMacStaysUTF8() {
        let archives = [
            ["è vero.png", "perché no.png", "caffè.png", "buongiorno.png"],
            ["à bientôt.png", "très bien.png", "génial.png", "café.png"],
            ["é isso.png", "você.png", "até logo.png"],
            ["в бане.png", "кабан.png", "баба.png"],
            ["café.png", "crème.png", "génial.png", "très.png", "élève.png", "fête.png", "rêve.png", "bébé.png", "été.png",
             "je t'aime ❤️.png"],
            ["1️⃣ first.png", "☺️.png", "✌️ peace.png", "🏳️‍🌈.png", "naïve.png"],
            ["Ölfarbe/Größe.png", "Ærø/smørrebrød.png"],
            // One-letter names among plain ones.
            ["ciao.png", "grazie.png", "è.png", "sì.png"],
            // Words without a plain letter: Turkish, Icelandic, Vietnamese.
            ["Günaydın.png", "üç kedi.png"], ["Üç kedi/1.png", "Üç kedi/2.png"], ["Þú ert frábær.png", "Takk.png"],
            ["đó.png", "đã xong.png"],
            // Runs of signs.
            ["¡¡Hola!!.png", "Buenos días.png"], ["¿¿Qué??.png", "¡¡¡Feliz cumpleaños!!!.png", "«¡Hola!».png"],
            // Persian, Urdu, Armenian (letters past U+0680 or U+0580), and Arabic-Indic and Persian digits.
            ["شب بخیر.png", "صبح بخیر.png", "تبریک.png"], ["شکریہ.png", "کتاب.png"], ["Բարեւ.png", "Բարի գիշեր.png"],
            ["١.png", "٢.png", "٣.png"], ["۱.png", "۲.png", "۳.png"], ["استیکر ۱.png", "استیکر ۲.png"], ["١٢.png", "١٣.png"],
            // Full-width letters in Japanese ("lol").
            ["ありがとうｗ.png", "おはよう.png"], ["ＯＫです.png", "ＬＩＮＥスタンプ.png"],
            // A one-letter folder counts once; words count against lone letters.
            ["è/caffè.png", "è/perché.png", "è/buongiorno.png"], ["в/кабан.png", "в/баба.png"],
            ["è.png", "à.png", "caffè.png"], ["é-1.png", "é-2.png", "café.png"], ["в.png", "с.png", "кабан.png"],
            // Kaomoji: Latin-1 signs with ASCII punctuation, Greek letters among Japanese.
            ["happy.png", "sad.png", "°_°.png", "(×_×).png"], ["(¬_¬).png", "hello.png"],
            ["ありがとう(^ω^).png", "よろしくお願いします(^ω^).png", "おやすみ.png"],
            // Inuktitut: Canadian syllabics span several blocks. Hawaiian: the ʻokina is a modifier letter.
            ["ᐃᓄᒃᑎᑐᑦ.png", "ᐊᐃᓐᖓᐃ.png"], ["Hawaiʻi.png", "ʻāina.png", "Kūʻokoʻa.png"], ["Saʿīd.png"], ["(ˇˍˇ).png"],
            // Three-letter words count against lone letters too.
            ["è.png", "é.png", "più.png"], ["ñ/ñ.png", "ñ/año.png"],
        ]
        for names in archives {
            let raw = names.map { utf8($0) }
            for language in ["en-US", "zh-Hans-CN", "ko-KR"] {
                let decoded = ZipFileNames.decode(raw, preferredLanguages: [language])
                XCTAssertEqual(decoded.names, names, language)
                XCTAssertNil(decoded.legacyEncoding, language)
            }
        }
    }

    /// macOS writes names decomposed: Romanian "ț" is "t" and a comma below.
    func testDecomposedNamesFromAMac() {
        let names = ["La mult\u{326}i ani.png", "Mult\u{326}umesc.png", "Pes\u{326}te.png", "S\u{326}oricel.png", "Mersi.png"]
        for language in ["ro-RO", "en-US", "zh-Hans-CN"] {
            let decoded = ZipFileNames.decode(names.map { utf8($0) }, preferredLanguages: [language])
            XCTAssertEqual(decoded.names, names.map(\.precomposedStringWithCanonicalMapping), language)
            XCTAssertNil(decoded.legacyEncoding, language)
        }
    }

    /// A lone accented letter is ambiguous with a lone GBK character ("è" and "猫" are the same bytes), and so is a
    /// lone hanzi with a CP866 word ("桜" and "цбЬ"). Made on a Mac or Linux, where tools write UTF-8, it is a letter or
    /// a hanzi; unmarked from Windows, whose tools mark the UTF-8 they write, it is a legacy character, numbered or not.
    func testLoneLettersAndCharacters() {
        let mac = [["ñ.png"], ["ü.png", "ö.png", "ä.png"], ["в.png"], ["я.png", "ю.png"], ["ç.png", "ğ.png", "ı.png"],
                   ["è.png", "ò.png", "sì.png"], ["é_1.png", "é_2.png"], ["桜.png"], ["桜/1.png", "桜/2.png"],
                   ["碍.png", "碑.png", "奔.png"], ["颤.png", "袁.png"], ["亀.png"], ["夕.png"], ["駅.png", "様.png", "桃.png"],
                   ["(*´▽`*).png"], ["(°□°).png"], ["(´∀`).png"], ["°.png"]]
        for names in mac {
            for language in ["en-US", "ja-JP", "zh-Hans-CN", "ru-RU", "de-DE"] {
                let decoded = ZipFileNames.decode(names.map { utf8($0) }, preferredLanguages: [language])
                XCTAssertEqual(decoded.names, names, language)
                XCTAssertNil(decoded.legacyEncoding, language)
            }
        }
        let windows = [["木.gif", "母.gif", "牛.gif", "女.gif", "魔.gif"], ["木.gif", "女.gif"], ["一.gif", "也.gif", "要.gif"],
                       ["一.gif"], ["说1.gif", "说2.gif", "说3.gif"], ["说-1.gif", "说-2.gif"], ["猫1.gif", "猫2.gif", "猫3.gif"],
                       ["女1.gif", "女2.gif", "女3.gif"], ["猫01.gif", "猫02.gif"], ["1猫.gif", "2猫.gif"], ["猫猫/1.gif", "猫猫/2.gif"],
                       ["毛毛1.gif", "毛毛2.gif"], ["路1.gif", "路2.gif"], ["鹿1.gif", "鹿2.gif", "鹿3.gif"],
                       // Doubled characters whose bytes are a Hebrew or Arabic letter twice ("转转" is "תת").
                       ["转转.gif"], ["爪爪.gif"], ["装装.gif"], ["倩倩.gif"],
                       // Characters whose bytes are two modifier letters, numbered.
                       ["实时1.gif", "实时2.gif"], ["水水_01.gif", "水水_02.gif"], ["爽爽1.gif"]]
        for names in windows {
            for language in ["zh-Hans-CN", "en-US", "de-DE", "fr-FR", "ru-RU"] {
                XCTAssertEqual(decode(names, .GB_18030_2000, language), names, language)
            }
        }
    }

    /// Names another tool added to a legacy archive in UTF-8 stay UTF-8; legacy names that happen to be valid UTF-8 stay
    /// legacy.
    func testMixedArchives() {
        let gbkNames = ["开心.gif", "微笑.gif"].map { raw(Array($0.data(using: gbk)!)) }
        let added = ["café.png", "Größe.png", "señor.png", "вино.png", "καφές.png"].map { utf8($0) }
        XCTAssertEqual(ZipFileNames.decode(gbkNames + added, preferredLanguages: ["en-US"]).names,
                       ["开心.gif", "微笑.gif", "café.png", "Größe.png", "señor.png", "вино.png", "καφές.png"])
        // CP866 "так" and "топ" are valid UTF-8 too, for a Braille pattern and an arrow.
        let russian = ["привет.png", "так.png", "топ.png", "спасибо.png", "там.png"]
        for language in ["ru-RU", "en-US"] {
            XCTAssertEqual(decode(russian, .dosRussian, language), russian, language)
        }
        // One UTF-8 name doesn't rule out the archive's own code page.
        let addedToLegacy: [([String], CFStringEncodings, String, [String])] = [
                     (["開心.gif", "謝謝老闆.png", "生氣.png"], .big5_HKSCS_1999, "Größe.png", ["zh-Hant-TW", "en-US"]),
                     (["안녕하세요.png", "감사합니다.gif", "사랑해.gif"], .dosKorean, "привет.png", ["ko-KR", "en-US"]),
                     (["ネコ.png", "イヌ.png", "ウサギ.png"], .dosJapanese, "voilà.png", ["ja-JP", "en-US"])]
        for (legacyNames, cf, utf8Name, languages) in addedToLegacy {
            for unix in [false, true] {
                let raws = legacyNames.map { raw(Array($0.data(using: Self.encoding(cf))!)) } + [raw(Array(utf8Name.utf8), unix: unix)]
                for language in languages {
                    XCTAssertEqual(ZipFileNames.decode(raws, preferredLanguages: [language]).names, legacyNames + [utf8Name], language)
                }
            }
        }
        // A name another Windows tool added in UTF-8 (unmarked, same host) doesn't change how the others read, and laughter
        // in a script without case is a word.
        let sameHost: [([String], CFStringEncodings, String)] = [
            (["开心.png", "表情包.png"], .GB_18030_2000, "привет.png"), (["来了.gif", "狗.gif", "机智.gif", "抱抱.gif"], .GB_18030_2000, "ПриветМир.png"),
            (["开心.gif", "晚安.gif"], .GB_18030_2000, "Ευχαριστώ.png"), (["开心.gif"], .GB_18030_2000, "שלום.png"),
            (["ネコ.png", "イヌ.png"], .dosJapanese, "ёжик.png"), (["Größe.png", "Grüße.png", "Straße.png"], .dosLatin1, "привет.png"),
            (["고양이.gif", "사랑해.gif"], .dosKorean, "мама.gif"), (["等等.gif", "好熱.gif"], .big5_HKSCS_1999, "חחח.png"),
            (["ありがとう.gif", "おはよう.gif", "おやすみ.gif", "ネコ.gif"], .dosJapanese, "ههه.png"),
            // Names no double-byte code page reads: they don't leave the archive to CP850 or CP866.
            (["开心.gif", "晚安.gif", "谢谢.gif", "哈哈.gif"], .GB_18030_2000, "墨.png"), (["開心.gif", "晚安.gif", "謝謝.gif", "哈哈.gif"], .big5_HKSCS_1999, "瓜.png"),
            (["고양이.gif", "사랑해.gif", "고마워.gif", "안녕.gif"], .dosKorean, "梨.png"), (["开心.gif", "晚安.gif"], .GB_18030_2000, "鑫.png"),
            (["失礼します.gif"], .dosJapanese, "(ˆˆ).jpg"), (["太棒了.gif", "累爆.gif", "惡魔.gif"], .big5_HKSCS_1999, "(ˆˆ).gif"),
            (["기다릴게.gif", "좋은아침.gif"], .dosKorean, "(ˆˆ).gif"),
            // Indic and Thai laughter is written doubled; GBK doesn't land there.
            (["开心.gif", "晚安.gif", "谢谢.gif"], .GB_18030_2000, "हाहा.png"), (["開心.gif", "晚安.gif"], .big5_HKSCS_1999, "อิอิ.png")]
        for (legacyNames, cf, added) in sameHost {
            let raws = legacyNames.map { raw(Array($0.data(using: Self.encoding(cf))!)) } + [raw(Array(added.utf8))]
            for language in ["en-US", "zh-Hans-CN", "de-DE", "ru-RU"] {
                XCTAssertEqual(Array(ZipFileNames.decode(raws, preferredLanguages: [language]).names.prefix(legacyNames.count)), legacyNames,
                               "\(added) \(language)")
            }
        }
        // Names macOS's zip added to a Windows archive, which wouldn't read as text from Windows.
        let macAdded: [([String], CFStringEncodings, String, [String])] = [
            (["开心.png", "表情包.png", "哈哈哈.png"], .GB_18030_2000, "(°□°).png", ["en-US", "zh-Hans-CN", "ja-JP"]),
            (["开心.png", "表情包.png", "哈哈哈.png"], .GB_18030_2000, "(*´▽`*).png", ["en-US", "zh-Hans-CN"]),
            (["开心.png", "表情包.png", "哈哈哈.png"], .GB_18030_2000, "桜.png", ["en-US", "zh-Hans-CN"]),
            (["ネコ.png", "イヌ.png", "ありがとう.png"], .dosJapanese, "桜.png", ["ja-JP", "en-US"]),
            (["開心.png", "謝謝老闆.png", "生氣.png"], .big5_HKSCS_1999, "(°□°).png", ["zh-Hant-TW", "en-US"]),
            (["안녕하세요.png", "사랑해.png", "고마워.png"], .dosKorean, "(´∀`).png", ["ko-KR", "en-US"]),
            (["兄弟.png", "震惊.png"], .GB_18030_2000, "好ㄉ.png", ["en-US", "zh-Hans-CN"]),
            (["好的.png", "贴贴.png", "打工人.png", "恭喜发财.png"], .GB_18030_2000, "(ﾟДﾟ).png", ["en-US", "zh-Hans-CN"]),
            (["Olé.png", "crème brûlée.png", "naïve.png"], .dosLatin1, "(ʘ‿ʘ).png", ["en-US", "fr-FR"])]
        // The same where every Windows name happens to be valid UTF-8 too ("чай" is "砩"): the Mac's name doesn't vote.
        let macAddedToValid: [([String], CFStringEncodings, String, [String])] = [
            (["чай.gif", "сад.gif"], .dosRussian, "Müller.png", ["en-US", "ru-RU"]),
            (["说.gif", "模式.gif"], .GB_18030_2000, "naïve.png", ["en-US", "zh-Hans-CN"]),
            (["캬캬캬캬.gif", "큭큭큭큭.gif"], .dosKorean, "jalapeño.png", ["ko-KR", "en-US"])]
        for (legacyNames, cf, utf8Name, languages) in macAdded + macAddedToValid {
            let raws = legacyNames.map { raw(Array($0.data(using: Self.encoding(cf))!)) } + [utf8(utf8Name)]
            for language in languages {
                XCTAssertEqual(ZipFileNames.decode(raws, preferredLanguages: [language]).names, legacyNames + [utf8Name], language)
            }
        }
        // Names macOS's zip added to a Windows GBK archive, however short.
        let short = ["50°.png", "été.png", "año.png", "ça va.png", "Zoë.png", "è vero.png", "né.png", "мир.png", "кот.png", "да.png", "øl.png"]
        let windows = ["开心.gif", "表情包.gif"].map { raw(Array($0.data(using: gbk)!)) }
        for language in ["en-US", "zh-Hans-CN", "de-DE"] {
            XCTAssertEqual(ZipFileNames.decode(windows + short.map { utf8($0) }, preferredLanguages: [language]).names,
                           ["开心.gif", "表情包.gif"] + short, language)
        }
    }

    /// Real GBK, Korean and Big5 names mixing Latin letters and characters stay so, even where they are valid UTF-8 that
    /// reads as a word ("Tom猫" is also "Tomè").
    func testLatinMixedWithChineseOrKorean() {
        let archives: [([String], CFStringEncodings)] = [
            (["开心.gif", "微笑.gif", "Tom猫.gif", "猫doge.gif", "每happy.gif", "QQ猫猫.gif", "谢谢谢谢.gif", "cat猫.gif", "Kitty猫.gif"], .GB_18030_2000),
            (["안녕.png", "크크크크.png", "사랑해.png"], .dosKorean),
            (["開心.gif", "Tom羅.gif"], .big5_HKSCS_1999),
            (["안녕.png", "큭큭큭큭.png"], .dosKorean), (["안녕.png", "킥킥킥킥.png"], .dosKorean),
        ]
        for (names, cf) in archives {
            for language in ["zh-Hans-CN", "en-US", "ko-KR", "zh-Hant-TW"] {
                XCTAssertEqual(decode(names, cf, language), names, language)
            }
        }
        // Taiwanese names put English words after characters ("愛you"); GBK characters whose bytes are modifier letters
        // in UTF-8 don't make a Latin word ("女士" isn't "Ůʿ").
        let more: [([String], CFStringEncodings, [String])] = [
            (["愛you.gif"], .big5_HKSCS_1999, ["zh-Hant-TW"]), (["大愛you.gif"], .big5_HKSCS_1999, ["zh-Hant-TW"]),
            (["另good.gif"], .big5_HKSCS_1999, ["zh-Hant-TW"]), (["超cute.gif"], .big5_HKSCS_1999, ["zh-Hant-TW", "yue-Hant-HK"]),
            (["超讚.gif", "超cute.gif", "小baby.gif"], .big5_HKSCS_1999, ["zh-Hant-TW"]),
            (["小cute.gif", "小pig.gif", "超cute.gif"], .big5_HKSCS_1999, ["zh-Hant-TW"]),
            (["女士.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]), (["模式.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]),
            (["墨水.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]), (["谋士.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]),
            (["女士.gif", "模式.gif", "墨水.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]),
            (["开心.gif", "寞士帽茂.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]),
            (["OK实时.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]), (["实时.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]),
            (["LOL史恕.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]), (["Hello刷水.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"]),
            (["开心.gif", "OK藝藥.gif"], .GB_18030_2000, ["en-US", "zh-Hans-CN"])]
        for (names, cf, languages) in more {
            for language in languages {
                XCTAssertEqual(decode(names, cf, language), names, language)
            }
        }
        // A GBK character with ASCII punctuation, in an archive of names that are all valid UTF-8, isn't a kaomoji.
        for name in ["谁?.gif", "说!.gif", "睡~.gif", "(帅).gif", "路!.gif", "楼?.gif"] {
            for language in ["zh-Hans-CN", "en-US"] {
                XCTAssertEqual(decode([name], .GB_18030_2000, language), [name], language)
            }
        }
    }

    // MARK: Ambiguous Chinese and Korean

    /// GB2312 hanzi in rows B0–C8 (pinyin a to q) are also valid, common-looking KS X 1001 Hangul and Big5. A small
    /// WeChat collection of 哈哈哈 and 可爱 must stay Chinese for anyone who doesn't read Korean or Traditional Chinese.
    func testSmallChineseCollectionsStayChinese() {
        let archives = [["哈哈哈.gif", "哈哈哈哈.gif", "可爱.gif"], ["狗狗.gif", "狗狗狗.gif", "哈哈哈.gif"],
                        ["哈哈哈哈哈哈哈哈.gif"], ["好的.gif", "可爱.gif", "哈哈.gif"], ["哈哈哈.gif"]]
        for names in archives {
            for language in ["en-US", "ja-JP", "zh-Hans-CN", "zh-Hans-HK", "zh-Hans-MO", "ko-KR", "en-HK"] {
                XCTAssertEqual(decode(names, .GB_18030_2000, language), names, language)
            }
        }
        // Everyday words whose bytes are also Korean or Big5, some valid UTF-8 too ("猫猫" is "èè"). (Where both readings
        // are everyday words, the Korean or Big5 one may win: "夸夸" is "요요", and 夸 isn't counted as everyday so that
        // "좋아요" stays Korean.)
        let common = [["玫瑰.gif"], ["桃.gif"], ["猫猫.gif", "毛毛.gif"], ["没没.gif", "开心.gif"], ["滑滑梯.gif"]]
        for names in common {
            for language in ["en-US", "zh-Hans-CN", "ja-JP"] {
                XCTAssertEqual(decode(names, .GB_18030_2000, language), names, language)
            }
        }
        for (names, cf) in [(["좋아요.gif"], CFStringEncodings.dosKorean), (["괜찮아요.gif"], .dosKorean), (["치즈.gif", "엄마.gif", "카톡.gif"], .dosKorean),
                            (["초코.gif", "엄마.gif"], .dosKorean), (["乾飯.gif"], .big5_HKSCS_1999), (["謝謝.gif", "睡覺.gif"], .big5_HKSCS_1999)] {
            for language in ["en-US", "de-DE", "ja-JP"] {
                XCTAssertEqual(decode(names, cf, language), names, language)
            }
        }
        // One character alone doesn't overrule a Simplified Chinese user's own code page ("疯" is also Korean "룩").
        for name in ["疯.gif", "曹.gif", "播.gif", "暖.gif", "仁.gif"] {
            XCTAssertEqual(decode([name], .GB_18030_2000, "zh-Hans-CN"), [name])
        }
        // These bytes are everyday Korean too (漂亮 is 특좋): Korean for someone who reads Korean, Chinese for the rest.
        for names in [["漂亮.gif"], ["泪.gif"], ["哎哎哎.gif", "嘛.gif"], ["蝴蝶.gif"]] {
            for language in ["en-US", "ja-JP", "zh-Hans-CN", "zh-Hans-HK", "en-HK"] {
                XCTAssertEqual(decode(names, .GB_18030_2000, language), names, language)
            }
        }
    }

    func testKoreanWordsAreKoreanForEveryone() {
        let archives = [["고양이.png"], ["안녕하세요.png", "감사합니다.gif"], ["사랑해.gif", "좋아요.png", "대박.gif"],
                        ["친구.gif", "엄마.gif", "아빠.gif"]]
        for names in archives {
            for language in ["ko-KR", "en-US", "ja-JP"] {
                XCTAssertEqual(decode(names, .dosKorean, language), names, language)
            }
        }
    }

    /// Chat writes jamo on their own (laughter, tears) and decorates names with ♥ or circled numbers.
    func testKoreanChatNames() {
        let archives = [["카톡/ㅋㅋㅋ.png", "카톡/ㅠㅠ.png", "카톡/헐.png", "카톡/대박.png", "카톡/사랑해♥.png"],
                        ["사랑해♥.png", "고마워.png", "안녕.png", "잘자.png", "굿밤.png"], ["①안녕.png", "②고마워.png", "③사랑해.png"],
                        ["고양이_ㅋㅋ.png", "고양이_ㅠㅠ.png", "고양이_헐.png", "고양이_굿밤.png"]]
        for names in archives {
            for language in ["ko-KR", "en-US", "ja-JP", "zh-Hans-CN"] {
                XCTAssertEqual(decode(names, .dosKorean, language), names, language)
            }
        }
        // Other jamo next to a word, and syllables whose bytes are valid UTF-8 ("치킨" is "ġŲ", "크크" is "ũũ").
        for names in [["ㅁㅊ.png", "안녕.png"], ["ㄹㅇ.png", "대박.png"], ["ㅗㅜㅑ.png", "대박.png"], ["카카.gif", "펭귄.gif"],
                      ["치킨.gif"], ["크크.gif"], ["카카.gif"]] {
            XCTAssertEqual(decode(names, .dosKorean, "ko-KR"), names)
        }
        for language in ["ko-KR", "en-US", "zh-Hans-CN"] {
            XCTAssertEqual(decode(["치킨.gif", "크크.gif", "토끼.gif"], .dosKorean, language), ["치킨.gif", "크크.gif", "토끼.gif"], language)
        }
    }

    func testTraditionalChineseIsBig5() {
        let archives = [["開心.gif", "貓咪表情/哈哈哈.png"], ["謝謝老闆.png"], ["讚.gif", "抱抱.gif", "生氣.png"]]
        for names in archives {
            for language in ["zh-Hant-TW", "en-US", "yue-Hant-HK"] {
                XCTAssertEqual(decode(names, .big5_HKSCS_1999, language), names, language)
            }
        }
        // Bopomofo in Taiwanese chat.
        for names in [["好ㄉ.png", "ㄏㄏ.png", "ㄎㄎ.png"], ["ㄅㄅ.png"], ["ㄇㄉ.png"], ["ㄊㄇㄉ.png"], ["ㄇㄉ.png", "ㄅㄅ.png"],
                      ["ㄘㄨㄚ.png"], ["ㄙㄨㄚ.png"], ["ㄨㄚ.png"]] {
            XCTAssertEqual(decode(names, .big5_HKSCS_1999, "zh-Hant-TW"), names)
        }
        XCTAssertEqual(decode(["好ㄉ.png", "ㄏㄏ.png", "ㄎㄎ.png"], .big5_HKSCS_1999, "en-US"), ["好ㄉ.png", "ㄏㄏ.png", "ㄎㄎ.png"])
        // Single characters whose bytes are also lone jamo, and GBK full-width digits whose bytes are also bopomofo.
        for names in [["凶.gif"], ["凶凶.gif"], ["匹.gif"]] {
            XCTAssertEqual(decode(names, .big5_HKSCS_1999, "zh-Hant-TW"), names)
        }
        for names in [["１.gif", "２.gif", "３.gif"], ["１２３.gif"]] {
            XCTAssertEqual(decode(names, .GB_18030_2000, "zh-Hant-TW"), names)
        }
        // GBK kaomoji: full-width signs among Greek, Cyrillic and box drawing, not Korean.
        for names in [["o(╥﹏╥)o.png", "(*^▽^*).png", "饿死了（1）.gif"], ["(*￣3￣)╭.png", "(*/ω＼*).jpg", "求求了.gif"], ["(=￣ω￣=).gif"]] {
            for language in ["en-US", "zh-Hans-CN", "ko-KR"] {
                XCTAssertEqual(decode(names, .GB_18030_2000, language), names, language)
            }
        }
        // Bopomofo shares bytes with GBK's and Korean's full-width punctuation, which Chinese and Korean typing uses.
        for (names, cf) in [((1...5).map { "大佬（\($0)）.gif" }, CFStringEncodings.GB_18030_2000), (["可怜（1）.gif", "锦鲤！！.gif", "堵车（猫）.gif"], .GB_18030_2000),
                            (["（吃饱了）.gif"], .GB_18030_2000), (["打你！.gif", "好的！.gif"], .GB_18030_2000),
                            (["마늘！.gif", "（토닥）.gif", "천사！.gif", "라쿤（2）.gif", "건배！.gif"], .dosKorean)] {
            // (A numbered pack is as ambiguous as its name alone: "大佬" is everyday Korean too.)
            for language in ["en-US", "zh-Hans-CN", "ko-KR", "zh-Hant-TW"]
            where !(cf == .dosKorean && language == "zh-Hant-TW") && !(names.count == 5 && cf == .GB_18030_2000 && language == "ko-KR") {
                XCTAssertEqual(decode(names, cf, language), names, language)
            }
        }
    }

    /// Katakana and numbered packs in Shift_JIS, for Japanese users and others. Katakana bytes read as CP850 letters
    /// next to plain letters ("âlâR"), which a Western user's own code page mustn't win with.
    func testJapaneseNames() {
        // Hiragana and kanji read one byte at a time as CP866 make two-letter "words" ("うん" is "ВдВё"), not Russian.
        for names in [["うん.gif"], ["かわいい.gif"], ["頑張れ.gif"], ["きらきら.gif", "わくわく.gif"], ["もぐもぐ.gif", "かわいい.gif", "いいえ.gif"],
                      ["(°□°).png", "ありがとう.png"], ["(´Д`).png", "それな.gif", "よろしく.gif", "おはよう.gif", "おかえり.gif"]] {
            for language in ["ru-RU", "ja-JP", "en-US"] {
                XCTAssertEqual(decode(names, .dosJapanese, language), names, language)
            }
        }
        for names in [["拜拜.gif", "休.gif", "旺柴.gif"]] {
            for language in ["ru-RU", "en-US", "zh-Hant-TW"] {
                XCTAssertEqual(decode(names, .big5_HKSCS_1999, language), names, language)
            }
        }
        // Doubled symbols lead with 0x81, which CP866 reads as "Б": not Russian laughter.
        for names in [["→→.gif", "←←.gif"], ["※※.gif"]] {
            for language in ["ja-JP", "en-US", "ru-RU"] {
                XCTAssertEqual(decode(names, .dosJapanese, language), names, language)
            }
        }
        // A lone katakana name ties with CP850 letters for others ("ハッピー" is also "ânâbâsü["); Japanese users get it.
        for name in ["ラーメン.gif", "ハッピー.gif", "ピーナッツ.gif"] {
            XCTAssertEqual(decode([name], .dosJapanese, "ja-JP"), [name])
        }
        let archives = [["ネコ.png", "イヌ.png", "ウサギ.png", "パンダ.png", "クマ.png"],
                        ["スタンプ/ネコ①.png", "スタンプ/ネコ②.png", "スタンプ/ネコ③.png"], ["猫①.png", "猫②.png", "猫③.png", "猫④.png", "猫⑤.png"],
                        (1...5).map { "ネコ\(["①", "②", "③", "④", "⑤"][$0 - 1]).png" },
                        (1...5).map { "イヌ\(["①", "②", "③", "④", "⑤"][$0 - 1]).png" },
                        (1...5).map { "ハート\(["①", "②", "③", "④", "⑤"][$0 - 1]).png" }]
        for names in archives {
            for language in ["ja-JP", "en-US", "de-DE", "fr-FR", "zh-Hans-CN", "ko-KR", "ru-RU"] {
                XCTAssertEqual(decode(names, .dosJapanese, language), names, language)
            }
        }
    }

    // MARK: Western and Cyrillic DOS code pages

    /// Windows' built-in ZIP writes the OEM code page: CP850 in Western Europe and Latin America, where letters such
    /// as ã, õ, ø and the accented capitals sit where CP437 has box drawing.
    func testWesternEuropeanAndLatinAmericanNames() {
        let archives = [["coração.png", "não.png", "São Paulo.png"], ["Søren.png", "København.png"], ["À BIENTÔT.png"],
                        ["pão de queijo.gif", "ação.gif"], ["über.gif", "café.png", "niño.gif", "Müller.png"]]
        for names in archives {
            for language in ["pt-BR", "da-DK", "fr-FR", "en-US"] {
                XCTAssertEqual(decode(names, .dosLatin1, language), names, language)
            }
        }
        // Spanish exclamations start with ¡, which mustn't read as a Big5 character running into the word.
        let spanish = [["¡Hola!.png", "¡Feliz cumpleaños!.png", "¡Ánimo!.png", "¡Buenas noches!.png", "¡Gracias!.png"],
                       ["Mañana.gif", "Niño.gif", "Señor.gif", "Año Nuevo.gif", "¡Hola!.gif"], ["¡Hola!.png"],
                       ["¡¡Feliz cumpleaños!!.png", "¡¡Hola!!.png", "¡¡Gracias!!.png"], ["¡¡Feliz!!.png"]]
        for names in spanish {
            for languages in [["es-ES"], ["es-MX"], ["de-DE", "ja-JP"], ["en-US"], ["zh-Hant-TW"]] {
                XCTAssertEqual(ZipFileNames.decode(names.map { raw(Array($0.data(using: Self.encoding(.dosLatin1))!)) },
                                                   preferredLanguages: languages).names, names, "\(languages)")
            }
        }
    }

    func testRussianNames() {
        let archives = [["привет.png", "кот.png"], ["Котики/Спокойной ночи.gif"], ["в бане.png", "Ура!.gif"],
                        // CamelCase.
                        ["ДобройНочи.png", "СНовымГодом.png", "ПриветМир.png"], ["ТикТок.png"],
                        // Words that are also valid UTF-8 for one character: Braille, an arrow, a rare hanzi.
                        ["так.png"], ["чай.png", "сад.png", "рад.png", "так.png"], ["тем.png", "тег.png", "той.png", "тон.png", "том.png"],
                        ["Ёжик.png"], ["Ёлка.png"],
                        // CamelCase with two-letter words, which UTF-8 read as CP866 looks like ("уБ"), but isn't UTF-8.
                        ["НуПогоди.png"], ["ТыМоя.png"], ["ДоСвидания.png"], ["вКонтакте.png"],
                        ["НуПогоди.png", "ТыМоя.png", "НеТрогай.png", "ДаНет.png", "ЯНеЗнаю.png"],
                        // A syllable repeated, as laughter.
                        ["Что.png", "ХаХа.png"], ["Ахахах.png", "МиМиМи.png"]]
        for names in archives {
            for language in ["ru-RU", "uk-UA", "en-US"] {
                XCTAssertEqual(decode(names, .dosRussian, language), names, language)
            }
        }
    }

    // MARK: Details

    /// CP936, Windows' GBK, writes the euro sign as the single byte 0x80, which GB18030 alone wouldn't accept.
    func testGBKEuroSign() {
        let names = [Array("哈哈哈.gif".data(using: gbk)!), Array("开心".data(using: gbk)!) + [0x80] + Array(".png".utf8)]
        let decoded = ZipFileNames.decode(names.map { raw($0) }, preferredLanguages: ["en-US"])
        XCTAssertEqual(decoded.names, ["哈哈哈.gif", "开心€.png"])
        for language in ["zh-Hans-CN", "en-US"] {
            let alone = Array("东".data(using: gbk)!) + [0x80] + Array(".png".utf8)
            XCTAssertEqual(ZipFileNames.decode([raw(alone)], preferredLanguages: [language]).names, ["东€.png"], language)
        }
    }

    /// A German archive for someone who reads German first and Japanese too: CP850, not Shift_JIS.
    func testWesternUsersWithAnAsianSecondLanguage() {
        let names = ["Größe.png", "Grüße.png", "Schöne Grüße.png", "Frühstück.png"]
        XCTAssertEqual(decode(names, .dosLatin1, "de-DE", "ja-JP"), names)
    }

    /// Short Russian words can be valid UTF-8 for one rare character ("раб" is a Samaritan letter); in a CP866 archive
    /// they are Russian.
    func testShortRussianWordsThatAreAlsoValidUTF8() {
        let names = ["раб.png", "привет.png", "кот.png"]
        XCTAssertNotNil(String(data: names[0].data(using: Self.encoding(.dosRussian))!, encoding: .utf8))
        XCTAssertEqual(decode(names, .dosRussian, "ru-RU"), names)
    }

    /// A 64 KB name must not take long to judge.
    func testVeryLongNamesAreFast() {
        let long = "a" + String(repeating: "é", count: 21_000) + ".png"
        let started = Date()
        _ = ZipFileNames.decode([utf8(long), utf8("à " + String(repeating: "à ", count: 10_000) + ".png")])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// Judging names is linear, and a hostile archive of huge names is judged by a sample: 12 MB of names that aren't
    /// UTF-8, and names with thousands of combining marks, which are quadratic to normalize.
    func testHostileNamesAreFast() {
        let started = Date()
        let long = (0..<200).map { index in raw(Array(repeating: [0x80, 0xC4, 0xE3] as [UInt8], count: 20_000).flatMap { $0 } + Array("\(index).png".utf8)) }
        _ = ZipFileNames.decode(long)
        // Euro signs make GBK decode piece by piece unless done in one pass; one real GBK name makes the archive GBK.
        let euros = [raw(Array("开心.gif".data(using: gbk)!))]
            + (0..<2000).map { index in raw(Array(repeating: [0x31, 0x80] as [UInt8], count: 490).flatMap { $0 } + Array(".\(index)".utf8)) }
        XCTAssertEqual(ZipFileNames.decode(euros).legacyEncoding, Self.encoding(.GB_18030_2000))
        // Runs of marks are cut to the 30 of stream-safe text, so comparing and splitting the name later is cheap too;
        // names longer than macOS allows are cut short.
        for (count, suffix) in [(200, ".png"), (16_000, "…")] {
            let marks = "a" + String(repeating: "\u{301}\u{316}", count: count) + ".png"
            let decoded = ZipFileNames.decode((0..<20).map { _ in .init(bytes: Data(marks.utf8), isMarkedUTF8: true, unicodePath: nil) })
            XCTAssertEqual(decoded.names.first?.hasSuffix(suffix), true)
            XCTAssertLessThanOrEqual(decoded.names.first?.unicodeScalars.count ?? .max, 1 + 30 + 4)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    /// On macOS and Linux a backslash is part of a name (kaomoji such as (\_/)); only Windows tools mean a folder.
    func testBackslashesSeparateFoldersOnlyInWindowsArchives() {
        let name = Array("(\\_:).gif".utf8)
        XCTAssertEqual(ZipFileNames.decode([raw(name, unix: true)]).names, ["(\\_:).gif"])
        XCTAssertEqual(ZipFileNames.decode([raw(name, unix: false)]).names, ["(/_:).gif"])
    }

    /// The everyday traditional characters are the simplified ones converted one by one, the same in every process
    /// (converted together, some depend on their neighbours, whose order would vary).
    func testEverydayTraditionalCharactersDontDependOnTheProcess() {
        let converted = FrequentCharacters.simplified.compactMap {
            String($0).applyingTransform(StringTransform("Hans-Hant"), reverse: false)?.first
        }
        XCTAssertTrue(Set(converted).isSubset(of: FrequentCharacters.traditional))
        let extras = FrequentCharacters.traditional.subtracting(FrequentCharacters.simplified).subtracting(converted)
        XCTAssertTrue(extras.isSubset(of: Set("讚囉喔欸嗚咧唷喲噢嘛啦哦耶嘿嗨呃哇喵萌囧爆衝ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦㄧㄨㄩ")),
                      "only the explicit variants: \(extras.sorted())")
    }

    func testTheFirstOfTheUsersLanguagesWithACodePageWins() {
        XCTAssertEqual(ZipFileNames.order(for: ["en-US", "zh-Hant-TW"]).first, .big5)
        XCTAssertEqual(ZipFileNames.order(for: ["en-US", "ko-KR", "zh-Hant-TW"]).first, .korean)
        XCTAssertEqual(ZipFileNames.order(for: ["zh-Hans-HK"]).first, .gb18030, "an explicit script beats the region")
        XCTAssertEqual(ZipFileNames.order(for: ["zh-HK"]).first, .big5)
        XCTAssertEqual(ZipFileNames.order(for: ["yue-Hant-HK"]).first, .big5)
        XCTAssertEqual(ZipFileNames.order(for: ["ru-RU"]).first, .cyrillicDOS)
        XCTAssertEqual(ZipFileNames.order(for: ["sr-Latn-RS"]).first, .gb18030)
        XCTAssertEqual(ZipFileNames.order(for: ["de-DE", "ja-JP"]).first, .westernDOS, "the user's own Western language")
        XCTAssertEqual(ZipFileNames.order(for: ["en-US", "ja-JP"]).first, .shiftJIS)
        XCTAssertEqual(ZipFileNames.order(for: []).first, .gb18030)
    }

    // MARK: Helpers

    private let gbk = encoding(.GB_18030_2000)

    private func decode(_ names: [String], _ cf: CFStringEncodings, _ languages: String...) -> [String] {
        let bytes = names.map { Array($0.data(using: Self.encoding(cf))!) }
        return ZipFileNames.decode(bytes.map { raw($0) }, preferredLanguages: languages).names
    }

    private func utf8(_ name: String) -> ZipFileNames.RawName {
        raw(Array(name.utf8), unix: true)
    }

    private func raw(_ bytes: [UInt8], unix: Bool = false) -> ZipFileNames.RawName {
        ZipFileNames.RawName(bytes: Data(bytes), isMarkedUTF8: false, unicodePath: nil, madeOnUnix: unix)
    }

    private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }
}
