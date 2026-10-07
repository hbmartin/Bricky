import XCTest
@testable import RecoveryEvidenceKit

/// Lattice evidence is optional and trailing: records written before it
/// still decode, and nothing new is written when there is nothing to say.
final class LatticeEvidenceTests: XCTestCase {
    private func frame(runnerUp: String?) -> VerificationWindowFrame {
        VerificationWindowFrame(
            frameID: UUID(), registrationState: "locked", worldFromModel: Array(repeating: 0, count: 16),
            rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 1.25, verdictAfter: "complete",
            ingestMilliseconds: 9, latticeRunnerUp: runnerUp
        )
    }

    private func fit(runnerUp: String?) -> GeometricFitRecord {
        GeometricFitRecord(
            fitVersion: EvidenceSchema.fitVersion, fitID: UUID(), sessionID: UUID(), passIndex: 0, candidateIndex: 2,
            stepID: "m#3", score: 0.6, inlierFraction: 0.5, visibleFraction: 0.4, unexplainedFraction: 0.1,
            phantomFraction: 0.05, rmsResidual: 0.004, latticeMargin: 1.4, worldFromModel: Array(repeating: 0, count: 16),
            disqualification: .none, conclusive: false, createdAt: Date(timeIntervalSince1970: 0),
            latticeRunnerUp: runnerUp
        )
    }

    private func capture(state: String?, margin: Float?, runnerUp: String?) -> EvidenceCaptureRecord {
        EvidenceCaptureRecord(
            captureID: UUID(), imageRelativePath: "captures/a.jpg", cameraTransform: Array(repeating: 0, count: 16),
            cameraIntrinsics: Array(repeating: 0, count: 9), cameraImageResolution: [1920, 1440], alignmentID: UUID(),
            angle: "center", capturedAt: Date(timeIntervalSince1970: 0), worldFromModel: nil,
            registrationState: state, latticeMargin: margin, latticeRunnerUp: runnerUp
        )
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        try XCTUnwrap(String(data: EvidenceSchema.encoder().encode(value), encoding: .utf8))
    }

    func testRunnerUpOptionalOmittedWhenNil() throws {
        XCTAssertTrue(try json(frame(runnerUp: "shift_x_neg")).contains(#""lattice_runner_up":"shift_x_neg""#))
        XCTAssertFalse(try json(frame(runnerUp: nil)).contains("lattice_runner_up"))
        XCTAssertTrue(try json(fit(runnerUp: "yaw_90")).contains(#""lattice_runner_up":"yaw_90""#))
        XCTAssertFalse(try json(fit(runnerUp: nil)).contains("lattice_runner_up"))

        let stamped = try json(capture(state: "locked", margin: 1.5, runnerUp: "yaw_180"))
        XCTAssertTrue(stamped.contains(#""registration_state":"locked""#))
        XCTAssertTrue(stamped.contains(#""lattice_margin":1.5"#))
        XCTAssertTrue(stamped.contains(#""lattice_runner_up":"yaw_180""#))
        let bare = try json(capture(state: nil, margin: nil, runnerUp: nil))
        for key in ["registration_state", "lattice_margin", "lattice_runner_up"] {
            XCTAssertFalse(bare.contains(key), key)
        }
    }

    func testContestsAndTalliesAreSnakeCaseAndOptional() throws {
        let window = VerificationWindowRecord(
            windowID: UUID(), sessionID: UUID(), stepID: "m#3", stepIndex: 2, trigger: .confirm,
            createdAt: Date(timeIntervalSince1970: 0), frames: [frame(runnerUp: nil)], verdict: "misplaced",
            offsetStuds: [1, 0], uncertainReason: nil, detectability: "strong", deltaPixels: 140, framesUsed: 12,
            completeFraction: 0.1, incompleteFraction: 0.2, staged: nil,
            latticeContests: [LatticeContestRecord(offsetStuds: [1, 0], winsComplete: 3, winsShifted: 11)]
        )
        let encoded = try json(window)
        XCTAssertTrue(encoded.contains(#""lattice_contests""#))
        XCTAssertTrue(encoded.contains(#""offset_studs":[1,0]"#))
        XCTAssertTrue(encoded.contains(#""wins_complete":3"#))
        XCTAssertTrue(encoded.contains(#""wins_shifted":11"#))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EvidenceSchema.encoder().encode(window)) as? [String: Any]
        )
        object.removeValue(forKey: "lattice_contests")
        let old = try EvidenceSchema.decoder().decode(
            VerificationWindowRecord.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(old.latticeContests)

        let placement = BuildDiffRecord.Placement(
            placement: 2, state: "displaced", offset: [1, 0, 0, 0], support: 5, absence: 1, unexplained: 0, framesSeen: 4,
            tallies: [HypothesisTallyRecord(offset: [1, 0, 0, 0], winsPresent: 2, winsAlternative: 9)]
        )
        let placementJSON = try json(placement)
        XCTAssertTrue(placementJSON.contains(#""tallies":[{"#))
        XCTAssertTrue(placementJSON.contains(#""wins_present":2"#))
        XCTAssertTrue(placementJSON.contains(#""wins_alternative":9"#))
        let legacy = #"{"placement":2,"state":"present","support":5,"absence":1,"unexplained":0,"frames_seen":4}"#
        XCTAssertNil(try EvidenceSchema.decoder().decode(BuildDiffRecord.Placement.self, from: Data(legacy.utf8)).tallies)
    }

    private func frame(state: String, margin: Float, runnerUp: String?) -> VerificationWindowFrame {
        VerificationWindowFrame(
            frameID: UUID(), registrationState: state, worldFromModel: Array(repeating: 0, count: 16),
            rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: margin, verdictAfter: "uncertain",
            ingestMilliseconds: 9, latticeRunnerUp: runnerUp
        )
    }

    func testLatticeWindowRowsSummariseFramesAndKeepTheTruth() throws {
        let window = VerificationWindowRecord(
            windowID: UUID(), sessionID: UUID(), stepID: "m#3", stepIndex: 2, trigger: .confirm,
            createdAt: Date(timeIntervalSince1970: 0),
            frames: [
                frame(state: "locked", margin: 1.4, runnerUp: "shift_x_pos"),
                frame(state: "locked", margin: 2.0, runnerUp: "yaw_180"),
                frame(state: "ambiguous", margin: 1.05, runnerUp: "shift_x_pos"),
                frame(state: "refining", margin: 0, runnerUp: nil),
                frame(state: "locked", margin: Float.greatestFiniteMagnitude, runnerUp: nil),
            ],
            verdict: "misplaced", offsetStuds: [1, 0], uncertainReason: nil, detectability: "strong",
            deltaPixels: 140, framesUsed: 12, completeFraction: 0.1, incompleteFraction: 0.2,
            staged: StagedVerificationDeclaration(
                scenario: .complete, lighting: .bright, occlusion: .none, physicalCase: true, legalUseConfirmed: true
            ),
            latticeContests: [LatticeContestRecord(offsetStuds: [1, 0], winsComplete: 3, winsShifted: 11)]
        )
        let sessionID = UUID()
        let row = try XCTUnwrap(LatticeWindowRowV1.rows(windows: [window], sessionID: sessionID, deviceModel: "iPhone18,1").first)
        XCTAssertEqual(row.provenance, "device")
        XCTAssertEqual(row.fixtureID, window.windowID.uuidString)
        XCTAssertEqual(row.sessionID, sessionID.uuidString)
        XCTAssertEqual(row.trigger, "confirm")
        XCTAssertEqual(row.verdict, "misplaced")
        XCTAssertEqual(row.stagedScenario, "complete")
        XCTAssertEqual(row.expectedVerdict, "complete")
        XCTAssertEqual(row.frames, 5)
        XCTAssertEqual(row.margins, [1.4, 2.0, 1.05], "no-sweep and no-competitor frames carry no margin")
        XCTAssertEqual(row.sweptFrames, 3)
        XCTAssertEqual(row.ambiguousFrames, 1)
        XCTAssertEqual(row.lockedFrames, 3)
        XCTAssertEqual(row.lockedNearThresholdFrames, 1)
        XCTAssertEqual(row.runnerUps, ["shift_x_pos": 2, "yaw_180": 1])
        XCTAssertEqual(row.latticeContests?.first?.winsShifted, 11)

        let encoded = try json(row)
        for key in [#""kind":"lattice_window""#, #""schema_version":1"#, #""locked_near_threshold_frames":1"#,
                    #""staged_scenario":"complete""#, #""runner_ups""#] {
            XCTAssertTrue(encoded.contains(key), key)
        }
        XCTAssertEqual(try EvidenceSchema.decoder().decode(LatticeWindowRowV1.self, from: Data(encoded.utf8)), row)

        let replayed = LatticeWindowRowV1.rows(windows: [window], sessionID: sessionID, deviceModel: "replay:Mac14,9")
        XCTAssertEqual(replayed.first?.provenance, "replay")
        let synthetic = LatticeWindowRowV1.rows(windows: [window], sessionID: sessionID, deviceModel: "synthetic:bricky-harness")
        XCTAssertEqual(synthetic.first?.provenance, "synthetic")
    }

    func testRecordsFromBeforeTheRunnerUpStillDecode() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EvidenceSchema.encoder().encode(frame(runnerUp: "shift_z_pos"))) as? [String: Any]
        )
        object.removeValue(forKey: "lattice_runner_up")
        let oldFrame = try EvidenceSchema.decoder().decode(
            VerificationWindowFrame.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(oldFrame.latticeRunnerUp)
        XCTAssertEqual(oldFrame.latticeMargin, 1.25)

        var fitObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EvidenceSchema.encoder().encode(fit(runnerUp: "yaw_90"))) as? [String: Any]
        )
        fitObject.removeValue(forKey: "lattice_runner_up")
        XCTAssertNil(try EvidenceSchema.decoder().decode(
            GeometricFitRecord.self, from: JSONSerialization.data(withJSONObject: fitObject)
        ).latticeRunnerUp)

        let roundTrip = try EvidenceSchema.decoder().decode(
            EvidenceCaptureRecord.self,
            from: EvidenceSchema.encoder().encode(capture(state: "ambiguous", margin: 1.125, runnerUp: "shift_x_pos"))
        )
        XCTAssertEqual(roundTrip.registrationState, "ambiguous")
        XCTAssertEqual(roundTrip.latticeMargin, 1.125)
        XCTAssertEqual(roundTrip.latticeRunnerUp, "shift_x_pos")
    }
}
