import XCTest
@testable import Bricky

/// Continuous AR time feeds the sustained latency bucket, so overlapping
/// sessions from different views must count as one run.
final class ARActivityClockTests: XCTestCase {
    private final class FakeTime: @unchecked Sendable {
        var now: TimeInterval = 100
    }

    func testOverlappingSessionsFormOneContinuousRun() {
        let time = FakeTime()
        let clock = ARActivityClock(now: { time.now })
        let guide = UUID(), check = UUID()
        XCTAssertNil(clock.secondsSinceStart)

        clock.sessionStarted(guide)
        time.now += 60
        clock.sessionStarted(check)
        time.now += 30
        clock.sessionStopped(guide)
        XCTAssertEqual(clock.secondsSinceStart, 90, "the run continues while any session runs")

        time.now += 10
        clock.sessionStopped(check)
        XCTAssertNil(clock.secondsSinceStart)
        XCTAssertEqual(clock.activeSeconds, 100)
    }

    func testStopIsIdempotentAndANewRunStartsFresh() {
        let time = FakeTime()
        let clock = ARActivityClock(now: { time.now })
        let token = UUID()
        clock.sessionStarted(token)
        time.now += 20
        clock.sessionStopped(token)
        clock.sessionStopped(token)
        XCTAssertEqual(clock.activeSeconds, 20)

        time.now += 1_000
        clock.sessionStarted(token)
        time.now += 5
        XCTAssertEqual(clock.secondsSinceStart, 5)
        XCTAssertEqual(clock.activeSeconds, 25)
    }
}
