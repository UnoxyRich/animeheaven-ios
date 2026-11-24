import Foundation

public enum ArtworkTitleMatcher {
    struct Candidate {
        let titles: [String]
        let year: Int?
        let format: String
        let popularity: Int
    }

    private struct Qualifiers: Equatable {
        var season: Int? = nil
        var part: Int? = nil
        var final = false
    }

    public static func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "['’‘ʼ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\p{M}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func find(_ pattern: String, in title: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else { return nil }
        return String(title[range])
    }

    private static func qualifiers(_ title: String) -> Qualifiers {
        let roman = ["ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6]
        let season = find(#"\bseason (\d+)\b"#, in: title)
            ?? find(#"\b(\d+)(?:st|nd|rd|th)? season\b"#, in: title)
            ?? find(#"\b(?:dai )?(\d+) ki\b"#, in: title)
        let trailing = find(#"\b(ii|iii|iv|v|vi)$"#, in: title)
        return Qualifiers(season: season.flatMap(Int.init) ?? trailing.flatMap { roman[$0] },
                          part: find(#"\b(?:part|cour) (\d+)\b"#, in: title).flatMap(Int.init),
                          final: title.contains("final season"))
    }

    static func bestIndex(for request: ArtworkLookupRequest, candidates: [Candidate]) -> Int? {
        let queries = [request.title, request.japaneseTitle].map(normalize).filter { !$0.isEmpty }
        let expected = queries.map(qualifiers)
        let extraWords: Set<Substring> = ["ova", "ona", "special", "short", "recap"]
        let explicitExtra = queries.contains { !extraWords.isDisjoint(with: $0.split(separator: " ")) }
        var best: (Int, Double)?
        for (index, candidate) in candidates.enumerated() {
            let aliases = candidate.titles.map(normalize).filter { !$0.isEmpty }
            let actual = aliases.map(qualifiers)
            // An explicit sequel must not silently fall back to the original (or vice versa).
            let season = expected.compactMap(\.season).first
            let part = expected.compactMap(\.part).first
            let final = expected.contains { $0.final }
            let seasons = Set(actual.compactMap(\.season))
            let parts = Set(actual.compactMap(\.part))
            let candidateFinal = actual.contains { $0.final }
            if let season, !seasons.isEmpty, !seasons.contains(season) { continue }
            if let part, !parts.isEmpty, !parts.contains(part) { continue }
            var lexical = 0.0
            var exact = false
            for query in queries {
                let words = Set(query.split(separator: " "))
                for alias in aliases {
                    let other = Set(alias.split(separator: " "))
                    let similarity = Double(words.intersection(other).count) / Double(words.union(other).count)
                    let same = query == alias
                    exact = exact || same
                    lexical = max(lexical, (same ? 100 : 0) + similarity * 60)
                }
            }
            guard lexical >= 30 else { continue }
            if season != nil && seasons.isEmpty || part != nil && parts.isEmpty || final && !candidateFinal {
                continue
            }
            if season == nil && !exact && !seasons.isEmpty || part == nil && !exact && !parts.isEmpty { continue }
            let format = candidate.format.uppercased()
            if !exact && !explicitExtra && ["ONA", "OVA", "SPECIAL", "MUSIC", "TV_SHORT"].contains(format) { continue }
            var score = lexical
            if season != nil && !seasons.isEmpty || part != nil && !parts.isEmpty || final && candidateFinal { score += 35 }
            if let year = request.year, let candidateYear = candidate.year { score += year == candidateYear ? 20 : -20 }
            if !explicitExtra && ["TV", "MOVIE"].contains(format) { score += 15 }
            score += min(12, log10(Double(max(1, candidate.popularity))) * 2)
            if score >= 45 && score > (best?.1 ?? -.infinity) { best = (index, score) }
        }
        return best?.0
    }
}
