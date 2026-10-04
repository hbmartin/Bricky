import XCTest
import simd
@testable import Bricky

/// A photo check runs only under a locked pose, keeps verification paused
/// for exactly its own run, and never lets a cancelled run touch the next.
@MainActor
final class PhotoCheckControllerTests: XCTestCase {
    private final class FakePoseSource: RegisteredPoseSource {
        var lockedAlignment: ARAlignment?
        private(set) var suspends = 0
        private(set) var resumes = 0
        var isSuspended: Bool { suspends > resumes }

        init(locked: Bool) {
            lockedAlignment = locked
                ? ARAlignment(id: UUID(), transform: matrix_identity_float4x4, isTracking: true)
                : nil
        }

        func suspendVerification() { suspends += 1 }
        func resumeVerification() { resumes += 1 }
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "render failed" }
    }

    func testRefusesWithoutALockedPose() {
        let controller = PhotoCheckController()
        let source = FakePoseSource(locked: false)
        XCTAssertNil(controller.start(source: source) { _ in .complete })
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(source.suspends, 0)
    }

    func testChecksAtTheLockedPoseAndResumesAfter() async {
        let controller = PhotoCheckController()
        let source = FakePoseSource(locked: true)
        let lockedID = source.lockedAlignment?.id
        var checkedAt: UUID?
        let task = controller.start(source: source) { alignment in
            checkedAt = alignment.id
            XCTAssertTrue(source.isSuspended, "verification is paused while the model runs")
            return .incomplete
        }
        XCTAssertEqual(controller.state, .checking)
        XCTAssertNil(controller.start(source: source) { _ in .complete }, "one check at a time")
        await task?.value
        XCTAssertEqual(checkedAt, lockedID)
        XCTAssertEqual(controller.state, .finished(.incomplete))
        XCTAssertFalse(source.isSuspended)
        XCTAssertEqual(source.resumes, 1)
    }

    func testAFailureResumesVerificationAndSurfaces() async {
        let controller = PhotoCheckController()
        let source = FakePoseSource(locked: true)
        await controller.start(source: source) { _ in throw Failure() }?.value
        XCTAssertEqual(controller.state, .failed("render failed"))
        XCTAssertFalse(source.isSuspended)
    }

    func testACancelledRunCannotResumeTheNextRunsPause() async {
        let controller = PhotoCheckController()
        let first = FakePoseSource(locked: true)
        var release: CheckedContinuation<Void, Never>?
        let firstTask = controller.start(source: first) { _ in
            await withCheckedContinuation { release = $0 }
            return .complete
        }
        for _ in 0..<50 where release == nil { await Task.yield() }
        controller.cancel()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(first.isSuspended, "cancel resumes at once")

        let second = FakePoseSource(locked: true)
        var releaseSecond: CheckedContinuation<Void, Never>?
        let secondTask = controller.start(source: second) { _ in
            await withCheckedContinuation { releaseSecond = $0 }
            return .uncertain
        }
        release?.resume()
        await firstTask?.value
        XCTAssertEqual(controller.state, .checking, "the stale run must not publish")
        XCTAssertTrue(second.isSuspended, "nor resume the new run's pause")
        XCTAssertEqual(first.resumes, 1)

        for _ in 0..<50 where releaseSecond == nil { await Task.yield() }
        releaseSecond?.resume()
        await secondTask?.value
        XCTAssertEqual(controller.state, .finished(.uncertain))
        XCTAssertFalse(second.isSuspended)
    }
}
