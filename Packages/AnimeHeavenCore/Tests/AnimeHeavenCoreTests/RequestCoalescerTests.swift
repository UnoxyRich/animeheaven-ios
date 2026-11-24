import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("RequestCoalescer")
struct RequestCoalescerTests {
    private actor Gate {
        private var started = false
        private var released = false
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func waitForStart() async {
            if !started { await withCheckedContinuation { startedWaiter = $0 } }
        }

        func block() async {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        }

        func open() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    @Test func coalescerDeduplicatesAndSurvivesCallerCancellation() async throws {
        let coalescer = RequestCoalescer<String>()
        let key = "detail:abc"
        let gate = Gate()
        actor Counter {
            var count = 0
            func inc() -> Int { count += 1; return count }
        }
        let counter = Counter()

        let task1 = Task {
            try await coalescer.getOrFetch(key: key) {
                _ = await counter.inc()
                await gate.block()
                return "payload-ok"
            }
        }
        defer { Task { await gate.open() } }
        await gate.waitForStart()
        let task2 = Task {
            try await coalescer.getOrFetch(key: key) {
                _ = await counter.inc()
                return "payload-duplicate"
            }
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while await coalescer.waiterCount(for: key) < 2 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        let joined = await coalescer.waiterCount(for: key)
        try #require(joined == 2)
        task1.cancel()
        // Observe the cancelled caller before letting the shared operation finish.
        let cancelled = await task1.result
        if case .failure(let error) = cancelled {
            #expect(error is CancellationError)
        } else {
            Issue.record("Cancelled waiter received the shared response")
        }
        await gate.open()

        let result2 = try await task2.value
        let invocations = await counter.count
        #expect(result2 == "payload-ok")
        #expect(invocations == 1)
    }
}
