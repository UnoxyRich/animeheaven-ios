import Foundation
import SwiftSoup

public enum AnimeHeavenParser {
    private static let animeIdRegex = try! NSRegularExpression(pattern: #"anime\.php\?([a-zA-Z0-9_-]+)"#)
    private static let gateKeyRegex = try! NSRegularExpression(pattern: #"gate(?:a|h)?\s*\(\s*["']([a-zA-Z0-9_-]+)["']"#)
    private static let episodeNumberRegex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)"#)

    public static func extractAnimeId(_ href: String?) -> String? {
        guard let href, !href.isEmpty else { return nil }
        return firstCapture(regex: animeIdRegex, in: href)
    }

    public static func normalizeUrl(_ url: String?) -> String {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }
        if trimmed.hasPrefix("/") {
            return "\(AnimeHeavenClient.baseURL)\(trimmed)"
        }
        return "\(AnimeHeavenClient.baseURL)/\(trimmed)"
    }

    public static func parseHome(html: String) -> HomeFeed {
        guard let doc = try? SwiftSoup.parse(html, AnimeHeavenClient.baseURL) else {
            return HomeFeed(banners: [], scheduleItems: [], popularItems: [], seasonPath: nil, seasonLabel: nil)
        }

        let bannerElements = (try? doc.select("div.banner #slide a[href*=anime.php]")) ?? Elements()
        let banners: [BannerItem] = bannerElements.array().compactMap { link in
            guard let id = extractAnimeId(try? link.attr("href")) else { return nil }
            let img = try? link.select("img").first()
            let imageUrl = normalizeUrl(try? img?.attr("src"))
            guard !imageUrl.isEmpty else { return nil }
            let rawAlt = (try? img?.attr("alt"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawAlt.isEmpty ? "Featured Anime" : rawAlt
            return BannerItem(animeId: id, title: title, bannerImageUrl: imageUrl)
        }

        let headerLinks = (try? doc.select("div.header a.headeritem2")) ?? Elements()
        let seasonLink = headerLinks.array().first { link in
            let href = (try? link.attr("href")) ?? ""
            return !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                href.range(of: "random.php", options: .caseInsensitive) == nil
        }
        let seasonPath: String? = {
            guard let raw = try? seasonLink?.attr("href") else { return nil }
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return cleaned.isEmpty ? nil : cleaned
        }()
        let seasonLabel: String? = {
            guard let raw = try? seasonLink?.text() else { return nil }
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }()

        let chartEls = (try? doc.select("div.chart"))?.array() ?? []
        let scheduleItems = parseChartElements(chartEls, isPopularRank: false)

        let popularLinks = (try? doc.select("div.popularbox div.popularbox2 a[href*=anime.php]")) ?? Elements()
        let popularItems: [AnimeCard] = popularLinks.array().compactMap { link in
            guard let id = extractAnimeId(try? link.attr("href")) else { return nil }
            let img = try? link.select("img").first()
            let coverUrl = normalizeUrl(try? img?.attr("src"))
            let title = (try? img?.attr("alt"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AnimeCard(id: id, title: title, coverUrl: coverUrl)
        }

        return HomeFeed(
            banners: banners,
            scheduleItems: scheduleItems,
            popularItems: popularItems,
            seasonPath: seasonPath,
            seasonLabel: seasonLabel
        )
    }

    public static func parseChartPage(html: String, isPopularRank: Bool = false) -> ChartFeedResult {
        guard let doc = try? SwiftSoup.parse(html, AnimeHeavenClient.baseURL) else {
            return ChartFeedResult(title: "", items: [])
        }
        let title = (try? doc.select("div.linetitle").first()?.ownText())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let charts = (try? doc.select("div.chart, div.chart2g, div.chart2ls"))?.array() ?? []
        let items = parseChartElements(charts, isPopularRank: isPopularRank)
        return ChartFeedResult(title: title, items: items)
    }

    private static func parseChartElements(_ elements: [Element], isPopularRank: Bool) -> [AnimeCard] {
        elements.compactMap { chart in
            let titleLink = try? chart.select(
                ".charttitle a[href*=anime.php], .charttitle2g a[href*=anime.php], .charttitle2ls a[href*=anime.php]"
            ).first()
            let coverLink = try? chart.select(
                ".chartimg a[href*=anime.php], .chartimg2g a[href*=anime.php], .chartimg2ls a[href*=anime.php]"
            ).first()
            guard let id = extractAnimeId(try? titleLink?.attr("href"))
                ?? extractAnimeId(try? coverLink?.attr("href")) else {
                return nil
            }

            let coverImg = try? chart.select("img.coverimg").first()
            let linkTitle = (try? titleLink?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let altTitle = (try? coverImg?.attr("alt"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = linkTitle.isEmpty ? altTitle : linkTitle
            guard !title.isEmpty else { return nil }

            let rawJp = (try? chart.select(".charttitlejp, .charttitlejp2g, .charttitlejp2ls").first()?.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let japaneseTitle = rawJp == "-" ? "" : rawJp

            let coverUrl = normalizeUrl(try? coverImg?.attr("src"))
            let epPrimary = (try? chart.select(".chartep, .chartep2g, .chartep2ls").first()?.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let epFallback = (try? chart.select(".chartepm, .chartepm2g, .chartepm2ls").first()?.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let epText = epPrimary.isEmpty ? epFallback : epPrimary

            let timerEl = try? chart.select(".charttimer, .charttimer2g, .charttimer2ls").first()
            var rankDelta: String? = nil
            var rankDirection: RankDirection? = nil
            let timerOrStatus: String

            if isPopularRank, let timerEl {
                let imgSrc = (try? timerEl.select("img").first()?.attr("src")) ?? ""
                if imgSrc.range(of: "arrowu", options: .caseInsensitive) != nil {
                    rankDirection = .up
                } else if imgSrc.range(of: "arrowd", options: .caseInsensitive) != nil {
                    rankDirection = .down
                } else if imgSrc.range(of: "arrowb", options: .caseInsensitive) != nil {
                    rankDirection = .same
                }
                let rawDelta = (try? timerEl.select(".popt").first()?.text())?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                rankDelta = rawDelta.isEmpty ? nil : rawDelta
                timerOrStatus = rankDelta ?? ""
            } else {
                timerOrStatus = (try? timerEl?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            return AnimeCard(
                id: id,
                title: title,
                japaneseTitle: japaneseTitle,
                coverUrl: coverUrl,
                episodeLabel: epText,
                timerOrStatus: timerOrStatus,
                rankDelta: rankDelta,
                rankDirection: rankDirection,
                isPopularRank: isPopularRank
            )
        }
    }

    public static func parseFastSearch(html: String) -> [FastSearchItem] {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let doc = try? SwiftSoup.parseBodyFragment(html, AnimeHeavenClient.baseURL) else {
            return []
        }
        let links = (try? doc.select("a[href*=anime.php]"))?.array() ?? []
        return links.compactMap { link in
            guard let id = extractAnimeId(try? link.attr("href")) else { return nil }
            let img = try? link.select(".fastimg img, img.coverimg").first()
            let coverUrl = normalizeUrl(try? img?.attr("src"))
            let fastName = (try? link.select(".fastname").first()?.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let altName = (try? img?.attr("alt"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = fastName.isEmpty ? altName : fastName
            guard !title.isEmpty else { return nil }
            return FastSearchItem(animeId: id, title: title, coverUrl: coverUrl)
        }
    }

    public static func parseSimilarGrid(html: String) -> ChartFeedResult {
        guard let doc = try? SwiftSoup.parse(html, AnimeHeavenClient.baseURL) else {
            return ChartFeedResult(title: "", items: [])
        }
        let title = (try? doc.select("div.linetitle").first()?.ownText())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let containers = (try? doc.select("div.info3"))?.array() ?? []
        let items = parseSimilarContainers(containers)
        return ChartFeedResult(title: title, items: items)
    }

    private static func parseSimilarContainers(_ containers: [Element]) -> [AnimeCard] {
        containers.flatMap { container -> [AnimeCard] in
            let cards = (try? container.select("div.similarimg"))?.array() ?? []
            return cards.compactMap { card in
                guard let link = try? card.select("a[href*=anime.php]").first(),
                      let id = extractAnimeId(try? link.attr("href")) else {
                    return nil
                }
                let img = try? card.select("img.coverimg").first()
                let coverUrl = normalizeUrl(try? img?.attr("src"))
                let nameText = (try? card.select(".similarname a, .similarname").first()?.text())?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let altText = (try? img?.attr("alt"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = nameText.isEmpty ? altText : nameText
                guard !title.isEmpty else { return nil }
                return AnimeCard(id: id, title: title, coverUrl: coverUrl)
            }
        }
    }

    public static func parseAnimeDetail(animeId: String, html: String) -> AnimeDetail {
        guard let doc = try? SwiftSoup.parse(html, AnimeHeavenClient.baseURL) else {
            return AnimeDetail(
                id: animeId, title: "", japaneseTitle: "", bannerUrl: nil, posterUrl: "",
                synopsis: "", tags: [], episodesLabel: "?", year: "?", score: "?",
                countdownLabel: nil, episodes: [], relatedShows: [], similarShows: []
            )
        }

        let rawBanner = normalizeUrl(try? doc.select("div.banner img.bannerimg").first()?.attr("src"))
        let bannerUrl = rawBanner.isEmpty ? nil : rawBanner
        let posterUrl = normalizeUrl(try? doc.select("div.infoimg img.posterimg").first()?.attr("src"))
        let title = (try? doc.select("div.infotitle").first()?.text())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawJp = (try? doc.select("div.infotitlejp").first()?.text())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let japaneseTitle = rawJp == "-" ? "" : rawJp
        let synopsis = (try? doc.select("div.infodes").first()?.text())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let tagEls = (try? doc.select("div.infotags a .boxitem"))?.array() ?? []
        let tags = tagEls.compactMap { el -> String? in
            let t = (try? el.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }

        let infoYearEl = try? doc.select("div.infoyear").first()
        let metaValues = ((try? infoYearEl?.select("div.inline.c2"))?.array() ?? []).map {
            ((try? $0.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let episodesLabel = metaValues.count > 0 ? metaValues[0] : "?"
        let year = metaValues.count > 1 ? metaValues[1] : "?"
        let score = metaValues.count > 2 ? metaValues[2] : "?"

        let info2Els = (try? doc.select("div.info2"))?.array() ?? []
        let countdownLabel: String? = info2Els.first { el in
            ((try? el.text()) ?? "").range(of: "Countdown", options: .caseInsensitive) != nil
        }.flatMap { el in
            let text = ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        let epLinks = (try? doc.select("div.linetitle2 a[href*=gate.php]"))?.array() ?? []
        let episodes: [EpisodeItem] = epLinks.compactMap { epLink in
            let idAttr = ((try? epLink.attr("id")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if !idAttr.isEmpty {
                key = idAttr
            } else {
                let onclick = (try? epLink.attr("onclick")) ?? ""
                key = firstCapture(regex: gateKeyRegex, in: onclick) ?? ""
            }
            guard !key.isEmpty else { return nil }

            let numberLabel = (try? epLink.select(".watch2").first()?.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let watch1s = (try? epLink.select(".watch1"))?.array() ?? []
            let releaseAge = watch1s.count > 1
                ? ((try? watch1s.last?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                : ""
            return EpisodeItem(key: key, numberLabel: numberLabel, releaseAge: releaseAge)
        }

        var relatedShows: [AnimeCard] = []
        var similarShows: [AnimeCard] = []
        let headers = (try? doc.select("div.linetitle"))?.array() ?? []
        for header in headers {
            let label = ((try? header.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let nextInfo3 = try? header.nextElementSibling(), nextInfo3.hasClass("info3") {
                if label.range(of: "Related Shows", options: .caseInsensitive) != nil {
                    relatedShows = parseSimilarContainers([nextInfo3])
                } else if label.range(of: "Similar Shows", options: .caseInsensitive) != nil {
                    similarShows = parseSimilarContainers([nextInfo3])
                }
            }
        }

        return AnimeDetail(
            id: animeId,
            title: title,
            japaneseTitle: japaneseTitle,
            bannerUrl: bannerUrl,
            posterUrl: posterUrl,
            synopsis: synopsis,
            tags: tags,
            episodesLabel: episodesLabel,
            year: year,
            score: score,
            countdownLabel: countdownLabel,
            episodes: episodes,
            relatedShows: relatedShows,
            similarShows: similarShows
        )
    }

    public static func parseGatePage(episodeKey: String, html: String) -> EpisodeStream {
        guard let doc = try? SwiftSoup.parse(html, AnimeHeavenClient.baseURL) else {
            return EpisodeStream(
                episodeKey: episodeKey, animeId: nil, animeTitle: "", episodeLabel: "",
                videoSources: [], prevEpisodeKey: nil, prevEpisodeLabel: nil,
                nextEpisodeKey: nil, nextEpisodeLabel: nil
            )
        }

        let headerEl = try? doc.select("div.linetitle3").first()
        let animeLink = try? headerEl?.select("a[href*=anime.php]").first()
        let animeId = extractAnimeId(try? animeLink?.attr("href"))
        let animeTitle = (try? animeLink?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fullHeaderText = (try? headerEl?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let episodeLabel: String
        if !animeTitle.isEmpty && fullHeaderText.hasPrefix(animeTitle) {
            episodeLabel = String(fullHeaderText.dropFirst(animeTitle.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            episodeLabel = fullHeaderText
        }

        var seenSources = Set<String>()
        let sourceEls = (try? doc.select("video#vid source[src]"))?.array() ?? []
        let videoSources: [String] = sourceEls.compactMap { srcEl in
            let url = normalizeUrl(try? srcEl.attr("src"))
            guard !url.isEmpty, seenSources.insert(url).inserted else { return nil }
            return url
        }

        let gateLinks = (try? doc.select("div.linetitle2 a[href*=gate.php]"))?.array() ?? []
        let navLinks: [(String, String)] = gateLinks.compactMap { link in
            let onclick = (try? link.attr("onclick")) ?? ""
            let idAttr = ((try? link.attr("id")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = firstCapture(regex: gateKeyRegex, in: onclick)
                ?? (idAttr.isEmpty ? nil : idAttr) else {
                return nil
            }
            let boxLabel = (try? link.select(".boxitem").first()?.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallbackLabel = ((try? link.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = boxLabel.isEmpty ? fallbackLabel : boxLabel
            return (key, label)
        }

        let currentEpNum = extractLeadingNumber(episodeLabel)
        var prevKey: String? = nil
        var prevLabel: String? = nil
        var nextKey: String? = nil
        var nextLabel: String? = nil

        if navLinks.count == 1 {
            let (key, label) = navLinks[0]
            if let currentEpNum, let navNum = extractLeadingNumber(label), navNum > currentEpNum {
                nextKey = key
                nextLabel = label
            } else {
                prevKey = key
                prevLabel = label
            }
        } else if navLinks.count >= 2 {
            let first = navLinks[0]
            let second = navLinks[1]
            if let firstNum = extractLeadingNumber(first.1),
               let secondNum = extractLeadingNumber(second.1),
               firstNum > secondNum {
                prevKey = second.0
                prevLabel = second.1
                nextKey = first.0
                nextLabel = first.1
            } else {
                prevKey = first.0
                prevLabel = first.1
                nextKey = second.0
                nextLabel = second.1
            }
        }

        return EpisodeStream(
            episodeKey: episodeKey,
            animeId: animeId,
            animeTitle: animeTitle,
            episodeLabel: episodeLabel,
            videoSources: videoSources,
            prevEpisodeKey: prevKey,
            prevEpisodeLabel: prevLabel,
            nextEpisodeKey: nextKey,
            nextEpisodeLabel: nextLabel
        )
    }

    private static func extractLeadingNumber(_ text: String) -> Double? {
        guard let capture = firstCapture(regex: episodeNumberRegex, in: text) else { return nil }
        return Double(capture)
    }

    private static func firstCapture(regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}
