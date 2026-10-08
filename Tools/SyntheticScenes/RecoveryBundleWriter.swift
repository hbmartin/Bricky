import CoreGraphics
import CryptoKit
import Foundation
import simd

/// Writes the recovery suite's scenarios as an evidence bundle
/// (`--suite recovery --write-bundle <dir>`), so CI can round-trip the
/// geometric stack through the same files a device exports: each session's
/// depth frame goes through the device's own writer, with the perturbed
/// ghost as the recorded alignment, and its fits through the estimator's
/// recorder hook. `--replay-bundle <dir> --suite recovery --require-match`
/// must then reproduce every fit bit for bit. Pipeline tests only: the
/// device model is `synthetic:SyntheticRGBD` and nothing is a physical case.
struct RecoveryBundleWriter {
    static let deviceModel = "synthetic:SyntheticRGBD"

    let directory: URL
    let seed: UInt64
    let sourceIdentity: String
    let modelTitle: String
    let stepCount: Int
    /// Fixed, so two runs write identical session files.
    private let baseDate = Date(timeIntervalSince1970: 1_790_000_000)
    private var sessionIDs: [UUID] = []

    init(directory: URL, seed: UInt64, sourceIdentity: String, modelTitle: String, stepCount: Int) throws {
        self.directory = directory
        self.seed = seed
        self.sourceIdentity = sourceIdentity
        self.modelTitle = modelTitle
        self.stepCount = stepCount
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sessions", isDirectory: true), withIntermediateDirectories: true
        )
    }

    /// A UUID from a name and the seed, never from the scenario RNG, so
    /// writing a bundle cannot move the suite's rows. The arm is not part of
    /// the name: both arms' sessions pair by id.
    func stableID(_ name: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(seed)|\(name)".utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    struct Scenario {
        let fixtureID: String
        let step: AuthoredStep
        let frame: RegistrationFrameInput
        let alignment: ARAlignment
        let estimate: RecoveryEstimate?
        let fits: [GeometricFitRecord]
        let latencyMilliseconds: Int
    }

    /// The session's id, which its fits must carry.
    func sessionID(fixtureID: String) -> UUID { stableID("session|\(fixtureID)") }

    mutating func write(_ scenario: Scenario) throws {
        let sessionID = sessionID(fixtureID: scenario.fixtureID)
        let captureID = stableID("capture|\(scenario.fixtureID)")
        let sessionDirectory = directory.appendingPathComponent("sessions/\(sessionID.uuidString)", isDirectory: true)
        let captures = sessionDirectory.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        // validate() requires the photo to exist; the geometric stack never
        // reads it.
        try RecoveryBoardLayoutV1.writeJPEG(Self.placeholderImage(), to: captures.appendingPathComponent("\(captureID.uuidString).jpg"))
        try scenario.frame.writeEvidence(
            id: captureID, stem: "depth/\(captureID.uuidString)", in: sessionDirectory,
            coarseWorldFromModel: scenario.alignment.transform
        )
        let encoder = EvidenceSchema.encoder()
        var fits = Data()
        for fit in scenario.fits {
            fits.append(try encoder.encode(fit))
            fits.append(UInt8(ascii: "\n"))
        }
        if !fits.isEmpty {
            try fits.write(to: sessionDirectory.appendingPathComponent("fits.ndjson"), options: .atomic)
        }
        let createdAt = baseDate.addingTimeInterval(TimeInterval(sessionIDs.count))
        // What the composite estimator records without a fallback: the
        // geometric estimate, or insufficient when it did not conclude.
        let estimate = scenario.estimate ?? RecoveryEstimate(
            rankedStepIDs: [], certainty: .insufficient, modelRevision: GeometricRecoveryEstimator.revision,
            latencyMilliseconds: scenario.latencyMilliseconds, captureIDs: [captureID],
            insufficiencyCause: .geometricInconclusiveWithoutFallback, method: .geometric
        )
        let session = EvidenceSessionFile(
            sessionVersion: EvidenceSchema.sessionVersion,
            sessionID: sessionID,
            createdAt: createdAt,
            instructionSHA256: sourceIdentity,
            authoredModelID: stableID("model|\(modelTitle)"),
            modelTitle: modelTitle,
            stepCount: stepCount,
            modelRevision: "none",
            deviceModel: Self.deviceModel,
            operatingSystem: "synthetic",
            appVersion: "synthetic",
            captures: [EvidenceCaptureRecord(
                captureID: captureID,
                imageRelativePath: "captures/\(captureID.uuidString).jpg",
                cameraTransform: Self.columnMajor(scenario.frame.worldFromCamera),
                cameraIntrinsics: Self.columnMajor(scenario.frame.depthIntrinsics),
                cameraImageResolution: [Float(scenario.frame.width), Float(scenario.frame.height)],
                alignmentID: scenario.alignment.id,
                angle: CaptureAngle.center.rawValue,
                capturedAt: createdAt
            )],
            staged: StagedFixtureDeclaration(
                expectedCompletedCount: scenario.step.index, lighting: .bright, occlusion: .none,
                physicalCase: false, legalUseConfirmed: false
            ),
            groundTruth: EvidenceGroundTruth(
                kind: .staged, expectedCompletedCount: scenario.step.index, expectedStepID: scenario.step.id
            ),
            estimate: EvidenceSessionFile.EstimateSummary(estimate),
            analysisError: nil,
            partPackVersion: LDrawInstructionParser.partPackVersion
        )
        try EvidenceSchema.encoder(prettyPrinted: true).encode(session)
            .write(to: sessionDirectory.appendingPathComponent("session.json"), options: .atomic)
        sessionIDs.append(sessionID)
    }

    /// Writes the manifest and refuses a bundle the reader would refuse.
    func finish() throws {
        let manifest = EvidenceBundleManifest(
            bundleVersion: EvidenceSchema.bundleVersion, createdAt: baseDate, appVersion: "synthetic",
            deviceModel: Self.deviceModel, operatingSystem: "synthetic", modelID: "none", modelRevision: "none",
            sessionIDs: sessionIDs
        )
        try EvidenceSchema.encoder(prettyPrinted: true).encode(manifest)
            .write(to: directory.appendingPathComponent("evidence_bundle.json"), options: .atomic)
        let issues = try EvidenceBundleReader(bundleDirectory: directory).validate()
        guard issues.isEmpty else {
            throw CLIError("wrote an invalid bundle:\n" + issues.joined(separator: "\n"))
        }
    }

    private static func columnMajor(_ matrix: simd_float4x4) -> [Float] {
        var values: [Float] = []
        for column in 0..<4 { for row in 0..<4 { values.append(matrix[column][row]) } }
        return values
    }

    private static func columnMajor(_ matrix: simd_float3x3) -> [Float] {
        var values: [Float] = []
        for column in 0..<3 { for row in 0..<3 { values.append(matrix[column][row]) } }
        return values
    }

    private static func placeholderImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw CLIError("could not create a placeholder capture") }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else { throw CLIError("could not create a placeholder capture") }
        return image
    }
}
