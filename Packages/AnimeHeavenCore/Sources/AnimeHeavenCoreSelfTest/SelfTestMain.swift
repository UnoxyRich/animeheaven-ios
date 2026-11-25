import Foundation
import AnimeHeavenCore

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) throws {
    if !condition() {
        throw TestFailure(message: "\(file):\(line) — \(message)")
    }
}

private actor SelfTestGateway: SearchGateway {
    var recent: [String] = ["frieren"]

    func fastSearch(query: String) async throws -> [FastSearchItem] {
        [FastSearchItem(animeId: "id1", title: "Match: \(query)", coverUrl: "https://example.com/1.jpg")]
    }

    func fullSearch(query: String) async throws -> ChartFeedResult {
        recent.insert(query, at: 0)
        return ChartFeedResult(title: "Search: \(query)", items: [AnimeCard(id: "id1", title: "Full: \(query)")])
    }

    func getRecentSearches() async -> [String] { recent }
    func deleteRecentSearch(query: String) async { recent.removeAll { $0 == query } }
}

private final class TestStats {
    var passed = 0
    var failed = 0
}

@main
struct AnimeHeavenCoreSelfTestMain {
    static func main() async {
        let stats = TestStats()

        func run(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                stats.passed += 1
                print("  PASS  \(name)")
            } catch {
                stats.failed += 1
                print("  FAIL  \(name): \(error)")
            }
        }

        print("Running AnimeHeavenCore self-test suite...")

        await run("Parser: parseHome extracts banners, season, schedule, popular") {
            let html = """
            <!DOCTYPE html><html><body>
            <div class='header bc1 c2'>
              <a class='headeritem2' href='2025fall.php'><div class='headeritem ac'>Fall</div></a>
              <a class='headeritem2' href='random.php'><div class='headeritem ac'>Random</div></a>
            </div>
            <div class='banner slide c2'><div id='slide'>
              <a href='anime.php?0pqfl'><img class='bannerimg' src='image.php?g9lr9' alt='Black Clover'></a>
            </div></div>
            <div class='boldtext'>
              <div class='chart bc1'>
                <div class='chartimg'><a href='anime.php?6zcxf'><img class='coverimg' src='image.php?abc12' alt='Ace'></a></div>
                <div class='chartep c2'>7</div>
                <div class='chartinfo'>
                  <div class='charttitle c'><a href='anime.php?6zcxf'>Ace of the Diamond</a></div>
                  <div class='charttitlejp c'>Diamond no Ace</div>
                  <div class='charttimer c2'>18 Hours</div>
                </div>
              </div>
              <div class='popularbox bc1'>
                <div class='popularbox2'><a href='anime.php?kybuw'><img class='coverimg' src='image.php?puty1' alt='Tokyo Revengers'></a></div>
              </div>
              <div class='chart bc1'><a href='2024summer.php'>Footer</a></div>
            </div></body></html>
            """
            let feed = AnimeHeavenParser.parseHome(html: html)
            try check(feed.banners.count == 1 && feed.banners[0].animeId == "0pqfl", "banner parse mismatch")
            try check(feed.seasonPath == "2025fall.php" && feed.seasonLabel == "Fall", "season parse mismatch")
            try check(feed.scheduleItems.count == 1 && feed.scheduleItems[0].episodeLabel == "7", "schedule parse mismatch")
            try check(feed.popularItems.count == 1 && feed.popularItems[0].id == "kybuw", "popular parse mismatch")
        }

        await run("Parser: parseChartPage popular ranks + arrows") {
            let html = """
            <html><body><div class='boldtext'>
              <div class='linetitle c'>Popular Today</div>
              <div class='chart bc1'>
                <div class='chartimg'><a href='anime.php?kybuw'><img class='coverimg' src='image.php?p1'></a></div>
                <div class='chartep c2'>1</div>
                <div class='chartinfo'>
                  <div class='charttitle c'><a href='anime.php?kybuw'>Tokyo Revengers</a></div>
                  <div class='charttitlejp c'>-</div>
                  <div class='charttimer c2'><div class='popi'><img src='arrowu.svg'></div><div class='popi popt'>+2</div></div>
                </div>
              </div>
            </div></body></html>
            """
            let res = AnimeHeavenParser.parseChartPage(html: html, isPopularRank: true)
            try check(res.title == "Popular Today" && res.items.count == 1, "chart title/count mismatch")
            try check(res.items[0].rankDirection == .up && res.items[0].rankDelta == "+2", "rank mismatch")
            try check(res.items[0].isPopularRank, "popular chart item should set isPopularRank")
            try check(res.items[0].japaneseTitle.isEmpty, "dash jp title should normalize empty")

            // Verify legacy cached AnimeCard JSON without `isPopularRank` decodes cleanly
            let legacyJson = #"{"id":"a1","title":"Show","japaneseTitle":"","coverUrl":"","episodeLabel":"3","timerOrStatus":"","rankDirection":"UP"}"#
            let decoded = try JSONDecoder().decode(AnimeCard.self, from: Data(legacyJson.utf8))
            try check(decoded.isPopularRank && decoded.rankDirection == .up, "legacy AnimeCard decoding mismatch")
        }

        await run("Parser: parseFastSearch + parseSimilarGrid + parseAnimeDetail + parseGatePage") {
            let fast = AnimeHeavenParser.parseFastSearch(
                html: "<a href='/anime.php?0pqfl'><div class='fastimg'><img src='/image.php?1'></div><div class='fastname'>Black Clover</div></a>"
            )
            try check(fast.count == 1 && fast[0].animeId == "0pqfl", "fast search mismatch")

            let gateHtml = """
            <html><body>
              <div class='linetitle3'><a href='anime.php?abc12'>Frieren</a> Episode 5</div>
              <video id='vid'>
                <source src='https://v1.cdn.test/ep5.mp4?t=1'>
                <source src='https://v2.cdn.test/ep5.mp4?t=2'>
              </video>
              <div class='linetitle2'>
                <a href='gate.php' onclick="gate('ep6key')"><div class='boxitem'>Episode 6</div></a>
                <a href='gate.php' onclick="gate('ep4key')"><div class='boxitem'>Episode 4</div></a>
              </div>
            </body></html>
            """
            let stream = AnimeHeavenParser.parseGatePage(episodeKey: "ep5key", html: gateHtml)
            try check(stream.videoSources.count == 2, "sources count")
            try check(stream.prevEpisodeKey == "ep4key" && stream.nextEpisodeKey == "ep6key", "prev/next order")
        }

        await run("MirrorHealthTracker: cooldown, EWMA throughput ranking, stub demotion") {
            final class Clock: @unchecked Sendable { var now: Int64 = 10_000 }
            let clock = Clock()
            let tracker = MirrorHealthTracker(clockMs: { clock.now })
            let dead = "https://dead.cdn/v.mp4"
            let slow = "https://slow.cdn/v.mp4"
            let fast = "https://fast.cdn/v.mp4"
            let stub = "https://stub.cdn/v.mp4"

            tracker.recordFailure(url: dead)
            tracker.recordSuccess(url: slow, latencyMs: 80)
            tracker.recordThroughput(url: slow, bytesTransferred: 256 * 1024, durationMs: 2_000)
            tracker.recordSuccess(url: fast, latencyMs: 120)
            tracker.recordThroughput(url: fast, bytesTransferred: 1024 * 1024, durationMs: 500)
            tracker.recordStubVideo(url: stub)

            let ranked = tracker.rankMirrors([stub, dead, slow, fast])
            try check(ranked == [fast, slow, dead, stub], "unexpected ranking: \(ranked)")
        }

        await run("DiskChunkCache: shared episode key, headers, moov detection, initial window") {
            let len: Int64 = 140 * 1024 * 1024
            let k1 = DiskChunkCache.buildEpisodeCacheKey(episodeKey: "ep99", contentLength: len, fallbackUrl: "https://m1/a.mp4")
            let k2 = DiskChunkCache.buildEpisodeCacheKey(episodeKey: "ep99", contentLength: len, fallbackUrl: "https://m2/b.mp4")
            try check(k1 == "ep:ep99:\(len)" && k1 == k2, "shared cache key mismatch")
            try check(DiskChunkCache.parseTotalLengthFromHeaders(contentRange: "bytes 0-0/123456", contentLength: "1", statusCode: 206) == 123_456, "range header parse")
            try check(DiskChunkCache.containsMoovBox(Data([0, 0, 0, 24, 0x6D, 0x6F, 0x6F, 0x76, 0, 0])), "moov true")
            try check(!DiskChunkCache.containsMoovBox(Data([0, 0, 0, 24, 0x6D, 0x64, 0x61, 0x74, 0, 0])), "moov false")
            let chunks = DiskChunkCache.buildInitialWindowChunks(
                totalLength: len, targetBytes: 2 * 1024 * 1024,
                resumePositionMs: 600_000, estimatedDurationMs: 1_200_000, opEndMs: 90_000
            )
            try check(chunks.first == 0 && chunks.count >= 5, "initial window")
        }

        await run("LruCache: evicts least recently used entry") {
            let cache = LruCache<String, Int>(maxEntries: 2)
            cache.set("a", value: 1)
            cache.set("b", value: 2)
            _ = cache.get("a")
            cache.set("c", value: 3)
            try check(cache.get("a") == 1 && cache.get("b") == nil && cache.get("c") == 3, "LRU order")
        }

        await run("SQLiteDatabase: bookmarks, latestWatchProgressPerAnime, search history, web cache prune") {
            let db = try SQLiteDatabase(path: ":memory:")
            await db.upsertBookmark(BookmarkRecord(animeId: "a1", title: "S1", coverUrl: "u1", lastEpisodeLabel: "1", addedAt: 100))
            await db.upsertBookmark(BookmarkRecord(animeId: "a2", title: "S2", coverUrl: "u2", lastEpisodeLabel: "2", addedAt: 200))
            let bms = await db.getAllBookmarks()
            try check(bms.map(\.animeId) == ["a2", "a1"], "bookmark ordering")

            await db.upsertWatchProgress(WatchProgressRecord(
                episodeKey: "ep1", animeId: "showA", animeTitle: "A", coverUrl: "c",
                episodeLabel: "1", positionMs: 1_200_000, durationMs: 1_400_000, isWatched: true,
                nextEpisodeKey: "ep2", nextEpisodeLabel: "Ep 2", updatedAt: 100
            ))
            await db.upsertWatchProgress(WatchProgressRecord(
                episodeKey: "ep2", animeId: "showA", animeTitle: "A", coverUrl: "c",
                episodeLabel: "2", positionMs: 300_000, durationMs: 1_400_000, isWatched: false,
                nextEpisodeKey: "ep3", nextEpisodeLabel: "Ep 3", updatedAt: 300
            ))
            let latest = await db.getLatestWatchProgressPerAnime(limit: 10)
            try check(latest.count == 1 && latest[0].episodeKey == "ep2", "latest per anime")

            await db.upsertWebCache(WebCacheRecord(cacheKey: "old", payload: "1", fetchedAt: 100))
            await db.upsertWebCache(WebCacheRecord(cacheKey: "new", payload: "2", fetchedAt: 500))
            await db.pruneWebCacheOlderThan(cutoffMs: 250)
            let oldVal = await db.getWebCache(cacheKey: "old")
            let newVal = await db.getWebCache(cacheKey: "new")
            try check(oldVal == nil && newVal != nil, "web cache pruning")
        }

        await run("RequestCoalescer: deduplicates & survives caller cancellation") {
            let coalescer = RequestCoalescer<String>()
            actor Counter { var count = 0; func inc() { count += 1 } }
            let counter = Counter()
            let t1 = Task {
                try await coalescer.getOrFetch(key: "k") {
                    await counter.inc()
                    try await Task.sleep(for: .milliseconds(60))
                    return "ok"
                }
            }
            let t2 = Task {
                try await coalescer.getOrFetch(key: "k") {
                    await counter.inc()
                    return "dup"
                }
            }
            try await Task.sleep(for: .milliseconds(10))
            t1.cancel()
            let v2 = try await t2.value
            let n = await counter.count
            try check(v2 == "ok" && n == 1, "coalescer count=\(n) val=\(v2)")
        }

        await run("WatchProgressLogic & SkipPromptLogic & MirrorQueueState") {
            try check(WatchProgressLogic.isEpisodeWatched(positionMs: 850_000, durationMs: 1_000_000), "85% watched")
            try check(WatchProgressLogic.resolveResumePositionMs(positionMs: 930_000, durationMs: 1_000_000) == 0, "92% reset")
            let ed = SkipSegment(type: .ed, startMs: 1_340_000, endMs: 1_430_000, isExact: true)
            let action = SkipPromptLogic.resolveSkipAction(
                segment: ed, currentPositionMs: 1_350_000, durationMs: 1_440_000,
                fallbackSkipSeconds: 85, hasNextEpisode: true
            )
            try check(action.kind == .nextEpisode, "ed near end should advance episode")

            let q = MirrorQueueState(sources: ["u1", "u2"]).advanceOnError().advanceOnError()
            try check(q.exhausted, "mirror queue exhaustion")
        }

        await run("LocalStreamProxyServer: live NWListener HTTP 206 cross-chunk range + HEAD + 403 token check") {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ah-selftest-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cache = DiskChunkCache(rootDirectory: tempDir, maxCacheBytes: 16 * 1024 * 1024)
            let booster = StreamingChunkBooster(diskCache: cache)
            let proxy = LocalStreamProxyServer(booster: booster)
            defer { Task { await proxy.stop() } }

            let chunkSize = Int(DiskChunkCache.chunkSizeBytes)
            let chunk0 = Data((0..<chunkSize).map { UInt8($0 % 251) })
            let chunk1 = Data((0..<chunkSize).map { UInt8(($0 + 77) % 251) })
            let totalLength = Int64(chunk0.count + chunk1.count)
            let cacheKey = "ep:test123:\(totalLength)"

            await cache.writeChunk(cacheKey: cacheKey, chunkOffset: 0, data: chunk0)
            await cache.writeChunk(cacheKey: cacheKey, chunkOffset: DiskChunkCache.chunkSizeBytes, data: chunk1)

            let localURL = try await proxy.registerSession(StreamSessionDescriptor(
                sessionId: "sess1",
                cacheKey: cacheKey,
                episodeKey: "test123",
                mirrors: ["https://unused.local/v.mp4"],
                totalLength: totalLength
            ))

            let rangeStart = chunkSize - 16
            let rangeEnd = chunkSize + 31
            var rangeReq = URLRequest(url: localURL)
            rangeReq.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")

            let (data, resp) = try await URLSession.shared.data(for: rangeReq)
            let http = resp as? HTTPURLResponse
            try check(http?.statusCode == 206, "expected 206 got \(String(describing: http?.statusCode))")
            try check(http?.value(forHTTPHeaderField: "Content-Range") == "bytes \(rangeStart)-\(rangeEnd)/\(totalLength)", "Content-Range mismatch")
            var expected = Data()
            expected.append(chunk0.subdata(in: (chunkSize - 16)..<chunkSize))
            expected.append(chunk1.subdata(in: 0..<32))
            try check(data == expected, "cross-chunk payload mismatch")

            var headReq = URLRequest(url: localURL)
            headReq.httpMethod = "HEAD"
            let (headData, headResp) = try await URLSession.shared.data(for: headReq)
            try check((headResp as? HTTPURLResponse)?.statusCode == 200 && headData.isEmpty, "HEAD response mismatch")

            let badURL = URL(string: "http://127.0.0.1:\(localURL.port ?? 0)/stream/wrongtoken/sess1.mp4")!
            let (_, badResp) = try await URLSession.shared.data(from: badURL)
            try check((badResp as? HTTPURLResponse)?.statusCode == 403, "expected 403 on bad token")
        }

        await run("SearchViewModel & SettingsStore: @MainActor @Observable flows") {
            try await MainActor.run {
                let suite = "selftest.settings.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let s1 = SettingsStore(defaults: defaults)
                s1.themeId = .darkMagenta
                s1.doubleTapSeekSeconds = 15
                s1.multilingualSearchEnabled = false
                let s2 = SettingsStore(defaults: defaults)
                try check(
                    s2.themeId == .darkMagenta && s2.doubleTapSeekSeconds == 15 && !s2.multilingualSearchEnabled,
                    "SettingsStore persistence"
                )
            }

            let vm = await MainActor.run { SearchViewModel(gateway: SelfTestGateway(), debounceMs: 10) }
            await vm.loadRecentSearches()
            await MainActor.run { vm.onQueryChanged("bleach") }
            try await Task.sleep(for: .milliseconds(60))
            let fastTitle = await MainActor.run { vm.fastResults.first?.title }
            try check(fastTitle == "Match: bleach", "fast search mismatch: \(String(describing: fastTitle))")
            await MainActor.run { vm.submitFullSearch() }
            try await Task.sleep(for: .milliseconds(60))
            let fullTitle = await MainActor.run { vm.fullResults.first?.title }
            try check(fullTitle == "Full: bleach", "full search mismatch: \(String(describing: fullTitle))")
            await MainActor.run { vm.selectCandidateQuery("Bleach: Thousand-Year Blood War") }
            try await Task.sleep(for: .milliseconds(60))
            let switchedTitle = await MainActor.run { vm.fullResults.first?.title }
            let matched = await MainActor.run { vm.matchedQuery }
            try check(
                matched == "Bleach: Thousand-Year Blood War" && switchedTitle == "Full: Bleach: Thousand-Year Blood War",
                "candidate switch mismatch: \(String(describing: switchedTitle))"
            )
        }

        await run("MultilingualQueryNormalizer: script detection, Kana->Romaji & variants") {
            let cn = MultilingualQueryNormalizer.analyze("葬送的芙莉莲")
            try check(cn.script == .hanCJK && cn.wikidataLangHint == "zh", "cn script mismatch")
            let jp = MultilingualQueryNormalizer.analyze("葬送のフリーレン")
            try check(jp.script == .hanCJK && jp.wikidataLangHint == "ja", "jp script mismatch")
            let ko = MultilingualQueryNormalizer.analyze("진격의 거인")
            try check(ko.script == .otherNonLatin && ko.wikidataLangHint == "ko", "ko script mismatch")
            let ru = MultilingualQueryNormalizer.analyze("Атака титанов")
            try check(ru.script == .otherNonLatin && ru.wikidataLangHint == "ru", "ru script mismatch")
            let kana = MultilingualQueryNormalizer.analyze("しんげき の きょじん")
            try check(kana.script == .kanaOnly && kana.kanaRomajiCandidates.contains("shingeki no kyojin"), "kana romaji mismatch")
            let macron = MultilingualQueryNormalizer.analyze("Sōsō no Furīren")
            try check(macron.normalizedLatin == "Soso no Furiren" && macron.romajiVariants.contains("sousou no furiren"), "macron/variant mismatch")
            let soma = MultilingualQueryNormalizer.generateRomajiVariants("Shokugeki no Soma")
            try check(soma.contains("shokugeki no souma"), "soma variant mismatch: \(soma)")
            let deduped = MultilingualQueryNormalizer.rankAndDedupe([
                "葬送のフリーレン", "Sousou no Frieren", "sousou no frieren!", "Frieren: Beyond Journey’s End"
            ])
            try check(deduped == ["Sousou no Frieren", "Frieren: Beyond Journey's End"], "dedupe mismatch: \(deduped)")
        }

        await run("Mp4MoovSeekParser: faststart VBR & non-faststart tail moov + EpisodeVideoIndex") {
            func appendUInt32(_ d: inout Data, _ v: UInt32) {
                var be = v.bigEndian
                withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
            }
            func appendInt64(_ d: inout Data, _ v: Int64) {
                var be = v.bigEndian
                withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
            }
            func boxHdr(_ type: String, _ size: Int64) -> Data {
                var out = Data()
                if size <= Int64(UInt32.max) {
                    appendUInt32(&out, UInt32(size))
                    out.append(Data(type.utf8))
                } else {
                    appendUInt32(&out, 1)
                    out.append(Data(type.utf8))
                    appendInt64(&out, size)
                }
                return out
            }
            func box(_ type: String, _ payload: Data) -> Data {
                var out = boxHdr(type, Int64(8 + payload.count))
                out.append(payload)
                return out
            }
            func fullBox(_ type: String, _ payload: Data) -> Data {
                var body = Data()
                appendUInt32(&body, 0)
                body.append(payload)
                return box(type, body)
            }
            func makeMoov(sampleSizes: [Int], syncSamples: [Int], firstChunkOffset: Int64) -> Data {
                var mvhdP = Data()
                appendUInt32(&mvhdP, 0); appendUInt32(&mvhdP, 0)
                appendUInt32(&mvhdP, 1000); appendUInt32(&mvhdP, UInt32(sampleSizes.count * 1000))
                mvhdP.append(Data(repeating: 0, count: 80))
                let mvhd = fullBox("mvhd", mvhdP)

                var sttsP = Data()
                appendUInt32(&sttsP, 1); appendUInt32(&sttsP, UInt32(sampleSizes.count)); appendUInt32(&sttsP, 1000)
                var stssP = Data()
                appendUInt32(&stssP, UInt32(syncSamples.count))
                for s in syncSamples { appendUInt32(&stssP, UInt32(s)) }
                var stscP = Data()
                appendUInt32(&stscP, 1); appendUInt32(&stscP, 1); appendUInt32(&stscP, 1); appendUInt32(&stscP, 1)
                var stszP = Data()
                appendUInt32(&stszP, 0); appendUInt32(&stszP, UInt32(sampleSizes.count))
                for sz in sampleSizes { appendUInt32(&stszP, UInt32(sz)) }
                var stcoP = Data()
                appendUInt32(&stcoP, UInt32(sampleSizes.count))
                var off = firstChunkOffset
                for sz in sampleSizes {
                    appendUInt32(&stcoP, UInt32(off))
                    off += Int64(sz)
                }
                var stblBody = Data()
                stblBody.append(fullBox("stts", sttsP))
                stblBody.append(fullBox("stss", stssP))
                stblBody.append(fullBox("stsc", stscP))
                stblBody.append(fullBox("stsz", stszP))
                stblBody.append(fullBox("stco", stcoP))
                let stbl = box("stbl", stblBody)

                var mdhdP = Data()
                appendUInt32(&mdhdP, 0); appendUInt32(&mdhdP, 0)
                appendUInt32(&mdhdP, 1000); appendUInt32(&mdhdP, UInt32(sampleSizes.count * 1000)); appendUInt32(&mdhdP, 0)
                var hdlrP = Data()
                appendUInt32(&hdlrP, 0); hdlrP.append(Data("vide".utf8)); hdlrP.append(Data(repeating: 0, count: 12))
                var mdiaBody = Data()
                mdiaBody.append(fullBox("mdhd", mdhdP))
                mdiaBody.append(fullBox("hdlr", hdlrP))
                mdiaBody.append(box("minf", stbl))
                var moovBody = Data()
                moovBody.append(mvhd)
                moovBody.append(box("trak", box("mdia", mdiaBody)))
                return box("moov", moovBody)
            }

            // 1. Faststart VBR MP4 (24 min: first 12m @ 20 KB/s, last 12m @ 140 KB/s)
            let vbrSizes = (0..<1440).map { $0 < 720 ? 20_000 : 140_000 }
            let syncs = Array(stride(from: 1, through: 1440, by: 5))
            let ftyp = box("ftyp", Data("isom\0\0\u{2}\0isommp41".utf8))
            let approxMoov = makeMoov(sampleSizes: vbrSizes, syncSamples: syncs, firstChunkOffset: Int64(ftyp.count) + 30_000)
            let mdatStart = Int64(ftyp.count + approxMoov.count + 8)
            let moov = makeMoov(sampleSizes: vbrSizes, syncSamples: syncs, firstChunkOffset: mdatStart)
            let mdatPayload = vbrSizes.reduce(Int64(0)) { $0 + Int64($1) }
            let totalLen = Int64(ftyp.count + moov.count) + 8 + mdatPayload
            var head = Data()
            head.append(ftyp); head.append(moov); head.append(boxHdr("mdat", 8 + mdatPayload))

            let loc = Mp4MoovSeekParser.inspectTopLevelBoxes(headData: head, totalLength: totalLen)
            try check(loc?.offset == Int64(ftyp.count) && loc?.isAtTail == false, "faststart moov location mismatch")
            let parsed = Mp4MoovSeekParser.parseMoovIndex(
                episodeKey: "ep_vbr", contentLength: totalLen, moovFileOffset: loc!.offset,
                data: head, dataBaseFileOffset: 0
            )
            try check(parsed?.durationMs == 1_440_000, "duration mismatch")
            try check(parsed?.resolveByteOffset(targetMs: 600_000) == mdatStart + 600 * 20_000, "exact VBR resume mismatch")
            try check(parsed?.resolveByteOffset(targetMs: 85_000) == mdatStart + 85 * 20_000, "exact OP offset mismatch")

            let encoded = try JSONEncoder().encode(parsed!)
            let decoded = try JSONDecoder().decode(EpisodeVideoIndex.self, from: encoded)
            try check(decoded == parsed, "EpisodeVideoIndex Codable round-trip mismatch")

            let win = DiskChunkCache.buildInitialWindowChunks(
                totalLength: totalLen, targetBytes: 2 * 1024 * 1024,
                resumePositionMs: 600_000, estimatedDurationMs: 1_440_000, opEndMs: 85_000,
                videoIndex: parsed
            )
            try check(win.contains(DiskChunkCache.alignChunkStart(mdatStart + 600 * 20_000)), "window should include exact VBR keyframe")

            // 2. Non-faststart tail moov MP4
            let tailSizes = Array(repeating: 100_000, count: 600)
            let tailSyncs = Array(stride(from: 1, through: 600, by: 5))
            let tailMdatStart = Int64(ftyp.count + 8)
            let tailMoov = makeMoov(sampleSizes: tailSizes, syncSamples: tailSyncs, firstChunkOffset: tailMdatStart)
            let tailPayload = tailSizes.reduce(Int64(0)) { $0 + Int64($1) }
            let tailMoovOffset = Int64(ftyp.count) + 8 + tailPayload
            let tailTotal = tailMoovOffset + Int64(tailMoov.count)
            var tailHead = Data()
            tailHead.append(ftyp); tailHead.append(boxHdr("mdat", 8 + tailPayload)); tailHead.append(Data(repeating: 0, count: 512))

            let tailLoc = Mp4MoovSeekParser.inspectTopLevelBoxes(headData: tailHead, totalLength: tailTotal)
            try check(tailLoc?.offset == tailMoovOffset && tailLoc?.isAtTail == true, "tail moov location mismatch")
            let tailParsed = Mp4MoovSeekParser.parseMoovIndex(
                episodeKey: "ep_tail", contentLength: tailTotal, moovFileOffset: tailLoc!.offset,
                data: tailMoov, dataBaseFileOffset: tailLoc!.offset
            )
            try check(tailParsed?.isMoovAtTail == true && tailParsed?.durationMs == 600_000, "tail moov parse mismatch")
        }

        await run("DiskChunkCache: Tier-A eviction protection, readRange, lengths persistence & 2 GB cap") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ah-selftest-tier-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let chunkSize = Int(DiskChunkCache.chunkSizeBytes)
            let cache = DiskChunkCache(rootDirectory: dir, maxCacheBytes: Int64(chunkSize) * 5)
            await cache.warmUp()

            let hotKey = "ep:hot:100000000"
            await cache.markHotWindow(cacheKey: hotKey, offsets: [0, Int64(chunkSize)])
            await cache.writeChunk(cacheKey: hotKey, chunkOffset: 0, data: Data(repeating: 0xAA, count: chunkSize))
            await cache.writeChunk(cacheKey: hotKey, chunkOffset: Int64(chunkSize), data: Data(repeating: 0xBB, count: chunkSize))

            let cross = await cache.readRange(cacheKey: hotKey, startOffset: Int64(chunkSize - 4), length: 8)
            try check(cross == Data([0xAA, 0xAA, 0xAA, 0xAA, 0xBB, 0xBB, 0xBB, 0xBB]), "cross-chunk readRange mismatch")

            let watchedKey = "ep:watched:100000000"
            for i in 0..<5 {
                await cache.writeChunk(
                    cacheKey: watchedKey,
                    chunkOffset: Int64(i) * Int64(chunkSize),
                    data: Data(repeating: UInt8(i), count: chunkSize)
                )
            }
            let has0 = await cache.hasChunk(cacheKey: hotKey, chunkOffset: 0)
            let has1 = await cache.hasChunk(cacheKey: hotKey, chunkOffset: Int64(chunkSize))
            let protBefore = await cache.protectedSizeBytes()
            try check(has0, "Tier-A chunk 0 must survive")
            try check(has1, "Tier-A chunk 1 must survive")
            try check(protBefore == Int64(chunkSize * 2), "protected bytes mismatch")

            await cache.demoteTrailingChunks(cacheKey: hotKey, behindOffset: Int64(chunkSize))
            let protAfter = await cache.protectedSizeBytes()
            try check(protAfter == Int64(chunkSize), "demote trailing mismatch")

            await cache.recordEpisodeLength(episodeKey: "ep_len", contentLength: 142_000_000)
            let reloaded = DiskChunkCache(rootDirectory: dir, maxCacheBytes: Int64(chunkSize) * 5)
            let knownLen = await reloaded.knownContentLength(episodeKey: "ep_len")
            try check(knownLen == 142_000_000, "persisted length mismatch")

            let gb: Int64 = 1024 * 1024 * 1024
            try check(DiskChunkCache.calculateVideoCacheMaxBytes(usableSpaceBytes: 2 * gb) == 512 * 1024 * 1024, "2GB disk -> 512MB")
            try check(DiskChunkCache.calculateVideoCacheMaxBytes(usableSpaceBytes: 6 * gb) == 1 * gb, "6GB disk -> 1GB")
            try check(DiskChunkCache.calculateVideoCacheMaxBytes(usableSpaceBytes: 16 * gb) == 2 * gb, "16GB disk -> 2GB")
            try check(DiskChunkCache.calculateVideoCacheMaxBytes(usableSpaceBytes: 1 * gb) == 256 * 1024 * 1024, "quarter cap")
        }

        await run("NetworkPolicy: strict Wi-Fi-only gating on metered connections") {
            try check(NetworkPolicy.resolveEffectiveMode(configured: .aggressive, metered: true) == .dataSaver, "metered aggressive -> dataSaver")
            try check(NetworkPolicy.resolveEffectiveMode(configured: .balanced, metered: true) == .dataSaver, "metered balanced -> dataSaver")
            try check(NetworkPolicy.resolveEffectiveMode(configured: .aggressive, metered: false) == .aggressive, "unmetered aggressive")
            try check(NetworkPolicy.resolveEffectiveMode(configured: .balanced, metered: false) == .balanced, "unmetered balanced")
        }

        await run("SQLiteDatabase: recent streams, video meta, and ordered bookmark IDs") {
            let db = try SQLiteDatabase(path: ":memory:")
            await db.upsertBookmark(BookmarkRecord(animeId: "b1", title: "B1", coverUrl: "", lastEpisodeLabel: "1", addedAt: 100))
            await db.upsertBookmark(BookmarkRecord(animeId: "b2", title: "B2", coverUrl: "", lastEpisodeLabel: "2", addedAt: 200))
            let bmIds = await db.getOrderedBookmarkIds(limit: 10)
            try check(bmIds == ["b2", "b1"], "ordered bookmark IDs mismatch")

            await db.upsertWebCache(WebCacheRecord(cacheKey: "gate:ep1", payload: "", fetchedAt: 100, parsedJson: "{}"))
            await db.upsertWebCache(WebCacheRecord(cacheKey: "vmeta:ep1", payload: "", fetchedAt: 200, parsedJson: "{}"))
            let streams = await db.getRecentCachedStreams(limit: 10)
            let metas = await db.getRecentVideoMeta(limit: 10)
            try check(streams.map(\.cacheKey) == ["gate:ep1"], "recent streams mismatch")
            try check(metas.map(\.cacheKey) == ["vmeta:ep1"], "recent vmeta mismatch")
        }

        print("\nSelf-Test Summary: \(stats.passed) passed, \(stats.failed) failed")
        if stats.failed > 0 {
            exit(1)
        }
    }
}
