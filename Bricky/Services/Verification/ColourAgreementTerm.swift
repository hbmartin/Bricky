import Foundation
import simd

/// One frame's colour evidence, aligned to the depth grid: the camera's
/// colour plane, the observed depth, and the completed and delta renders
/// with their colour tags (M3.1).
struct ColourFrame: Sendable {
    /// RGB8, interleaved, row-major (`RegistrationFrameInput.colour`).
    let colour: [UInt8]
    let observedDepth: [Float32]
    let observedConfidence: [UInt8]
    let completedDepth: [Float32]
    let completedTags: [UInt32]
    let deltaDepth: [Float32]
    let deltaTags: [UInt32]
    let width: Int
    let height: Int
}

/// The verdict of the colour term over the frames seen so far.
struct ColourAssessment: Sendable, Equatable {
    enum InconclusiveReason: String, Sendable, Equatable {
        /// No colour plane on the frames.
        case noColour = "no_colour"
        /// The completed parts could not serve as a colour chart.
        case uncalibrated
        /// A colour the camera cannot judge (transparent, chrome, …).
        case unobservableFinish = "unobservable_finish"
        case tooFewPixels = "too_few_pixels"
        case tooFewFrames = "too_few_frames"
        /// Agreement would prove nothing: the authored colour looks like
        /// what is beneath it, or like another colour the model uses.
        case nonDiscriminative = "non_discriminative"
        /// Near neither the authored colour nor another BOM colour.
        case ambiguous
    }

    enum Status: Sendable, Equatable {
        case agrees
        /// The observed colour is another colour the model uses.
        case disagrees(nearestCode: Int)
        case inconclusive(InconclusiveReason)

        var name: String {
            switch self {
            case .agrees: "agrees"
            case .disagrees: "disagrees"
            case .inconclusive(let reason): "inconclusive_\(reason.rawValue)"
            }
        }
    }

    /// The evidence for one authored colour in the region.
    struct Group: Sendable, Equatable {
        let code: Int
        var status: Status
        var pixels: Int
        var frames: Int
        var observedOklab: SIMD3<Float>?
        var authoredDistance: Float?
        var nearestCode: Int?
        var nearestDistance: Float?
        var beneathCode: Int?
    }

    var status: Status
    var groups: [Group]
    var framesWithColour: Int
    var framesCalibrated: Int
}

/// The non-learned RGB term (ADR 0008 amendment, M3.2): does the delta show
/// its authored colour? Compares the median calibrated Oklab colour of the
/// delta's depth-confirmed pixels against the authored colour, the nearest
/// other colour in the model's bill of materials, and the colour beneath.
///
/// Its authority is asymmetric and decided elsewhere (`ColourTermJudge`): a
/// disagreement may block a complete, an agreement may only corroborate a
/// depth-present marginal delta, and colour alone never completes anything.
///
/// Every threshold here is RECONSTRUCTED, to be tuned on Phase 1 real
/// windows. No synthetic colour sensor exists or may be invented (ADR 0008,
/// ADR 0014), so tests exercise mechanics only.
struct ColourAgreementTerm: Sendable {
    struct Configuration: Sendable {
        /// The verifier's depth agreement tolerance and confidence floor.
        var depthTolerance: Float = 0.006
        var minimumConfidence: UInt8 = 1
        /// The verifier's visible-footprint margin.
        var visibleMargin: Float = 0.0015
        var minimumPixelsPerFrame = 12
        var minimumFrames = 3
        /// Within this Oklab distance of the authored colour, it can agree.
        var agreeCeiling: Float = 0.12
        /// Agreement and disagreement each need this lead over the rival.
        var decisionMargin: Float = 0.04
        /// Colours this close cannot tell present from absent, or swapped.
        var discriminationFloor: Float = 0.08
        var calibration = SceneColourCalibration.Configuration()
    }

    let table: ColourTable
    /// The distinct colour codes the model uses: the rivals a wrong-colour
    /// part would most likely be.
    let billOfMaterials: [Int]
    var configuration = Configuration()

    /// One frame's per-colour evidence.
    struct FrameEvidence: Sendable, Equatable {
        struct CodeEvidence: Sendable, Equatable {
            /// Median calibrated observed colour, in Oklab.
            let observedOklab: SIMD3<Float>
            let pixels: Int
            /// The most common colour of the completed surface beneath.
            let beneathCode: Int?
        }

        var byCode: [Int: CodeEvidence]
        var calibration: SceneColourCalibration.Fit?
        var hadColour: Bool
        /// Authored codes present in the region but not observable.
        var unobservable: Set<Int>
        /// Authored codes with too few confirmed pixels this frame.
        var thin: Set<Int>
    }

    /// The delta's visible, colour-tagged pixels, eroded by one pixel so the
    /// separately compiled tag pass never contributes an edge (ADR 0006).
    func deltaRegion(_ frame: ColourFrame) -> [Int] {
        let width = frame.width, height = frame.height
        var inside = [Bool](repeating: false, count: width * height)
        for index in inside.indices where frame.deltaTags[index] != 0 && frame.deltaDepth[index] > 0 {
            let behind = frame.completedDepth[index]
            inside[index] = behind <= 0 || frame.deltaDepth[index] < behind - configuration.visibleMargin
        }
        return Self.eroded(inside, width: width, height: height)
    }

    /// Completed-surface pixels outside the delta: the colour chart.
    func chartRegion(_ frame: ColourFrame) -> [Int] {
        let width = frame.width, height = frame.height
        var inside = [Bool](repeating: false, count: width * height)
        for index in inside.indices where frame.completedTags[index] != 0 && frame.completedDepth[index] > 0 {
            let delta = frame.deltaDepth[index]
            inside[index] = delta <= 0 || frame.completedDepth[index] < delta - configuration.visibleMargin
        }
        return Self.eroded(inside, width: width, height: height)
    }

    /// Evidence from one frame. `region` restricts the delta pixels, e.g. to
    /// one placement's footprint; nil uses the whole delta.
    func evidence(from frame: ColourFrame, region: [Int]? = nil) -> FrameEvidence {
        let count = frame.width * frame.height
        guard frame.colour.count == count * 3 else {
            return FrameEvidence(byCode: [:], calibration: nil, hadColour: false, unobservable: [], thin: [])
        }
        var chart: [ColourSample] = []
        for index in chartRegion(frame) where confirmed(frame, index, expected: frame.completedDepth[index]) {
            let code = Int(frame.completedTags[index]) - 1
            guard let expected = table.entry(for: code).linear else { continue }
            chart.append(ColourSample(observed: observedLinear(frame, index), expected: expected, code: code))
        }
        let calibration = SceneColourCalibration.fit(chart, configuration: configuration.calibration)
        var pixelsByCode: [Int: [Int]] = [:]
        var unobservable: Set<Int> = []
        for index in region ?? deltaRegion(frame) where confirmed(frame, index, expected: frame.deltaDepth[index]) {
            let code = Int(frame.deltaTags[index]) - 1
            guard table.entry(for: code).oklab != nil else {
                unobservable.insert(code)
                continue
            }
            pixelsByCode[code, default: []].append(index)
        }
        var byCode: [Int: FrameEvidence.CodeEvidence] = [:]
        var thin: Set<Int> = []
        for (code, pixels) in pixelsByCode {
            guard pixels.count >= configuration.minimumPixelsPerFrame else {
                thin.insert(code)
                continue
            }
            guard case .calibrated = calibration else { continue }
            let oklab = pixels.compactMap { index in
                calibration.apply(observedLinear(frame, index)).map(ColourMath.oklab(linear:))
            }
            byCode[code] = FrameEvidence.CodeEvidence(
                observedOklab: Self.componentMedian(oklab),
                pixels: pixels.count,
                beneathCode: Self.mode(pixels.compactMap { index in
                    frame.completedTags[index] == 0 ? nil : Int(frame.completedTags[index]) - 1
                })
            )
        }
        return FrameEvidence(
            byCode: byCode, calibration: calibration, hadColour: true, unobservable: unobservable, thin: thin
        )
    }

    /// The assessment over accumulated frames.
    func assess(_ frames: [FrameEvidence]) -> ColourAssessment {
        let withColour = frames.filter(\.hadColour)
        let calibrated = withColour.filter { if case .calibrated = $0.calibration { return true } else { return false } }
        var assessment = ColourAssessment(
            status: .inconclusive(.noColour), groups: [],
            framesWithColour: withColour.count, framesCalibrated: calibrated.count
        )
        guard !withColour.isEmpty else { return assessment }
        var codes = Set<Int>()
        for evidence in withColour {
            codes.formUnion(evidence.byCode.keys)
            codes.formUnion(evidence.unobservable)
            codes.formUnion(evidence.thin)
        }
        assessment.groups = codes.sorted().map { code in group(code: code, frames: withColour) }
        assessment.status = Self.combine(assessment.groups, calibratedFrames: calibrated.count)
        return assessment
    }

    // MARK: - Decisions

    private func group(code: Int, frames: [FrameEvidence]) -> ColourAssessment.Group {
        var group = ColourAssessment.Group(code: code, status: .inconclusive(.tooFewPixels), pixels: 0, frames: 0)
        guard let authored = table.entry(for: code).oklab else {
            group.status = .inconclusive(.unobservableFinish)
            return group
        }
        let evidence = frames.compactMap { $0.byCode[code] }
        group.frames = evidence.count
        group.pixels = evidence.reduce(0) { $0 + $1.pixels }
        guard !evidence.isEmpty else { return group }
        guard evidence.count >= configuration.minimumFrames else {
            group.status = .inconclusive(.tooFewFrames)
            return group
        }
        let observed = Self.componentMedian(evidence.map(\.observedOklab))
        group.observedOklab = observed
        group.beneathCode = Self.mode(evidence.compactMap(\.beneathCode))
        let authoredDistance = ColourMath.distance(observed, authored)
        group.authoredDistance = authoredDistance
        let rivals = billOfMaterials.filter { $0 != code }.compactMap { rival in
            table.entry(for: rival).oklab.map { (code: rival, oklab: $0) }
        }
        let nearest = rivals.min { ColourMath.distance(observed, $0.oklab) < ColourMath.distance(observed, $1.oklab) }
        group.nearestCode = nearest?.code
        let nearestDistance = nearest.map { ColourMath.distance(observed, $0.oklab) }
        group.nearestDistance = nearestDistance
        // Another colour the model uses, clearly closer than the authored
        // one: a swapped part, even when the authored colour matches what
        // is beneath (absence would show the authored colour there).
        if let nearest, let nearestDistance, nearestDistance + configuration.decisionMargin < authoredDistance {
            group.status = .disagrees(nearestCode: nearest.code)
            return group
        }
        let rivalFloor = rivals.map { ColourMath.distance(authored, $0.oklab) }.min() ?? .infinity
        let beneathFloor = group.beneathCode.flatMap { table.entry(for: $0).oklab }
            .map { ColourMath.distance(authored, $0) } ?? .infinity
        if authoredDistance <= configuration.agreeCeiling,
           authoredDistance + configuration.decisionMargin < (nearestDistance ?? .infinity) {
            group.status = min(rivalFloor, beneathFloor) < configuration.discriminationFloor
                ? .inconclusive(.nonDiscriminative)
                : .agrees
            return group
        }
        group.status = .inconclusive(.ambiguous)
        return group
    }

    /// A disagreement anywhere decides; agreement needs every group.
    static func combine(_ groups: [ColourAssessment.Group], calibratedFrames: Int) -> ColourAssessment.Status {
        if let disagreeing = groups.first(where: { if case .disagrees = $0.status { return true } else { return false } }) {
            return disagreeing.status
        }
        guard !groups.isEmpty else { return .inconclusive(calibratedFrames == 0 ? .uncalibrated : .tooFewPixels) }
        if groups.allSatisfy({ $0.status == .agrees }) { return .agrees }
        if calibratedFrames == 0 { return .inconclusive(.uncalibrated) }
        return groups.first { $0.status != .agrees }?.status ?? .inconclusive(.tooFewPixels)
    }

    // MARK: - Pixels

    private func confirmed(_ frame: ColourFrame, _ index: Int, expected: Float32) -> Bool {
        guard frame.observedConfidence[index] >= configuration.minimumConfidence else { return false }
        let depth = frame.observedDepth[index]
        return depth.isFinite && depth > 0 && abs(depth - expected) <= configuration.depthTolerance
    }

    private func observedLinear(_ frame: ColourFrame, _ index: Int) -> SIMD3<Float> {
        ColourMath.linear(rgb8: frame.colour[index * 3], frame.colour[index * 3 + 1], frame.colour[index * 3 + 2])
    }

    /// Keeps a pixel only when it and its four neighbours are inside.
    static func eroded(_ inside: [Bool], width: Int, height: Int) -> [Int] {
        var kept: [Int] = []
        guard width > 2, height > 2 else { return kept }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                if inside[index], inside[index - 1], inside[index + 1], inside[index - width], inside[index + width] {
                    kept.append(index)
                }
            }
        }
        return kept
    }

    static func componentMedian(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !values.isEmpty else { return .zero }
        return SIMD3(
            SceneColourCalibration.median(values.map(\.x)),
            SceneColourCalibration.median(values.map(\.y)),
            SceneColourCalibration.median(values.map(\.z))
        )
    }

    static func mode(_ codes: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        for code in codes { counts[code, default: 0] += 1 }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}
