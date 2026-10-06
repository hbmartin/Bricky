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
                latticeMargin: frame.latticeMargin
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
