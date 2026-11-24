import Foundation
import Testing
@testable import AnimeHeavenCore

@Test func clearingLRUReleasesAllLinkedValues() {
    final class Value: Sendable {}
    let cache = LruCache<Int, Value>(maxEntries: 4)
    weak var first: Value?
    weak var second: Value?
    do {
        let a = Value()
        let b = Value()
        first = a
        second = b
        cache.set(1, value: a)
        cache.set(2, value: b)
    }
    #expect(first != nil)
    #expect(second != nil)
    cache.clear()
    #expect(first == nil)
    #expect(second == nil)
}

@Test func validatesExactRangeBeforeCaching() throws {
    let url = try #require(URL(string: "https://example.com/video.mp4"))
    func response(_ code: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers))
    }
    let full = try response(200, ["Content-Type": "video/mp4", "Content-Length": "2048"])
    #expect(StreamingChunkBooster.validatedRangeLength(full, start: 0, end: 511) == 2048)
    #expect(StreamingChunkBooster.validatedRangeLength(full, start: 512, end: 1023) == nil)
    let wrong = try response(206, ["Content-Range": "bytes 0-511/2048"])
    #expect(StreamingChunkBooster.validatedRangeLength(wrong, start: 512, end: 1023) == nil)
    let valid = try response(206, ["Content-Range": "bytes 512-1023/2048"])
    #expect(StreamingChunkBooster.validatedRangeLength(valid, start: 512, end: 1023) == 2048)
    let html = try response(200, ["Content-Type": "text/html", "Content-Length": "2048"])
    #expect(StreamingChunkBooster.validatedRangeLength(html, start: 0, end: 511) == nil)
}

@Test func aniListOnlyCachesConfirmedMisses() {
    let body = Data(#"{"data":{"Media":{"idMal":null}}}"#.utf8)
    #expect(SkipTimesClient.cacheableMalId(status: 200, data: body) == -1)
    #expect(SkipTimesClient.cacheableMalId(status: 404, data: Data()) == -1)
    #expect(SkipTimesClient.cacheableMalId(status: 200, data: Data("{}".utf8)) == nil)
    #expect(SkipTimesClient.cacheableMalId(status: 429, data: body) == nil)
    #expect(SkipTimesClient.cacheableMalId(status: 503, data: body) == nil)
}
