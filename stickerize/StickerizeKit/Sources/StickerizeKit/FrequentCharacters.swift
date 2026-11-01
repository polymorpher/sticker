import Foundation

/// Everyday characters in Chinese and Korean, to tell a real name from a misreading when the same bytes are equally
/// valid GBK, Big5 or Korean. Real text is mostly everyday characters (about nine in ten); a misreading lands on
/// arbitrary characters of the code page's common block, of which only a share (`coverage`) are everyday ones.
enum FrequentCharacters {
    /// The natural log of how much likelier `texts`, read in `legacy`, is to be real text than a misreading: positive
    /// when likelier real. Nil if there are no letters to judge, or `legacy` isn't a Chinese or Korean code page.
    static func evidence(in texts: [String], for legacy: ZipFileNames.Legacy) -> Double? {
        guard let common = everyday(in: legacy), let misread = coverage[legacy] else { return nil }
        // Each character once: a name repeated with numbers ("鲁1", "鲁2") or a syllable repeated ("큭큭큭큭") is no
        // more evidence than one.
        var seen = Set<Character>()
        var letters = 0, frequent = 0
        for text in texts {
            for character in text where !character.isASCII && character.isLetter && seen.insert(character).inserted {
                letters += 1
                if common.contains(character) { frequent += 1 }
            }
        }
        guard letters > 0 else { return nil }
        let real = 0.9
        return Double(frequent) * log(real / misread) + Double(letters - frequent) * log((1 - real) / (1 - misread))
    }

    /// An everyday hanzi, simplified or traditional.
    static func isEveryday(_ character: Character) -> Bool {
        simplified.contains(character) || traditional.contains(character)
    }

    /// An everyday character of `legacy`'s language (false for code pages without a list).
    static func isEveryday(_ character: Character, in legacy: ZipFileNames.Legacy) -> Bool {
        everyday(in: legacy)?.contains(character) ?? false
    }

    private static func everyday(in legacy: ZipFileNames.Legacy) -> Set<Character>? {
        switch legacy {
        case .gb18030: simplified
        case .big5: traditional
        case .korean: hangul
        default: nil
        }
    }

    /// The share of each code page's common block that is everyday characters: how often a misreading lands on one.
    private static let coverage: [ZipFileNames.Legacy: Double] = {
        func share(_ legacy: ZipFileNames.Legacy, leads: ClosedRange<UInt8>, trails: [ClosedRange<UInt8>],
                   everyday: Set<Character>) -> Double {
            var total = 0, frequent = 0
            for lead in leads {
                for range in trails {
                    for trail in range {
                        guard let character = String(data: Data([lead, trail]), encoding: legacy.encoding)?.first else { continue }
                        total += 1
                        if everyday.contains(character) { frequent += 1 }
                    }
                }
            }
            return Double(frequent) / Double(max(total, 1))
        }
        return [
            .gb18030: share(.gb18030, leads: 0xB0...0xD7, trails: [0xA1...0xFE], everyday: simplified), // GB2312 level 1
            .big5: share(.big5, leads: 0xA4...0xC5, trails: [0x40...0x7E, 0xA1...0xFE], everyday: traditional),
            .korean: share(.korean, leads: 0xB0...0xC8, trails: [0xA1...0xFE], everyday: hangul), // KS X 1001 Hangul
        ]
    }()

    /// The 1379 most frequent hanzi, most frequent first, then ones common in sticker names and chat. (Not those whose
    /// bytes are an everyday character of another code page, such as 夸, which is Korean 요 in "좋아요": that reading
    /// would lose.)
    static let simplified = Set(
        "的一是不了在人有我他这个们中来上大为和国地到以说时要就出会可也你对生能而子那得于着下自之年过发后作里用道行所然家种事成方多经么去法学如都同现当没动面起看定天分还进好小部其些主样理心她本前开但因" +
        "只从想实日军者意无力它与长把机十民第公此已工使情明性知全三又关点正业外将两高间由问很最重并物手应战向头文体政美相见被利什二等产或新己制身果加西斯月话合回特代内信表化老给世位次度门任常先海通教儿" +
        "原东声提立及比员解水名真论处走义各入几口认条平系气题活尔更别打女变四神总何电数安少报才结反受目太量再感建务做接必场件计管期市直德资命山金指克许统区保至队形社便空决治展马科司五基眼书非则听白却界" +
        "达光放强即像难且权思王象完设式色路记南品住告类求据程北边死张该交规万取拉格望觉术领共确传师观清今切院让识候带导争运笑飞风步改收根干造言联持组每济车亲极林服快办议往元英士证近失转夫令准布始怎呢存" +
        "未远叫台单影具罗字爱击流备兵连调深商算质团集百需价花党华城石级整府离况亚请技际约示复病息究线似官火断精满支视消越器容照须九增研写称企八功吗包片史委乎查轻易早曾除农找装广显吧阿李标谈吃图念六引历" +
        "首医局突专费号尽另周较注语仅考落青随选列武红响虽推势参希古众构房半节土投某案黑维革划敌致陈律足态护七兴派孩验责营星够章音跟志底站严巴例防族供效续施留讲型料终答紧黄绝奇察母京段依批群项故按河米围" +
        "江织害斗双境客纪采举杀攻父苏密低朝友诉止细愿千值仍男钱破网热助倒育属坐帝限船脸职速刻乐否刚威毛状率甚独球般普怕弹校苦创假久错承印晚兰试股拿脑预谁益阳若哪微尼继送急血惊伤素药适波夜省初喜卫源食险" +
        "待述陆习置居劳财环排福纳欢雷警获模充负云停木游龙树疑层冷洲冲射略范竟句室异激汉村哈策演简卡罪判担州静退既衣您宗积余痛检差富灵协角占配征修皮挥胜降阶审沉坚善妈刘读啊超免压银买皇养伊怀执副乱抗犯追" +
        "帮宣佛岁航优怪香著田铁控税左右份穿艺背阵草脚概恶块顿敢守酒岛托央户烈洋哥索胡款靠评版宝座释景顾弟登货互付伯慢欧换闻危忙核暗姐介坏讨丽良序升监临亮露永呼味野架域沙掉括舰鱼杂误湾吉减编楚肯测败屋跑" +
        "梦散温困剑渐封救贵枪缺楼县尚毫移娘朋画班智亦耳恩短掌恐遗固席松秘谢鲁遇康虑幸均销钟诗藏赶剧票损忽巨炮旧端探湖录叶春乡附吸予礼港雨呀板庭妇归睛饭额含顺输摇招婚脱补谓督毒油疗旅泽材灭逐莫笔亡鲜词圣" +
        "择寻厂睡博勒烟授诺伦岸奥唐卖俄炸载洛健堂旁宫喝借君禁阴园谋宋避抓荣姑孙逃牙束跳顶玉镇雪午练迫爷篇肉嘴馆遍凡础洞卷坦牛宁纸诸训私庄祖丝翻暴森塔默握戏隐熟骨访弱蒙歌店鬼软典欲萨伙遭盘爸扩盖弄雄稳忘" +
        "亿刺拥徒姆杨齐赛趣曲刀床迎冰虚玩析窗醒妻透购替塞努休虎扬途侵刑绿兄迅套贸毕唯谷轮库迹尤竞街促延震弃甲伟麻川申缓潜闪售灯针哲络抵朱埃抱鼓植纯夏忍页杰筑折郑贝尊吴秀混臣雅振染盛怒舞圆搞狂措姓残秋培" +
        "迷诚宽宇猛摆梅毁伸摩盟末乃悲拍丁赵阻哭萌乖狗猫呆晕汗赞囧嘻呵嘿哇哦呜啦嗯哼喵汪怼懵酷爽惨耶吼嗨棒帅丑胖瘦饿累烦闷羞臊吻蹭拜滚溜躺摸猪兔熊鸭鸡羊鼠蛇猴哎嘛喔哟噢唉呸擦屁屎尿泪漂逼蝴蝶恭辛歉厌嘁咦" +
        "呃嘤嗷嗝嘘嘶呦哒咩鹅虾蟹龟蛙鸟鹰狼狐狸驴狮豹猩鹿闹踢揉捏掐扯撞摔跌傻憨蠢笨渴疼痒恼慌吓怯尴尬鼻涕朵肚腿袋脖胳膊腰胸肩膀饺粽糖奶茶咖啡蛋糕饼薯堡披锅烧烤串辣酸甜咸臭嫩脆硬烫凉彩虹账圈粉聊喽咯嘞呗" +
        "啥咋俺咱颗粒滴瓶杯碗勺筷叉洗澡刷鞋帽袜裙裤伞钥匙频唱蹈肥寂寞孤崩溃屈舒" +
        "瑰桃滑蜜菜爬巧妒扭炒抬拖哄衰嗒抢噜喱鸽")

    /// The same characters in traditional form, plus the variants Taiwan and Hong Kong use in sticker names where the
    /// standard conversion picks another (讚 for 赞, 囉, 喔), and bopomofo, which Taiwanese chat writes on its own
    /// ("ㄏㄏ", "好ㄉ").
    static let traditional: Set<Character> = {
        // Each character on its own (the transform reads some by their neighbours: 干 as 乾, 幹 or 干), and in a fixed
        // order, so the set is the same in every process.
        let text = simplified.sorted().map(String.init).joined(separator: "\n")
        return simplified.union((text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? "").filter { $0 != "\n" })
            .union("讚囉喔欸嗚咧唷喲噢嘛啦哦耶嘿嗨呃哇喵萌囧爆衝")
            .union("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦㄧㄨㄩ")
    }()

    /// 508 frequent Hangul syllables, then ones common in sticker names and chat ("펭귄", "초콜릿", "큭큭"), chosen by
    /// what they gain and cost on Korean, Chinese and Japanese name corpora; and the jamo chat writes on their own
    /// ("ㅋㅋ", "ㅠㅠ", "ㅇㅇ").
    static let hangul = Set("ㄱㄴㄷㅂㅅㅇㅈㅊㅋㅎㅜㅠㅡ" +
        "이다는의에하고가지을를기사서한로리어도아자시대수나으해인것그일들정적제전있우내주게부상보만성구국동장라원거위여화무비소마중모과신경생했면오연개년문실공저금회계히미방물관진행니요세말분통람학유김" +
        "선당할없안까트터났운체습와데식및발조후결반각영바날단드교명용업야차민점호같은될되된됐줄크려집질좋놓많알았었였겠네며래렇렸엄빠언형친강양랑감합녕축복귀맛싶잘굿밤최짱멋져예뻐배파졸피곤힘응침심녁늘" +
        "팅박헐웃음눈짜싫몰넵넹땡큐헉흑흥메새받엽쁘쩐찮않퇴볶떡맥킨카타노초코토포누두루추쿠투푸디치키티레매베애재채캐케태테패페헤괴뇌돼뒤뭐뭘봐봤쉬왜외워웨쥐줘춰취퀴튀간갈갑건걸검겨곳광괜군굴권근글급길" +
        "깊깨꺼께꼭꽃꾸꿈끝난남너넣넘놀높느능달담답더던덕독돌둘든등따딱땅때떠또똑뚜뜻란러런럼록론롭료룰류르른름릇릴림립막맘맞맨머먹먼멀몇목몸못묻밀밑밖밥백버번벌법벽변별병본볼봄북불빌빛빨빼뿐산살삼색석" +
        "설섬속손솔송숙순술숨쉽스슬승십싸쌀써쓰씨악암압앞약얘억얼역열염옆옥온올옷완왔왕욕울움월육익읽잃임입잊작잔잠잡쟁절젊접족존좀종죽준즐즘직짓째쪽찌찍착참창찾책처천철첫청총출충칠커컴큰탈탕택특틀판팔" +
        "퍼편평표풀품프필함항향허험현혹혼홍확환활황훨휴흐흔흘흙흰" +
        "펭귄끼큭킥캬콜릿브곰멍닥짝깜벅붕꿀땀꺽엉멘뽀훌쩍윙릅츄콩증짹쩝렘끄뿅힝옹숭꽥햄꼼룩쳇꺄뒹앗칫잇듯햇뿌냠짠")
}
