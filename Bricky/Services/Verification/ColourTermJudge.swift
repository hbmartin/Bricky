import Foundation

/// How much say the RGB term has over a step verdict (ADR 0008 amendment,
/// Proposed). The app offers Off, Shadow and Block only; Full exists for
/// replay arms until real windows support it.
enum ColourTermMode: String, Sendable, CaseIterable {
    /// Not built: the verifier runs exactly as before.
    case off
    /// Computed and recorded; never changes a verdict.
    case shadow
    /// A colour disagreement turns `complete` into `incomplete`.
    case blockOnly = "block_only"
    /// Block only, and a colour agreement may also turn a marginal delta
    /// that depth alone would call present into `complete`.
    case full
}

/// The geometric verifier with the colour term beside it (M3.2). The
/// verifier renders colour tags in its own base batch and hands back the
/// frame's maps; this wrapper accumulates colour evidence from them and
/// applies the mode's authority, which is asymmetric by construction:
/// colour may take a `complete` away, may only corroborate a marginal
/// depth-present delta, and never completes anything on its own.
actor ColourTermJudge: StepJudging {
    /// Frames of colour evidence kept per step.
    static let maximumFrames = 120

    let mode: ColourTermMode
    private let table: ColourTable
    private let verifier: GeometricStepVerifier
    private let termConfiguration: ColourAgreementTerm.Configuration
    private var term: ColourAgreementTerm?
    private var frames: [ColourAgreementTerm.FrameEvidence] = []
    private var generation = 0
    /// The latest assessment, for logs and evidence windows.
    private(set) var lastAssessment: ColourAssessment?

    init(
        mode: ColourTermMode,
        table: ColourTable,
        configuration: GeometricStepVerifier.Configuration = .init(),
        termConfiguration: ColourAgreementTerm.Configuration = .init(),
        renderer: ExpectedDepthRenderer? = nil
    ) throws {
        self.mode = mode
        self.table = table
        self.termConfiguration = termConfiguration
        var configuration = configuration
        configuration.renderColourTags = true
        verifier = try GeometricStepVerifier(configuration: configuration, renderer: renderer)
    }

    func begin(stepID: String, geometry: StepGeometry) async {
        generation += 1
        frames = []
        lastAssessment = nil
        term = ColourAgreementTerm(
            table: table, billOfMaterials: Self.billOfMaterials(geometry), configuration: termConfiguration
        )
        await verifier.begin(stepID: stepID, geometry: geometry)
    }

    func resetEvidence() async {
        generation += 1
        frames = []
        lastAssessment = nil
        await verifier.resetEvidence()
    }

    func ingest(frame: RegistrationFrameInput, registration: ModelRegistration) async throws -> StepVerification {
        let started = generation
        let (verification, maps) = try await verifier.ingestReporting(frame: frame, registration: registration)
        // The step changed while the verifier rendered: its evidence was
        // discarded, so this frame adds none.
        guard started == generation else { return verification }
        if let maps, let term, let colourFrame = Self.colourFrame(maps) {
            frames.append(term.evidence(from: colourFrame))
            if frames.count > Self.maximumFrames { frames.removeFirst(frames.count - Self.maximumFrames) }
        }
        let assessment = term?.assess(frames)
        lastAssessment = assessment
        return Self.apply(
            mode, to: verification, assessment: assessment,
            depthPresentUnderMarginal: maps?.depthPresentUnderMarginal ?? false
        )
    }

    /// The mode's authority over one verdict.
    static func apply(
        _ mode: ColourTermMode,
        to verification: StepVerification,
        assessment: ColourAssessment?,
        depthPresentUnderMarginal: Bool
    ) -> StepVerification {
        guard mode == .blockOnly || mode == .full, let assessment else { return verification }
        if case .disagrees = assessment.status, verification.verdict == .complete {
            return verification.replacingVerdict(.incomplete)
        }
        if mode == .full, assessment.status == .agrees, depthPresentUnderMarginal,
           verification.detectability == .marginal, case .uncertain = verification.verdict {
            return verification.replacingVerdict(.complete)
        }
        return verification
    }

    /// The frame's colour evidence, when the verifier rendered tags and the
    /// relay delivered a colour plane on the same grid.
    static func colourFrame(_ maps: GeometricStepVerifier.FrameMaps) -> ColourFrame? {
        guard let completedTags = maps.completedTags, let deltaTags = maps.deltaTags else { return nil }
        let width = maps.delta.width, height = maps.delta.height
        return ColourFrame(
            colour: maps.colour?.count == width * height * 3 ? maps.colour ?? [] : [],
            observedDepth: maps.observedDepth,
            observedConfidence: maps.observedConfidence,
            completedDepth: maps.completed.depth,
            completedTags: completedTags.tags,
            deltaDepth: maps.delta.depth,
            deltaTags: deltaTags.tags,
            width: width,
            height: height
        )
    }

    /// Every colour the model uses, from the plan's flattened timeline when
    /// there is one, else from the step's own snapshots.
    static func billOfMaterials(_ geometry: StepGeometry) -> [Int] {
        if let segments = geometry.segments {
            return Set(segments.triangleColours).sorted()
        }
        let buffers = geometry.completedSnapshot.buffers + geometry.deltaSnapshot.buffers
        return Set(buffers.map(\.colorCode)).sorted()
    }
}
