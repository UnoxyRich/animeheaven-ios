import Foundation
import Testing
@testable import AnimeHeavenCore

@Suite("MirrorFailover")
struct MirrorFailoverTests {

    @Test func advanceOnErrorExhaustsAfterLastMirror() {
        let q0 = MirrorQueueState(sources: ["https://m1/v.mp4", "https://m2/v.mp4"])
        #expect(q0.currentUrl == "https://m1/v.mp4")
        #expect(q0.displayLabel == "Mirror 1/2")

        let q1 = q0.advanceOnError()
        #expect(q1.currentUrl == "https://m2/v.mp4")
        #expect(!q1.exhausted)

        let q2 = q1.advanceOnError()
        #expect(q2.exhausted)
        #expect(q2.currentUrl == nil)
    }

    @Test func cycleManualWrapsAroundCleanly() {
        let q0 = MirrorQueueState(sources: ["u1", "u2", "u3"])
        let q1 = q0.cycleManual()
        let q2 = q1.cycleManual()
        let q3 = q2.cycleManual()
        #expect(q1.activeIndex == 1)
        #expect(q2.activeIndex == 2)
        #expect(q3.activeIndex == 0)
    }

    @Test func resetRestoresIndexZero() {
        let exhausted = MirrorQueueState(sources: ["u1", "u2"]).advanceOnError().advanceOnError()
        #expect(exhausted.exhausted)
        let reset = exhausted.reset()
        #expect(!reset.exhausted)
        #expect(reset.currentUrl == "u1")
    }
}
