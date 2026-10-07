import CoreGraphics
import Foundation
import RecoveryEvidenceKit

// The step-check advisor (Phase 3 M3.4, ADR 0018): a second model judging a
// photo check in shadow. Foundation-only here; the Foundation Models
// implementation beside it compiles only where the framework exists.

/// What a photo check showed, for an advisor to judge: the photo, the
/// target render, and, for AR checks, where the step's delta fell.
public struct StepCheckAdviceInput: Sendable {
    public let photoJPEG: Data
    public let targetJPEG: Data
    /// Normalized to the upright photo (`CheckGeometryRecord`). Only meaningful
    /// when the target was rendered from the photo's own camera.
    public let deltaBox: CheckGeometryRecord.Box?
    /// True when `targetJPEG` was rendered at the locked registration, so it
    /// shares the photo's viewpoint and `deltaBox` applies to both.
    public let targetIsRegistered: Bool
    /// The 1-based step being checked, for the prompt.
    public let stepNumber: Int

    public init(photoJPEG: Data, targetJPEG: Data, deltaBox: CheckGeometryRecord.Box?, targetIsRegistered: Bool, stepNumber: Int) {
        self.photoJPEG = photoJPEG
        self.targetJPEG = targetJPEG
        self.deltaBox = deltaBox
        self.targetIsRegistered = targetIsRegistered
        self.stepNumber = stepNumber
    }
}

/// The closed question on the geometry crop: is the step's part there?
public enum ClosedCheckAnswer: String, Sendable, Hashable, Codable, CaseIterable {
    case present
    case absent
    case cannotTell = "cannot_tell"
}

/// What an advisor said. Each half may be missing, with the reason.
public struct StepCheckAdvice: Sendable, Equatable {
    /// The advisor's own verdict on photo against target.
    public var standalone: CheckVerdictV1?
    public var standaloneOutcome: String
    /// The closed question on the delta crop; nil when no crop applied.
    public var closed: ClosedCheckAnswer?
    public var closedOutcome: String
    public var milliseconds: Int

    public init(
        standalone: CheckVerdictV1?, standaloneOutcome: String, closed: ClosedCheckAnswer?, closedOutcome: String,
        milliseconds: Int
    ) {
        self.standalone = standalone
        self.standaloneOutcome = standaloneOutcome
        self.closed = closed
        self.closedOutcome = closedOutcome
        self.milliseconds = milliseconds
    }

    public static func skipped(_ reason: String) -> StepCheckAdvice {
        StepCheckAdvice(standalone: nil, standaloneOutcome: reason, closed: nil, closedOutcome: reason, milliseconds: 0)
    }
}

/// Judges one photo check. Implementations never throw: every failure is
/// an outcome name, and the primary check is never affected.
public protocol StepCheckModelAdvisor: Sendable {
    func advise(_ input: StepCheckAdviceInput) async -> StepCheckAdvice
}

/// How an advisor's answer may combine with the primary check (ADR 0018):
/// it may only move a verdict toward incomplete, never toward complete.
public enum ShadowMerge {
    public static func merge(primary: CheckVerdictV1, advice: StepCheckAdvice) -> CheckVerdictV1 {
        guard primary == .complete else { return primary }
        return advice.closed == .absent || advice.standalone == .incomplete ? .incomplete : .complete
    }
}

public enum CheckCrop {
    /// The pixel rectangle to crop for a normalized box, grown by `margin`
    /// of its own size on each side (context for the model) and kept inside
    /// the image. Nil for a box that falls outside the image.
    public static func rect(for box: CheckGeometryRecord.Box, imageWidth: Int, imageHeight: Int, margin: Double = 0.25) -> CGRect? {
        let width = Double(imageWidth), height = Double(imageHeight)
        guard width > 0, height > 0, box.width > 0, box.height > 0 else { return nil }
        let grow = margin * Double(max(box.width, box.height))
        let minX = max(0, Double(box.x) - grow) * width
        let minY = max(0, Double(box.y) - grow) * height
        let maxX = min(1, Double(box.x + box.width) + grow) * width
        let maxY = min(1, Double(box.y + box.height) + grow) * height
        guard maxX > minX, maxY > minY else { return nil }
        // Whole pixels that cover the box: floor the near edges, ceil the far.
        let x0 = minX.rounded(.down), y0 = minY.rounded(.down)
        let x1 = min(width, maxX.rounded(.up)), y1 = min(height, maxY.rounded(.up))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
