import Foundation

/// One frame the verifier judged, kept for an evidence window.
struct VerificationWindowSample: Sendable {
    let frameID: UUID
    let frame: RegistrationFrameInput
    let registration: ModelRegistration
    let result: StepVerification
    let ingestMilliseconds: Int
}

/// The last `capacity` judged frames, oldest first. About 0.7 MB per frame
/// with colour and mask, so the buffer exists only while evidence is on.
struct VerificationWindowBuffer {
    let capacity: Int
    private(set) var samples: [VerificationWindowSample] = []

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ sample: VerificationWindowSample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    mutating func removeAll() {
        samples.removeAll()
    }
}

/// A window ready to write: the buffered frames, the published verification
/// when it closed, and the declared truth if the user staged one.
struct VerificationWindowCapture: Sendable {
    let windowID: UUID
    let stepID: String
    let stepIndex: Int
    let trigger: VerificationWindowRecord.Trigger
    let samples: [VerificationWindowSample]
    let verification: StepVerification
    let staged: StagedVerificationDeclaration?
    /// Verifier compute since the step began, for the device row's latency.
    let ingestMillisecondsSinceBegin: Int
    let createdAt: Date
}

/// Where the verification controller sends windows; the evidence recorder
/// in the app, a fake in tests.
protocol VerificationWindowSink: Sendable {
    func record(_ window: VerificationWindowCapture) async
}
