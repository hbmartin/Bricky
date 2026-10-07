import Foundation
import simd

/// Pseudo-labels for a bundle's AR photo captures (iOS 27 Phase 4,
/// ADR 0020): the authored top studs of what the staged declaration says
/// was built, projected through the locked model pose the photo was taken
/// under, with visibility from the stud-ID render at the photo's own
/// camera. The image is referenced, never copied or altered.
///
/// These are pseudo-labels: they are only as good as the registration.
/// `StudLabelPolicy` refuses captures whose pose was not locked well clear
/// of a lattice alias, and every refusal is written with its reason so the
/// counts can be audited. Labels still need checking by eye before any
/// model trains on them.
enum CaptureStudLabels {
    static let kind = "stud_label_capture"
    /// The render grid's width; the photo's own aspect sets its height.
    static let gridWidth = 1024

    static func run(
        bundle: URL, plan: InstructionPlan, sourceIdentity: String, engine: LDrawGeometryEngine,
        renderer: ExpectedDepthRenderer, includeConfirmed: Bool, outPath: String
    ) async throws {
        let reader = try EvidenceBundleReader(bundleDirectory: bundle)
        let issues = reader.validate()
        guard issues.isEmpty else {
            throw CLIError("invalid bundle:\n" + issues.joined(separator: "\n"))
        }
        let (segments, index) = try await engine.segmentedWithStuds(placements: plan.placementTimeline)
        let plain = renderer.prepare(segments)
        let studTagged = renderer.prepare(segments, triangleTags: index.triangleStud)
        var rows: [String] = []
        var refusals: [String: Int] = [:]
        var labelled = 0
        for session in try reader.loadSessions() {
            guard session.file.instructionSHA256 == sourceIdentity else {
                print("session \(session.file.sessionID.uuidString.prefix(8)): instruction \(session.file.instructionSHA256.prefix(12))… is not this model; skipped")
                continue
            }
            let truth = session.file.groundTruth
            for capture in session.file.captures {
                var row: [String: Any] = [
                    "kind": kind,
                    "provenance": "pseudo_registered",
                    "schema_version": 1,
                    "fixture_id": capture.captureID.uuidString,
                    "session_id": session.file.sessionID.uuidString,
                    "image_relative_path": "sessions/\(session.file.sessionID.uuidString)/\(capture.imageRelativePath)",
                    "label_kind": truth.kind.rawValue,
                ]
                if let count = truth.expectedCompletedCount { row["expected_completed_count"] = count }
                if let margin = capture.latticeMargin { row["lattice_margin"] = Double(margin) }
                var refusal = StudLabelPolicy.refusal(capture: capture, truth: truth, includeConfirmed: includeConfirmed)?.rawValue
                let built = truth.expectedCompletedCount ?? -1
                if refusal == nil, !(0...plan.steps.count).contains(built) {
                    refusal = "step_out_of_range"
                }
                if let refusal {
                    row["refusal"] = refusal
                    refusals[refusal, default: 0] += 1
                    rows.append(try Row.encode(row))
                    continue
                }
                let placements = built == 0 ? 0 : plan.steps[built - 1].cumulativePlacementCount
                guard let worldFromModel = CheckCropGeometry.matrix(columnMajor: capture.worldFromModel ?? []),
                      let worldFromCamera = CheckCropGeometry.matrix(columnMajor: capture.cameraTransform),
                      let grid = CheckCropGeometry.grid(
                        cameraIntrinsics: capture.cameraIntrinsics, imageResolution: capture.cameraImageResolution,
                        width: gridWidth
                      ) else {
                    row["refusal"] = "malformed_capture"
                    refusals["malformed_capture", default: 0] += 1
                    rows.append(try Row.encode(row))
                    continue
                }
                let viewFromModel = worldFromCamera.inverse * worldFromModel
                let ranges = [segments.vertexRange(0..<placements)]
                let maps = try await renderer.render(
                    [DepthRenderRequest(geometry: plain, viewFromModel: viewFromModel, ranges: ranges)],
                    tags: [DepthRenderRequest(geometry: studTagged, viewFromModel: viewFromModel, ranges: ranges)],
                    intrinsics: grid.intrinsics, width: grid.width, height: grid.height
                )
                let studs = index.studs.indices.filter {
                    index.studs[$0].role == .top && index.studs[$0].placement < placements
                }
                let labels = StudVisibility.labels(
                    index: index, studs: studs, viewFromModel: viewFromModel, intrinsics: grid.intrinsics,
                    ids: maps.tags[0].tags, depth: maps.depth[0].depth, width: grid.width, height: grid.height
                )
                let rotation = CheckCropGeometry.uprightRotation(worldFromCamera: worldFromCamera)
                row["rotation"] = "\(rotation)"
                row["studs"] = labels.map { label -> [String: Any] in
                    let stud = index.studs[label.stud]
                    let upright = CheckCropGeometry.upright(
                        point: SIMD2(label.u / Float(grid.width), label.v / Float(grid.height)), rotation: rotation
                    )
                    return [
                        "stud": label.stud, "placement": stud.placement, "primitive": stud.primitive,
                        "x": Double(upright.x), "y": Double(upright.y), "depth_m": Double(label.depth),
                        "pixels": label.pixels, "up_facing": label.upFacing, "visible": label.visible,
                        "scaled": stud.isScaled,
                    ]
                }
                labelled += 1
                rows.append(try Row.encode(row))
            }
        }
        try (rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")).write(toFile: outPath, atomically: true, encoding: .utf8)
        print("labelled \(labelled) of \(rows.count) captures; refused \(refusals.sorted { $0.key < $1.key })")
    }
}
