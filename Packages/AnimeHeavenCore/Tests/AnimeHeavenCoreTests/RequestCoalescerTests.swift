import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("RequestCoalescer")
struct RequestCoalescerTests {

    @Test func coalescerDeduplicatesAndSurvivesCallerCancellation() async throws {
        let coalescer = RequestCoalescer<String>()
        actor Counter {
            var count = 0
            func inc() -> Int { count += 1; return count }
        }
        let counter = Counter()

        let task1 = Task {
            try await coalescer.getOrFetch(key: "detail:abc") {
                _ = await counter.inc()
                try await Task.sleep(for: .milliseconds(80))
                return "payload-ok"
            }
        }
        let task2 = Task {
            try await coalescer.getOrFetch(key: "detail:abc") {
                _ = await counter.inc()
                try await Task.sleep(for: .milliseconds(80))
                return "payload-duplicate"
            }
        }

        try await Task.sleep(for: .milliseconds(10))
        task1.cancel()

        let result2 = try await task2.value
        let invocations = await counter.count
        #expect(result2 == "payload-ok")
        #expect(invocations == 1)
    }
}
