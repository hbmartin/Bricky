import Foundation

/// Errors raised by the on-device recovery pipeline (AR capture, candidate
/// rendering, and estimator plumbing). Kept separate from download/storage
/// errors (`VerifiedAssetError`) and authored-document errors
/// (`InstructionImportError`) so runtime conditions get accurate messages.
enum RecoveryError: LocalizedError {
    case insufficientMemory(requiredBytes: Int64, availableBytes: Int64)
    case invalidCaptureSet(reason: String)
    case invalidCaptureMetadata
    case captureImageMissing
    case candidateRenderFailed

    var errorDescription: String? {
        switch self {
        case let .insufficientMemory(required, available):
            "Recovery needs about \(ByteCountFormatter.string(fromByteCount: required, countStyle: .memory)) of free memory; about \(ByteCountFormatter.string(fromByteCount: available, countStyle: .memory)) is available. Close other apps and try again."
        case .invalidCaptureSet(let reason):
            reason
        case .invalidCaptureMetadata:
            "A recovery capture has invalid camera metadata. Re-align and capture the views again."
        case .captureImageMissing:
            "A guided recovery capture is missing. Capture the views again."
        case .candidateRenderFailed:
            "A candidate step image could not be rendered on this device. Try the analysis again."
        }
    }
}
