import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("AnimeHeavenParser")
struct AnimeHeavenParserTests {

    @Test func parseHomeExtractsBannersSeasonScheduleAndPopular() {
        let html = """
        <!DOCTYPE html>
        <html><body>
        <div class='header bc1 c2'>
          <a href='new.php'><div class='headeritem ac'>New</div></a>
          <a class='headeritem2' href='2025fall.php' title='2025 Fall Shows'><div class='headeritem ac'>Fall</div></a>
          <a class='headeritem2' href='random.php' title='Random Show'><div class='headeritem ac'>Random</div></a>
        </div>
        <div class='banner slide c2'>
          <div id='slide' class='slide1 ani'>
            <a href='anime.php?0pqfl'><img class='bannerimg' src='image.php?g9lr9' alt='Black Clover 2nd Season'></a>
            <a href='anime.php?ugyek'><img class='bannerimg' src='image.php?vjl82' alt='Dandadan 2nd Season'></a>
          </div>
        </div>
        <div class='boldtext'>
          <div class='linetitle c'>Subbed Anime Schedule</div>
          <div class='chart bc1'>
            <div class='chartimg'><a href='anime.php?6zcxf'><img class='coverimg' src='image.php?abc12' alt='Ace of the Diamond'><div class='chartepm bc2 c1'>7</div></a></div>
            <div class='chartep c2'>7</div>
            <div class='chartinfo'>
              <div class='charttitle c'><a href='anime.php?6zcxf' class='c'>Ace of the Diamond: Act II 2nd Season</a></div>
              <div class='charttitlejp c'>Diamond no Ace</div>
              <div class='charttimer c2'>18 Hours 38 Min</div>
            </div>
          </div>
          <div class='popularbox bc1'>
            <a href='popular.php'><div class='boxitem2 boxitemv bc2 c1 center'>POPULAR</div></a>
            <div class='popularbox2'><a href='anime.php?kybuw'><img class='coverimg popularimg' src='image.php?puty1' alt='Tokyo Revengers'></a></div>
            <div class='popularbox2'><a href='anime.php?igk5o'><img class='coverimg popularimg' src='image.php?tv772' alt='The Apothecary Diaries 3rd Season'></a></div>
          </div>
          <div class='chart bc1'>
            <a href='2024summer.php'><div class='boxitem2 bc2 c1 center'>2024 Summer Anime</div></a>
          </div>
        </div>
        </body></html>
        """

        let feed = AnimeHeavenParser.parseHome(html: html)
        #expect(feed.banners.count == 2)
        #expect(feed.banners[0].animeId == "0pqfl")
        #expect(feed.banners[0].bannerImageUrl == "https://animeheaven.me/image.php?g9lr9")
        #expect(feed.seasonPath == "2025fall.php")
        #expect(feed.seasonLabel == "Fall")

        #expect(feed.scheduleItems.count == 1)
        let item = feed.scheduleItems[0]
        #expect(item.id == "6zcxf")
        #expect(item.title == "Ace of the Diamond: Act II 2nd Season")
        #expect(item.japaneseTitle == "Diamond no Ace")
        #expect(item.episodeLabel == "7")
        #expect(item.timerOrStatus == "18 Hours 38 Min")

        #expect(feed.popularItems.count == 2)
        #expect(feed.popularItems[0].id == "kybuw")
        #expect(feed.popularItems[0].title == "Tokyo Revengers")
    }

    @Test func parseChartPagePopularRanks() {
        let html = """
        <html><body>
        <div class='boldtext'>
          <div class='linetitle c'>Popular Today</div>
          <div class='chart bc1'>
            <div class='chartimg'><a href='anime.php?kybuw'><img class='coverimg' src='image.php?puty1' alt='Tokyo Revengers'></a></div>
            <div class='chartep c2'>1</div>
            <div class='chartinfo'>
              <div class='charttitle c'><a href='anime.php?kybuw'>Tokyo Revengers</a></div>
              <div class='charttitlejp c'>-</div>
              <div class='charttimer c2'><div class='popi bc2 c1'><img src='arrowu.svg' alt=''></div><div class='popi popt c'>+2</div></div>
            </div>
          </div>
          <div class='chart bc1'>
            <div class='chartimg'><a href='anime.php?6uopw'><img class='coverimg' src='image.php?3ks09' alt='Heavy Knight'></a></div>
            <div class='chartep c2'>5</div>
            <div class='chartinfo'>
              <div class='charttitle c'><a href='anime.php?6uopw'>Heavy Knight</a></div>
              <div class='charttitlejp c'>Tsuihou</div>
              <div class='charttimer c2'><div class='popi bc3 c1'><img src='arrowd.svg' alt=''></div><div class='popi popt c'>-4</div></div>
            </div>
          </div>
        </div>
        </body></html>
        """

        let result = AnimeHeavenParser.parseChartPage(html: html, isPopularRank: true)
        #expect(result.title == "Popular Today")
        #expect(result.items.count == 2)
        #expect(result.items[0].isPopularRank == true)
        #expect(result.items[0].rankDirection == .up)
        #expect(result.items[0].rankDelta == "+2")
        #expect(result.items[0].japaneseTitle == "")
        #expect(result.items[1].isPopularRank == true)
        #expect(result.items[1].rankDirection == .down)
        #expect(result.items[1].rankDelta == "-4")
    }

    @Test func parseFastSearchAndSimilarGrid() {
        let fastHtml = """
        <a class='ac' href='/anime.php?0pqfl'><div class='fastitem bc1 ac'><div class='fastimg'><img class='coverimg' src='/image.php?82gob' alt='Black Clover'></div><div class='fastname'>Black Clover</div></div></a>
        <a class='ac' href='/anime.php?7tq84'><div class='fastitem bc1 ac'><div class='fastimg'><img class='coverimg' src='/image.php?xq99f' alt='Black Torch'></div><div class='fastname'>Black Torch</div></div></a>
        """
        let fast = AnimeHeavenParser.parseFastSearch(html: fastHtml)
        #expect(fast.count == 2)
        #expect(fast[0].animeId == "0pqfl")
        #expect(fast[0].coverUrl == "https://animeheaven.me/image.php?82gob")

        let gridHtml = """
        <html><body>
          <div class='linetitle c'>Search Results</div>
          <div class='info3'>
            <div class='similarimg'>
              <a href='anime.php?abc12'><img class='coverimg' src='image.php?img1' alt='Frieren'></a>
              <div class='similarname'><a href='anime.php?abc12'>Frieren</a></div>
            </div>
          </div>
        </body></html>
        """
        let grid = AnimeHeavenParser.parseSimilarGrid(html: gridHtml)
        #expect(grid.title == "Search Results")
        #expect(grid.items.count == 1)
        #expect(grid.items[0].id == "abc12")
        #expect(grid.items[0].title == "Frieren")
    }

    @Test func parseAnimeDetail() {
        let html = """
        <html><body>
          <div class='banner'><img class='bannerimg' src='image.php?ban1'></div>
          <div class='infoimg'><img class='posterimg' src='image.php?pos1'></div>
          <div class='infotitle'>Frieren: Beyond Journey's End</div>
          <div class='infotitlejp'>Sousou no Frieren</div>
          <div class='infodes'>After a ten-year quest...</div>
          <div class='infotags'>
            <a href='tags.php?tag=Adventure'><div class='boxitem'>Adventure</div></a>
            <a href='tags.php?tag=Fantasy'><div class='boxitem'>Fantasy</div></a>
          </div>
          <div class='infoyear'>
            Episodes:<div class='inline c2'>28</div>
            Year:<div class='inline c2'>2023</div>
            Score:<div class='inline c2'>9.3</div>
          </div>
          <div class='info2'>Countdown: 2d 5h</div>
          <div class='linetitle2'>
            <a href='gate.php' id='ep2key' onclick="gate('ep2key')"><div class='watch1'>Ep</div><div class='watch2'>2</div><div class='watch1'>1d ago</div></a>
            <a href='gate.php' onclick="gate('ep1key')"><div class='watch1'>Ep</div><div class='watch2'>1</div><div class='watch1'>8d ago</div></a>
          </div>
          <div class='linetitle'>Similar Shows</div>
          <div class='info3'>
            <div class='similarimg'>
              <a href='anime.php?sim1'><img class='coverimg' src='image.php?simg1' alt='Mushishi'></a>
              <div class='similarname'><a href='anime.php?sim1'>Mushishi</a></div>
            </div>
          </div>
        </body></html>
        """
        let detail = AnimeHeavenParser.parseAnimeDetail(animeId: "frieren1", html: html)
        #expect(detail.id == "frieren1")
        #expect(detail.title == "Frieren: Beyond Journey's End")
        #expect(detail.japaneseTitle == "Sousou no Frieren")
        #expect(detail.tags == ["Adventure", "Fantasy"])
        #expect(detail.episodesLabel == "28")
        #expect(detail.year == "2023")
        #expect(detail.score == "9.3")
        #expect(detail.countdownLabel == "Countdown: 2d 5h")
        #expect(detail.episodes.count == 2)
        #expect(detail.episodes[0].key == "ep2key")
        #expect(detail.episodes[0].numberLabel == "2")
        #expect(detail.episodes[0].releaseAge == "1d ago")
        #expect(detail.episodes[1].key == "ep1key")
        #expect(detail.similarShows.count == 1)
        #expect(detail.similarShows[0].id == "sim1")
    }

    @Test func parseGatePageExtractsSourcesAndPrevNext() {
        let html = """
        <html><body>
          <div class='linetitle3'><a href='anime.php?abc12'>Frieren</a> Episode 5</div>
          <video id='vid'>
            <source src='https://v1.cdn.test/ep5.mp4?t=1' type='video/mp4'>
            <source src='https://v2.cdn.test/ep5.mp4?t=2' type='video/mp4'>
            <source src='https://v1.cdn.test/ep5.mp4?t=1' type='video/mp4'>
          </video>
          <div class='linetitle2'>
            <a href='gate.php' onclick="gate('ep6key')"><div class='boxitem'>Episode 6</div></a>
            <a href='gate.php' onclick="gate('ep4key')"><div class='boxitem'>Episode 4</div></a>
          </div>
        </body></html>
        """
        let stream = AnimeHeavenParser.parseGatePage(episodeKey: "ep5key", html: html)
        #expect(stream.episodeKey == "ep5key")
        #expect(stream.animeId == "abc12")
        #expect(stream.animeTitle == "Frieren")
        #expect(stream.episodeLabel == "Episode 5")
        #expect(stream.videoSources == [
            "https://v1.cdn.test/ep5.mp4?t=1",
            "https://v2.cdn.test/ep5.mp4?t=2"
        ])
        #expect(stream.prevEpisodeKey == "ep4key")
        #expect(stream.nextEpisodeKey == "ep6key")
    }

    @Test func normalizeUrlHandlesAllSchemes() {
        #expect(AnimeHeavenParser.normalizeUrl("image.php?1") == "https://animeheaven.me/image.php?1")
        #expect(AnimeHeavenParser.normalizeUrl("/image.php?2") == "https://animeheaven.me/image.php?2")
        #expect(AnimeHeavenParser.normalizeUrl("//cdn.test/a.mp4") == "https://cdn.test/a.mp4")
        #expect(AnimeHeavenParser.normalizeUrl("https://a.test/x.mp4") == "https://a.test/x.mp4")
        #expect(AnimeHeavenParser.normalizeUrl(nil) == "")
    }
}
