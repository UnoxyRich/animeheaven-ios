import Foundation

enum ArtworkProviders {
    typealias Object = [String: Any]
    static let fields = "id idMal title{english romaji native} synonyms seasonYear format popularity coverImage{extraLarge large color} bannerImage trailer{id site}"

    static func aniListBody(_ requests: [ArtworkLookupRequest]) throws -> Data {
        precondition((1...8).contains(requests.count))
        let variables = Dictionary(uniqueKeysWithValues: requests.enumerated().map { ("s\($0.offset)", $0.element.title) })
        let args = requests.indices.map { "$s\($0):String!" }.joined(separator: ",")
        let aliases = requests.indices.map {
            "a\($0):Page(perPage:5){media(search:$s\($0),type:ANIME,sort:[SEARCH_MATCH,POPULARITY_DESC]){\(fields)}}"
        }.joined()
        return try JSONSerialization.data(withJSONObject: ["query": "query(\(args)){\(aliases)}", "variables": variables])
    }

    static func object(_ data: Data) -> Object? {
        (try? JSONSerialization.jsonObject(with: data)) as? Object
    }

    static func url(_ value: Any?) -> String? {
        guard let string = value as? String, let url = URL(string: string),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil else { return nil }
        return string
    }

    static func aniList(_ data: Data, requests: [ArtworkLookupRequest]) -> [AnimeArtwork?] {
        let root = object(data)?["data"] as? Object
        return requests.enumerated().map { index, request in
            let page = root?["a\(index)"] as? Object
            let candidates = page?["media"] as? [Object] ?? []
            let titles = candidates.map { row in
                let title = row["title"] as? Object ?? [:]
                return ArtworkTitleMatcher.Candidate(
                    titles: ["english", "romaji", "native"].compactMap { title[$0] as? String } + (row["synonyms"] as? [String] ?? []),
                    year: row["seasonYear"] as? Int, format: row["format"] as? String ?? "", popularity: row["popularity"] as? Int ?? 0
                )
            }
            guard let index = ArtworkTitleMatcher.bestIndex(for: request, candidates: titles) else { return nil }
            let row = candidates[index]
            let cover = row["coverImage"] as? Object
            let trailer = row["trailer"] as? Object
            var result = AnimeArtwork()
            result.anilistId = row["id"] as? Int
            result.malId = row["idMal"] as? Int
            result.aniListPoster = url(cover?["extraLarge"]) ?? url(cover?["large"])
            result.aniListBanner = url(row["bannerImage"])
            result.accentColorHex = cover?["color"] as? String
            if (trailer?["site"] as? String)?.lowercased() == "youtube",
               let id = trailer?["id"] as? String, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
                result.trailerID = id
            }
            return result
        }
    }

    static func applyAniZip(_ data: Data, to artwork: inout AnimeArtwork) -> Bool {
        guard let root = object(data), root["images"] is [Object] || root["episodes"] is Object else { return false }
        let images = root["images"] as? [Object] ?? []
        func image(_ type: String) -> String? {
            images.first { ($0["coverType"] as? String)?.lowercased() == type }.flatMap { url($0["url"]) }
        }
        artwork.aniZipPoster = image("poster")
        artwork.aniZipBanner = image("banner")
        artwork.landscapeFanartUrl = image("fanart")
        if artwork.malId == nil { artwork.malId = (root["mappings"] as? Object)?["mal_id"] as? Int }
        for (key, value) in root["episodes"] as? Object ?? [:] {
            if let episode = Int(key), episode > 0, let still = url((value as? Object)?["image"]) {
                artwork.episodeThumbs[episode] = still
            }
        }
        return true
    }

    static func applyKitsu(_ data: Data, request: ArtworkLookupRequest, to artwork: inout AnimeArtwork) -> Bool {
        guard let rows = object(data)?["data"] as? [Object] else { return false }
        let entries = rows.compactMap { $0["attributes"] as? Object }
        let titles = entries.map { row in
            let titles = (row["titles"] as? [String: String])?.values.sorted() ?? []
            let aliases = row["abbreviatedTitles"] as? [String] ?? []
            let canonical = (row["canonicalTitle"] as? String).map { [$0] } ?? []
            return ArtworkTitleMatcher.Candidate(
                titles: titles + aliases + canonical,
                year: (row["startDate"] as? String).flatMap { Int($0.prefix(4)) },
                format: row["subtype"] as? String ?? "", popularity: row["userCount"] as? Int ?? 0
            )
        }
        if let index = ArtworkTitleMatcher.bestIndex(for: request, candidates: titles) {
            let poster = entries[index]["posterImage"] as? Object
            let cover = entries[index]["coverImage"] as? Object
            artwork.kitsuPoster = url(poster?["large"]) ?? url(poster?["original"]) ?? url(poster?["medium"])
            artwork.kitsuBanner = url(cover?["large"]) ?? url(cover?["small"]) ?? url(cover?["original"])
        }
        return true
    }

    static func applyJikan(_ data: Data, request: ArtworkLookupRequest, to artwork: inout AnimeArtwork) -> Bool {
        guard let value = object(data)?["data"] else { return false }
        let row: Object
        if let direct = value as? Object {
            row = direct
        } else if let rows = value as? [Object] {
            let titles = rows.map { row in
                let titles = (row["titles"] as? [Object] ?? []).compactMap { $0["title"] as? String }
                return ArtworkTitleMatcher.Candidate(
                    titles: titles + ["title", "title_english", "title_japanese"].compactMap { row[$0] as? String },
                    year: row["year"] as? Int ?? ((row["aired"] as? Object)?["from"] as? String).flatMap { Int($0.prefix(4)) },
                    format: row["type"] as? String ?? "", popularity: row["members"] as? Int ?? 0
                )
            }
            guard let index = ArtworkTitleMatcher.bestIndex(for: request, candidates: titles) else { return true }
            row = rows[index]
        } else { return false }
        if artwork.malId == nil { artwork.malId = row["mal_id"] as? Int }
        let images = row["images"] as? Object
        let webp = images?["webp"] as? Object
        let jpg = images?["jpg"] as? Object
        artwork.jikanPoster = url(webp?["large_image_url"]) ?? url(jpg?["large_image_url"])
        let trailer = (row["trailer"] as? Object)?["images"] as? Object
        artwork.jikanTrailer = url(trailer?["maximum_image_url"]) ?? url(trailer?["large_image_url"])
        return true
    }
}
