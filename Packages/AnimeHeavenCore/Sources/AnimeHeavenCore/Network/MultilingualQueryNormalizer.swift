import Foundation

public enum QueryScript: Sendable, Equatable {
    case latin
    case kanaOnly
    case hanCJK
    case otherNonLatin
}

public struct AnalyzedQuery: Sendable, Equatable {
    public let original: String
    public let normalizedLatin: String
    public let script: QueryScript
    public let wikidataLangHint: String
    public let kanaRomajiCandidates: [String]
    public let romajiVariants: [String]
}

/// Pure-Swift script detector, Latin diacritic/macron folder, Japanese Kana-to-Hepburn-Romaji
/// transliterator, and bounded Romaji spelling-variant generator.
public enum MultilingualQueryNormalizer {
    private static let kanaDigraphs: [String: String] = [
        "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo",
        "しゃ": "sha", "しゅ": "shu", "しょ": "sho",
        "ちゃ": "cha", "ちゅ": "chu", "ちょ": "cho",
        "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
        "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo",
        "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
        "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo",
        "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
        "じゃ": "ja", "じゅ": "ju", "じょ": "jo",
        "ぢゃ": "ja", "ぢゅ": "ju", "ぢょ": "jo",
        "びゃ": "bya", "びゅ": "byu", "びょ": "byo",
        "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
        "ふぁ": "fa", "ふぃ": "fi", "ふぇ": "fe", "ふぉ": "fo",
        "てぃ": "ti", "でぃ": "di", "とぅ": "tu", "どぅ": "du",
        "うぃ": "wi", "うぇ": "we", "うぉ": "wo",
        "しぇ": "she", "じぇ": "je", "ちぇ": "che",
        "つぁ": "tsa", "つぃ": "tsi", "つぇ": "tse", "つぉ": "tso",
        "ヴぁ": "va", "ヴぃ": "vi", "ヴぇ": "ve", "ヴぉ": "vo"
    ]

    private static let kanaSingles: [Character: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "ゐ": "wi", "ゑ": "we", "を": "wo", "ん": "n",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o",
        "ゃ": "ya", "ゅ": "yu", "ょ": "yo", "ゎ": "wa", "ゔ": "vu"
    ]

    private static let kunreiRules: [(String, String)] = [
        (#"\bsi"#, "shi"),
        (#"\bti"#, "chi"),
        (#"\btu"#, "tsu"),
        (#"\bhu"#, "fu"),
        (#"\bzi"#, "ji"),
        (#"sy([auo])"#, "sh$1"),
        (#"ty([auo])"#, "ch$1"),
        (#"zy([auo])"#, "j$1")
    ]

    public static func analyze(_ rawQuery: String) -> AnalyzedQuery {
        let cleaned = rawQuery
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = stripDiacritics(cleaned)

        var hasLatin = false
        var hasKana = false
        var hasHan = false
        var hasHangul = false
        var hasCyrillic = false
        var hasArabic = false
        var hasThai = false
        var hasDevanagari = false
        var hasOtherNonLatin = false

        for scalar in cleaned.unicodeScalars {
            let v = scalar.value
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
                || (0x00C0...0x024F).contains(v) || (0x1E00...0x1EFF).contains(v) {
                hasLatin = true
            } else if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) {
                hasKana = true
            } else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) {
                hasHan = true
            } else if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) {
                hasHangul = true
            } else if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
                hasCyrillic = true
            } else if (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v) {
                hasArabic = true
            } else if (0x0E00...0x0E7F).contains(v) {
                hasThai = true
            } else if (0x0900...0x097F).contains(v) {
                hasDevanagari = true
            } else if CharacterSet.letters.contains(scalar) {
                hasOtherNonLatin = true
            }
        }

        let script: QueryScript
        if hasHan {
            script = .hanCJK
        } else if hasHangul || hasCyrillic || hasArabic || hasThai || hasDevanagari || hasOtherNonLatin {
            script = .otherNonLatin
        } else if hasKana {
            script = .kanaOnly
        } else {
            script = .latin
        }

        let langHint: String
        if hasHan && hasKana { langHint = "ja" }
        else if hasHan { langHint = "zh" }
        else if hasKana { langHint = "ja" }
        else if hasHangul { langHint = "ko" }
        else if hasCyrillic { langHint = "ru" }
        else if hasArabic { langHint = "ar" }
        else if hasThai { langHint = "th" }
        else if hasDevanagari { langHint = "hi" }
        else { langHint = "en" }

        let kanaRomaji = script == .kanaOnly ? kanaToRomajiCandidates(cleaned) : []
        let romajiVariants = (script == .latin && hasLatin) ? generateRomajiVariants(folded) : []

        return AnalyzedQuery(
            original: cleaned,
            normalizedLatin: folded,
            script: script,
            wikidataLangHint: langHint,
            kanaRomajiCandidates: kanaRomaji,
            romajiVariants: romajiVariants
        )
    }

    public static func stripDiacritics(_ input: String) -> String {
        let replaced = input
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‐", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        return replaced
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizeForMatch(_ input: String) -> String {
        stripDiacritics(input)
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isSearchableOnSite(_ candidate: String) -> Bool {
        let folded = stripDiacritics(candidate)
        return !folded.isEmpty && folded.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
    }

    public static func kanaToRomajiCandidates(_ raw: String) -> [String] {
        let hira = Array(toHiragana(raw))
        var lengthened = ""
        var compact = ""

        var i = 0
        while i < hira.count {
            let c = hira[i]
            if c == "っ" {
                if let next = nextKanaRomaji(hira, index: i + 1), let first = next.first {
                    let doubled: Character = next.hasPrefix("ch") ? "t" : first
                    if doubled.isASCII && doubled.isLetter && !"aeiou".contains(doubled) {
                        lengthened.append(doubled)
                        compact.append(doubled)
                    }
                }
                i += 1
                continue
            }
            if c == "ー" {
                if let last = lengthened.last, "aeiou".contains(last) {
                    lengthened.append(last)
                }
                i += 1
                continue
            }
            if i + 1 < hira.count {
                let pair = String([c, hira[i + 1]])
                if let mapped = kanaDigraphs[pair] {
                    lengthened.append(mapped)
                    compact.append(mapped)
                    i += 2
                    continue
                }
            }
            if let single = kanaSingles[c] {
                lengthened.append(single)
                compact.append(single)
            } else if c.isWhitespace || (c.isASCII && (c.isLetter || c.isNumber)) {
                let lower = String(c).lowercased()
                lengthened.append(lower)
                compact.append(lower)
            } else if c == "・" || c == "＝" || c == "-" {
                lengthened.append(" ")
                compact.append(" ")
            }
            i += 1
        }

        let first = lengthened
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let second = compact
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var out: [String] = []
        if !first.isEmpty { out.append(first) }
        if !second.isEmpty && second != first { out.append(second) }
        return out
    }

    public static func generateRomajiVariants(_ foldedLatin: String) -> [String] {
        let base = foldedLatin.lowercased()
        var results: [String] = []
        func appendIfNew(_ candidate: String) {
            if !candidate.isEmpty && candidate != base && !results.contains(candidate) {
                results.append(candidate)
            }
        }

        var hepburn = base
        for (pattern, replacement) in kunreiRules {
            hepburn = hepburn.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        appendIfNew(hepburn)

        let collapsed = hepburn
            .replacingOccurrences(of: "ou", with: "o")
            .replacingOccurrences(of: "uu", with: "u")
            .replacingOccurrences(of: "oo", with: "o")
        appendIfNew(collapsed)

        var tokens = hepburn.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if let lastIdx = tokens.lastIndex(where: {
            $0.count >= 3 && $0.range(of: #"(?<=[bcdfghjklmnpqrstvwxyz])o"#, options: .regularExpression) != nil
        }) {
            tokens[lastIdx] = tokens[lastIdx].replacingOccurrences(
                of: #"(?<=[bcdfghjklmnpqrstvwxyz])o"#,
                with: "ou",
                options: .regularExpression
            )
            let lastWordExpanded = tokens.joined(separator: " ")
            if lastWordExpanded.count <= base.count + 4 {
                appendIfNew(lastWordExpanded)
            }
        }

        let expandedO = hepburn.replacingOccurrences(
            of: #"(?<=[bcdfghjklmnpqrstvwxyz])o(?=[bcdfghjklmnpqrstvwxyz])|(?<=\S[bcdfghjklmnpqrstvwxyz])o(?=\s|$)"#,
            with: "ou",
            options: .regularExpression
        )
        if expandedO.count <= base.count + 6 {
            appendIfNew(expandedO)
        }

        return Array(results.prefix(4))
    }

    public static func rankAndDedupe(_ candidates: [String], excludeQuery: String = "") -> [String] {
        let excludedKey = normalizeForMatch(excludeQuery)
        var seen = Set<String>()
        var result: [String] = []
        for raw in candidates {
            let folded = stripDiacritics(raw)
            guard isSearchableOnSite(folded) else { continue }
            let key = normalizeForMatch(folded)
            guard !key.isEmpty, key != excludedKey else { continue }
            if seen.insert(key).inserted {
                result.append(folded)
            }
        }
        return result
    }

    private static func nextKanaRomaji(_ hira: [Character], index: Int) -> String? {
        guard index < hira.count else { return nil }
        if index + 1 < hira.count {
            let pair = String([hira[index], hira[index + 1]])
            if let mapped = kanaDigraphs[pair] { return mapped }
        }
        return kanaSingles[hira[index]]
    }

    private static func toHiragana(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if (0x30A1...0x30F6).contains(v), let hira = UnicodeScalar(v - 0x60) {
                out.unicodeScalars.append(hira)
            } else if v == 0x30FC {
                out.append("ー")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
