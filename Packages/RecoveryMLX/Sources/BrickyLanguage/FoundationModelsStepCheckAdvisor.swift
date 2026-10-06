#if canImport(FoundationModels)
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import RecoveryEvidenceKit

/// The system model as a step-check advisor, in shadow (ADR 0018). Two
/// greedy, guided questions, each its own session:
/// - standalone: photo and target render, "complete, incomplete or
///   uncertain?", the same question the VLM answers;
/// - closed: with an AR check's delta box, the photo and the registered
///   render cropped to it, "is the part this step adds in place?". Geometry
///   chose the crop; the model is never asked where anything is.
/// Image attachments need the iOS/macOS 27 SDKs.
@available(iOS 27.0, macOS 27.0, *)
public struct FoundationModelsStepCheckAdvisor: StepCheckModelAdvisor {
    static let standaloneInstructions = """
    You compare a photo of a physical brick build with a rendered target \
    for one step of its instructions. Answer complete only if the photo \
    clearly matches the target. Prefer uncertain over guessing: a wrong \
    complete is the worst outcome. Judge only what you can see.
    """

    static let closedInstructions = """
    You are shown two close-up images of the same spot on a brick build, \
    from the same viewpoint. The expected image is a render of the part \
    this step adds. Say whether the photo shows that part in place. Answer \
    cannot tell when the photo is unclear or blocked. Judge only what you \
    can see.
    """

    public let deadline: Duration

    public init(deadline: Duration = .seconds(8)) {
        self.deadline = deadline
    }

    public func advise(_ input: StepCheckAdviceInput) async -> StepCheckAdvice {
        let started = ContinuousClock.now
        func elapsed() -> Int {
            let parts = started.duration(to: .now).components
            return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        }
        guard SystemLanguageModel.default.isAvailable else { return .skipped("unavailable_model") }
        guard let photo = Self.image(input.photoJPEG), let target = Self.image(input.targetJPEG) else {
            return .skipped("failed_image")
        }
        let (standalone, standaloneOutcome) = await standaloneVerdict(photo: photo, target: target, step: input.stepNumber)
        var closed: ClosedCheckAnswer?
        var closedOutcome = "skipped_no_box"
        if input.targetIsRegistered, let box = input.deltaBox,
           let photoRect = CheckCrop.rect(for: box, imageWidth: photo.width, imageHeight: photo.height),
           let targetRect = CheckCrop.rect(for: box, imageWidth: target.width, imageHeight: target.height),
           let photoCrop = photo.cropping(to: photoRect), let targetCrop = target.cropping(to: targetRect) {
            (closed, closedOutcome) = await closedAnswer(photo: photoCrop, expected: targetCrop)
        } else if !input.targetIsRegistered {
            closedOutcome = "skipped_guide_camera"
        }
        return StepCheckAdvice(
            standalone: standalone, standaloneOutcome: standaloneOutcome, closed: closed, closedOutcome: closedOutcome,
            milliseconds: elapsed()
        )
    }

    private func standaloneVerdict(photo: CGImage, target: CGImage, step: Int) async -> (CheckVerdictV1?, String) {
        do {
            let answer = try await withDeadline {
                let session = LanguageModelSession(instructions: Self.standaloneInstructions)
                return try await session.respond(
                    generating: GeneratedCheckVerdict.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32)
                ) {
                    "Does the photo of the build match the target for step \(step)?"
                    Attachment(photo).label("photo")
                    Attachment(target).label("target")
                }.content
            }
            guard let answer else { return (nil, "failed_timeout") }
            return (answer.verdict, "answered")
        } catch {
            return (nil, "failed_\(FoundationModelsRepairWording.reason(error))")
        }
    }

    private func closedAnswer(photo: CGImage, expected: CGImage) async -> (ClosedCheckAnswer?, String) {
        do {
            let answer = try await withDeadline {
                let session = LanguageModelSession(instructions: Self.closedInstructions)
                return try await session.respond(
                    generating: GeneratedClosedAnswer.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)
                ) {
                    "Is the part in the expected image in place in the photo?"
                    Attachment(photo).label("photo")
                    Attachment(expected).label("expected")
                }.content
            }
            guard let answer else { return (nil, "failed_timeout") }
            return (answer.answer, "answered")
        } catch {
            return (nil, "failed_\(FoundationModelsRepairWording.reason(error))")
        }
    }

    /// Nil when `deadline` passes first. A model call that ignores
    /// cancellation still finishes before this returns; the shadow runner
    /// owns the overall budget.
    private func withDeadline<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        let deadline = self.deadline
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func image(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// The standalone verdict; its cases mirror `CheckVerdictV1`.
@available(iOS 27.0, macOS 27.0, *)
@Generable
enum GeneratedVerdict {
    case complete, incomplete, uncertain
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GeneratedCheckVerdict {
    @Guide(description: "complete only if the photo clearly matches the target")
    var result: GeneratedVerdict

    var verdict: CheckVerdictV1 {
        switch result {
        case .complete: .complete
        case .incomplete: .incomplete
        case .uncertain: .uncertain
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
enum GeneratedClosed {
    case present, absent, cannotTell
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GeneratedClosedAnswer {
    var result: GeneratedClosed

    var answer: ClosedCheckAnswer {
        switch result {
        case .present: .present
        case .absent: .absent
        case .cannotTell: .cannotTell
        }
    }
}
#endif
