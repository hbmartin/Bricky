import Foundation
import simd

enum InstructionLimits {
    static let maximumSourceBytes = 100 * 1024 * 1024
    static let maximumLineBytes = 64 * 1024
    static let maximumSteps = 10_000
    static let maximumPlacements = 50_000
    static let maximumRecursionDepth = 64
}

enum InstructionDiagnosticSeverity: String, Codable, Sendable {
    case warning
    case error
}

struct InstructionDiagnostic: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let severity: InstructionDiagnosticSeverity
    let code: String
    let message: String
    let section: String?
    let lineNumber: Int?

    init(
        id: UUID = UUID(),
        severity: InstructionDiagnosticSeverity,
        code: String,
        message: String,
        section: String? = nil,
        lineNumber: Int? = nil
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
        self.section = section
        self.lineNumber = lineNumber
    }
}

/// LDraw's affine transform: translation followed by the row-major 3x3 basis.
struct LDrawTransform: Codable, Hashable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var a: Double = 1
    var b: Double = 0
    var c: Double = 0
    var d: Double = 0
    var e: Double = 1
    var f: Double = 0
    var g: Double = 0
    var h: Double = 0
    var i: Double = 1

    static let identity = LDrawTransform()

    func multiplied(by rhs: LDrawTransform) -> LDrawTransform {
        LDrawTransform(
            x: a * rhs.x + b * rhs.y + c * rhs.z + x,
            y: d * rhs.x + e * rhs.y + f * rhs.z + y,
            z: g * rhs.x + h * rhs.y + i * rhs.z + z,
            a: a * rhs.a + b * rhs.d + c * rhs.g,
            b: a * rhs.b + b * rhs.e + c * rhs.h,
            c: a * rhs.c + b * rhs.f + c * rhs.i,
            d: d * rhs.a + e * rhs.d + f * rhs.g,
            e: d * rhs.b + e * rhs.e + f * rhs.h,
            f: d * rhs.c + e * rhs.f + f * rhs.i,
            g: g * rhs.a + h * rhs.d + i * rhs.g,
            h: g * rhs.b + h * rhs.e + i * rhs.h,
            i: g * rhs.c + h * rhs.f + i * rhs.i
        )
    }

    func applyingInheritedColor(_ inheritedColor: Int, ownColor: Int) -> Int {
        ownColor == 16 ? inheritedColor : ownColor
    }

    var translationInMeters: SIMD3<Float> {
        // 1 LDU = 0.4 mm; invert LDraw's downward-positive Y axis.
        SIMD3(Float(x) * 0.0004, Float(-y) * 0.0004, Float(z) * 0.0004)
    }
}

struct PartPlacement: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let partReference: String
    let colorCode: Int
    let transform: LDrawTransform
    let sourceSection: String
    let sourceLine: Int
    let isSubmodelReference: Bool
}

enum RotationMode: String, Codable, Sendable {
    case relative
    case absolute
    case additive
    case end
}

struct RotationCue: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let z: Double
    let mode: RotationMode
}

struct CameraCue: Codable, Hashable, Sendable {
    var anglePreset: String? = nil
    var angles: [Double]?
    var position: [Double]?
    var target: [Double]?
    var upVector: [Double]?
    var distance: Double? = nil
    var fieldOfView: Double? = nil
    var name: String? = nil
    var orthographic: Bool? = nil
    var nearClip: Double? = nil
    var farClip: Double? = nil

    var isEmpty: Bool {
        anglePreset == nil && angles == nil && position == nil && target == nil &&
            upVector == nil && distance == nil && fieldOfView == nil && name == nil &&
            orthographic == nil && nearClip == nil && farClip == nil
    }
}

struct InstructionDirective: Codable, Hashable, Sendable {
    let namespace: String
    let command: String
    let arguments: [String]
    let sourceLine: Int
}

struct SectionInstructionStep: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(normalizedSectionName)#\(number)" }
    let normalizedSectionName: String
    let number: Int
    let sourceStartLine: Int
    let sourceEndLine: Int
    let directPlacements: [PartPlacement]
    let rotationCue: RotationCue?
    let cameraCue: CameraCue?
    let directives: [InstructionDirective]
}

struct InstructionSection: Identifiable, Codable, Hashable, Sendable {
    var id: String { normalizedName }
    let name: String
    let normalizedName: String
    let isRoot: Bool
    let hasAuthoredBoundaries: Bool
    let references: [String]
    let steps: [SectionInstructionStep]
}

struct InstructionDocument: Codable, Hashable, Sendable {
    let rootSectionName: String
    let sections: [InstructionSection]
    let orphanSectionNames: [String]
    let diagnostics: [InstructionDiagnostic]
    let partPackVersion: String
    let billOfMaterials: [BOMEntry]
    let bounds: LDrawBounds?

    var rootSection: InstructionSection? {
        sections.first { $0.normalizedName == rootSectionName }
    }

    var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

struct BOMEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(partReference)|\(colorCode)" }
    let partReference: String
    let colorCode: Int
    let quantity: Int
}

struct LDrawBounds: Codable, Hashable, Sendable {
    let minimum: [Double]
    let maximum: [Double]
}

struct PlacementRange: Codable, Hashable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    var isEmpty: Bool { lowerBound == upperBound }
}

struct AuthoredStep: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let index: Int
    let sectionName: String
    let instancePath: String
    let sectionStepNumber: Int
    let sourceStartLine: Int
    let sourceEndLine: Int
    let directPlacements: [PartPlacement]
    let addedPlacementRange: PlacementRange
    let cumulativePlacementCount: Int
    let rotationCue: RotationCue?
    let cameraCue: CameraCue?
    let directives: [InstructionDirective]
}

struct InstructionPlan: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let title: String
    let sourceFilename: String
    let sourceSHA256: String
    let importedAt: Date
    let document: InstructionDocument
    let steps: [AuthoredStep]
    let placementTimeline: [PartPlacement]

    var partPackVersion: String { document.partPackVersion }
    var stepZeroID: String { "\(document.rootSectionName)#0" }

    func addedPlacements(for step: AuthoredStep) -> ArraySlice<PartPlacement> {
        placementTimeline[step.addedPlacementRange.lowerBound..<step.addedPlacementRange.upperBound]
    }

    func cumulativePlacements(through step: AuthoredStep) -> ArraySlice<PartPlacement> {
        placementTimeline[0..<min(step.cumulativePlacementCount, placementTimeline.count)]
    }
}

enum RecoveryCertainty: String, Codable, Sendable {
    case high
    case medium
    case low
    case insufficient
}

struct RecoveryCapture: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let imageRelativePath: String
    let cameraTransform: [Float]
    let cameraIntrinsics: [Float]
    let alignmentID: UUID
    let angle: CaptureAngle
    let capturedAt: Date
}

enum CaptureAngle: String, CaseIterable, Codable, Sendable {
    case left
    case center
    case right

    var title: String { rawValue.capitalized }
}

struct RecoveryEstimate: Codable, Hashable, Sendable {
    let rankedStepIDs: [String]
    let certainty: RecoveryCertainty
    let modelRevision: String
    let latencyMilliseconds: Int
    let captureIDs: [UUID]
}

enum StepCheckResult: String, Codable, Sendable {
    case complete
    case incomplete
    case uncertain
}

struct ARAlignment: Identifiable, Hashable, Sendable {
    let id: UUID
    var transform: simd_float4x4
    var isTracking: Bool

    static func == (lhs: ARAlignment, rhs: ARAlignment) -> Bool {
        guard lhs.id == rhs.id, lhs.isTracking == rhs.isTracking else { return false }
        for column in 0..<4 where lhs.transform[column] != rhs.transform[column] {
            return false
        }
        return true
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        for column in 0..<4 {
            for row in 0..<4 {
                hasher.combine(transform[column][row])
            }
        }
        hasher.combine(isTracking)
    }
}

enum ModelAdmissionState: Equatable, Sendable {
    case checking
    case needsDownload(bytes: Int64)
    case downloading(progress: Double)
    case warming
    case admitted
    case rejected(reason: String)
}

struct RecoveryBenchmarkV1: Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let fixtureID: String
    let instructionSHA256: String
    let pyldraw3Version: String
    let partPackVersion: String
    let expectedStepID: String
    let candidateSlots: [String: String]
    let boardRelativePaths: [String]
    let cameraMetadata: [[String: Float]]
    let expectedStepIndex: Int
    let rankedStepIDs: [String]
    let certainty: RecoveryCertainty
    let deviceModel: String
    let operatingSystem: String
    let latencyMilliseconds: Int
    let memoryPeakBytes: Int64
    let topStepIndex: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixtureID = "fixture_id"
        case instructionSHA256 = "instruction_sha256"
        case pyldraw3Version = "pyldraw3_version"
        case partPackVersion = "part_pack_version"
        case expectedStepID = "expected_step_id"
        case candidateSlots = "candidate_slots"
        case boardRelativePaths = "board_relative_paths"
        case cameraMetadata = "camera_metadata"
        case expectedStepIndex = "expected_step_index"
        case rankedStepIDs = "ranked_step_ids"
        case certainty
        case deviceModel = "device_model"
        case operatingSystem = "operating_system"
        case latencyMilliseconds = "latency_ms"
        case memoryPeakBytes = "memory_peak_bytes"
        case topStepIndex = "top_step_index"
    }
}
