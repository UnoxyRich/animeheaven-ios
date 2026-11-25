import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("MultilingualSearch")
struct MultilingualSearchTests {

    @Test func detectsScriptsAndLanguageHintsAcrossWorldLanguages() {
        #expect(MultilingualQueryNormalizer.analyze("Sousou no Frieren").script == .latin)
        #expect(MultilingualQueryNormalizer.analyze("しんげきのきょじん").script == .kanaOnly)

        let cn = MultilingualQueryNormalizer.analyze("葬送的芙莉莲")
        #expect(cn.script == .hanCJK)
        #expect(cn.wikidataLangHint == "zh")

        let jp = MultilingualQueryNormalizer.analyze("葬送のフリーレン")
        #expect(jp.script == .hanCJK)
        #expect(jp.wikidataLangHint == "ja")

        let ko = MultilingualQueryNormalizer.analyze("진격의 거인")
        #expect(ko.script == .otherNonLatin)
        #expect(ko.wikidataLangHint == "ko")

        let ru = MultilingualQueryNormalizer.analyze("Атака титанов")
        #expect(ru.script == .otherNonLatin)
        #expect(ru.wikidataLangHint == "ru")

        let ar = MultilingualQueryNormalizer.analyze("هجوم العمالقة")
        #expect(ar.script == .otherNonLatin)
        #expect(ar.wikidataLangHint == "ar")

        let th = MultilingualQueryNormalizer.analyze("ผ่าพิภพไททัน")
        #expect(th.script == .otherNonLatin)
        #expect(th.wikidataLangHint == "th")
    }

    @Test func stripsMacronsAndGeneratesRomajiVariants() {
        let analyzed = MultilingualQueryNormalizer.analyze("Sōsō no Furīren")
        #expect(analyzed.normalizedLatin == "Soso no Furiren")
        #expect(analyzed.romajiVariants.contains("sousou no furiren"))

        let kunrei = MultilingualQueryNormalizer.generateRomajiVariants("Singeki no Kyozin")
        #expect(kunrei.contains(where: { $0.contains("shingeki") }))

        let soma = MultilingualQueryNormalizer.generateRomajiVariants("Shokugeki no Soma")
        #expect(soma.contains("shokugeki no souma"))
    }

    @Test func convertsHiraganaAndKatakanaToHepburnRomaji() {
        let shingeki = MultilingualQueryNormalizer.kanaToRomajiCandidates("しんげき の きょじん")
        #expect(shingeki.contains("shingeki no kyojin"))

        let kimetsu = MultilingualQueryNormalizer.kanaToRomajiCandidates("きめつのやいば")
        #expect(kimetsu.contains("kimetsunoyaiba"))

        let katakana = MultilingualQueryNormalizer.kanaToRomajiCandidates("ワンピース")
        #expect(katakana.contains("wanpiisu"))
        #expect(katakana.contains("wanpisu"))

        let sokuon = MultilingualQueryNormalizer.kanaToRomajiCandidates("けっこん")
        #expect(sokuon.contains("kekkon"))
    }

    @Test func parsesExternalProviderPayloadsCleanly() {
        let aniListData = Data("""
        {"data":{"Page":{"media":[{"title":{"romaji":"Sousou no Frieren","english":"Frieren: Beyond Journey's End"},"format":"TV","popularity":500000}]}}}
        """.utf8)
        #expect(MultilingualSearchResolver.parseAniListSingle(aniListData) == [
            "Sousou no Frieren",
            "Frieren: Beyond Journey's End"
        ])

        let bangumiData = Data("""
        {"results":2,"list":[{"id":420628,"name":"薬屋のひとりごと","name_cn":"药屋少女的呢喃"}]}
        """.utf8)
        #expect(MultilingualSearchResolver.parseBangumiNativeNames(bangumiData) == ["薬屋のひとりごと"])

        let wikidataData = Data("""
        {"search":[
          {"id":"Q999","label":"Random Company","description":"software company"},
          {"id":"Q586025","label":"Attack on Titan","description":"Japanese manga series"}
        ]}
        """.utf8)
        #expect(MultilingualSearchResolver.parseWikidataLabels(wikidataData) == ["Attack on Titan"])

        let kitsuData = Data("""
        {"data":[{"attributes":{"canonicalTitle":"Shokugeki no Souma","titles":{"en":"Food Wars! Shokugeki no Soma","en_jp":"Shokugeki no Souma"}}}]}
        """.utf8)
        #expect(MultilingualSearchResolver.parseKitsuTitles(kitsuData) == [
            "Shokugeki no Souma",
            "Food Wars! Shokugeki no Soma",
            "Shokugeki no Souma"
        ])
    }

    @Test func rankAndDedupeFiltersNonLatinAndDeduplicates() {
        let ranked = MultilingualQueryNormalizer.rankAndDedupe([
            "葬送のフリーレン",
            "Sousou no Frieren",
            "Sōusōu no Frieren",
            "sousou no frieren!",
            "Frieren: Beyond Journey’s End"
        ], excludeQuery: "Soso no Frieren")
        #expect(ranked == ["Sousou no Frieren", "Frieren: Beyond Journey's End"])
    }
}
