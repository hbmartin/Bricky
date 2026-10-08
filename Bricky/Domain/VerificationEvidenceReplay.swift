import Foundation
import simd

/// Turns recorded evidence back into verifier inputs, so a window replays
/// through exactly the code that judged it (ADR 0007 amendment 2). Shared by
/// the app's tests and SyntheticRGBD `--replay-bundle`.
extension RegistrationFrameInput {
    init(record: EvidenceDepthFrameRecord, planes: EvidenceDepthPlanes) {
        var intrinsics = simd_float3x3()
        for column in 0..<3 {
            for row in 0..<3 where record.depthIntrinsics.count == 9 {
                intrinsics[column][row] = record.depthIntrinsics[column * 3 + row]
            }
        }
        self.init(
            depth: planes.depth,
            confidence: planes.confidence,
            rawDepth: planes.rawDepth,
            rawConfidence: planes.rawConfidence,
            width: record.width,
            height: record.height,
            depthIntrinsics: intrinsics,
            worldFromCamera: simd_float4x4(rowMajor: record.worldFromCamera),
            timestamp: record.timestamp,
            colour: planes.colour,
            colourEncoding: record.colourEncoding,
            occluderMask: planes.occluderMask
        )
    }

    /// The sidecar and planes `init(record:planes:)` reads back. Raw planes
    /// are kept only as a pair; colour and mask only when they fill the grid,
    /// exactly as the recorder has always written them.
    func evidence(id: UUID, stem: String) -> (record: EvidenceDepthFrameRecord, planes: EvidenceDepthPlanes) {
        let hasRaw = rawDepth != nil && rawConfidence != nil
        let keptColour = colour.flatMap { $0.count == width * height * 3 ? $0 : nil }
        let keptMask = occluderMask.flatMap { $0.count == width * height ? $0 : nil }
        var intrinsics: [Float] = []
        intrinsics.reserveCapacity(9)
        for column in 0..<3 {
            for row in 0..<3 {
                intrinsics.append(depthIntrinsics[column][row])
            }
        }
        let record = EvidenceDepthFrameRecord(
            depthVersion: EvidenceSchema.depthVersion,
            captureID: id,
            width: width,
            height: height,
            depthIntrinsics: intrinsics,
            worldFromCamera: worldFromCamera.rowMajorValues,
            timestamp: timestamp,
            depthRelativePath: "\(stem).depth",
            confidenceRelativePath: "\(stem).confidence",
            rawDepthRelativePath: hasRaw ? "\(stem).raw-depth" : nil,
            rawConfidenceRelativePath: hasRaw ? "\(stem).raw-confidence" : nil,
            colourRelativePath: keptColour == nil ? nil : "\(stem).colour",
            occluderMaskRelativePath: keptMask == nil ? nil : "\(stem).occluder",
            colourEncoding: keptColour == nil ? nil : colourEncoding
        )
        let planes = EvidenceDepthPlanes(
            depth: depth,
            confidence: confidence,
            rawDepth: hasRaw ? rawDepth : nil,
            rawConfidence: hasRaw ? rawConfidence : nil,
            colour: keptColour,
            occluderMask: keptMask
        )
        return (record, planes)
    }

    /// Writes the frame's planes, then `<stem>.json` naming them, under
    /// `directory`. Shared by the app's recorder and SyntheticRGBD, so a
    /// synthetic bundle is written by the device's own code.
    @discardableResult
    func writeEvidence(id: UUID, stem: String, in directory: URL) throws -> EvidenceDepthFrameRecord {
        let (record, planes) = evidence(id: id, stem: stem)
        try planes.write(record, in: directory)
        try EvidenceSchema.encoder(prettyPrinted: true).encode(record)
            .write(to: directory.appendingPathComponent("\(stem).json"), options: .atomic)
        return record
    }
}

extension ModelRegistration {
    init(windowFrame frame: VerificationWindowFrame, stepIndex: Int, timestamp: TimeInterval) {
        self.init(
            alignmentID: UUID(),
            worldFromModel: simd_float4x4(rowMajor: frame.worldFromModel),
            state: RegistrationState(rawValue: frame.registrationState) ?? .lost,
            quality: RegistrationQuality(
                rmsResidual: frame.rmsResidual,
                inlierFraction: frame.inlierFraction,
                latticeMargin: frame.latticeMargin,
                latticeRunnerUp: frame.latticeRunnerUp.flatMap(LatticeAlternative.init(rawValue:))
            ),
            fittedStepIndex: stepIndex,
            timestamp: timestamp
        )
    }
}

extension simd_float4x4 {
    /// From 16 row-major values, the layout evidence records use; identity
    /// for anything else.
    init(rowMajor values: [Float]) {
        self = matrix_identity_float4x4
        guard values.count == 16 else { return }
        for row in 0..<4 {
            for column in 0..<4 {
                self[column][row] = values[row * 4 + column]
            }
        }
    }

    var rowMajorValues: [Float] {
        (0..<4).flatMap { row in (0..<4).map { column in self[column][row] } }
    }
}
