import Foundation
import simd

/// Mistakes the regression taxonomy never injects (its only misplacement
/// is an 8 mm shift along X). The challenge suite runs them on a fixture
/// with one part per step, so each edit is unambiguous, and scores them
/// apart from the release gates: most exist to show what the verifier
/// cannot yet catch, and a colour swap is invisible to depth by
/// construction (an expected failure until the RGB term, ADR 0008).
struct ChallengeScenario {
    enum Edit {
        /// Rigidly moves the whole delta's geometry.
        case buffers(offset: SIMD3<Float>)
        /// Replaces the delta's single placement; nil when the edit does not
        /// apply to that part.
        case placement((PartPlacement) -> PartPlacement?)
    }

    enum Expectation {
        case verdict(String)
        /// Complete when the edited part is depth-indistinguishable from
        /// the authored one (a symmetric rotation), misplaced otherwise.
        case completeIfDepthEquivalent
    }

    let label: String
    let edit: Edit
    let expectation: Expectation
    var expectedFailure = false

    /// The yaw a rotation scenario applies, for the symmetry cross-check.
    var quarterTurns: Int? {
        switch label {
        case "rot90": 1
        case "rot180": 2
        default: nil
        }
    }

    /// Same-footprint substitutions: a slope where a brick belongs.
    static let wrongPartSwaps = ["3001.dat": "3037.dat", "3003.dat": "3039.dat", "3004.dat": "3040b.dat"]

    static let all: [ChallengeScenario] = [
        .init(label: "shift1z", edit: .buffers(offset: SIMD3(0, 0, 0.008)), expectation: .verdict("misplaced")),
        // Engine space is Y-up; a plate is 8 LDU = 3.2 mm.
        .init(label: "plate_up1", edit: .buffers(offset: SIMD3(0, 0.0032, 0)), expectation: .verdict("misplaced")),
        .init(label: "plate_down1", edit: .buffers(offset: SIMD3(0, -0.0032, 0)), expectation: .verdict("misplaced")),
        .init(label: "rot90", edit: .placement { rotated($0, quarterTurns: 1) }, expectation: .completeIfDepthEquivalent),
        .init(label: "rot180", edit: .placement { rotated($0, quarterTurns: 2) }, expectation: .completeIfDepthEquivalent),
        .init(label: "wrong_part_same_footprint", edit: .placement { placement in
            wrongPartSwaps[placement.partReference].map { replacement(of: placement, part: $0) }
        }, expectation: .verdict("misplaced")),
        .init(label: "colour_swap", edit: .placement { placement in
            replacement(of: placement, colour: placement.colorCode == 4 ? 1 : 4)
        }, expectation: .verdict("misplaced"), expectedFailure: true),
    ]

    /// Rotates a placement about its own origin around LDraw's vertical axis.
    static func rotated(_ placement: PartPlacement, quarterTurns: Int) -> PartPlacement {
        let angle = Double(quarterTurns) * .pi / 2
        let (sine, cosine) = (sin(angle).rounded(), cos(angle).rounded())
        let rotation = LDrawTransform(a: cosine, c: sine, g: -sine, i: cosine)
        return replacement(of: placement, transform: placement.transform.multiplied(by: rotation))
    }

    static func replacement(
        of placement: PartPlacement,
        part: String? = nil,
        colour: Int? = nil,
        transform: LDrawTransform? = nil
    ) -> PartPlacement {
        PartPlacement(
            id: placement.id,
            partReference: part ?? placement.partReference,
            colorCode: colour ?? placement.colorCode,
            transform: transform ?? placement.transform,
            sourceSection: placement.sourceSection,
            sourceLine: placement.sourceLine,
            isSubmodelReference: placement.isSubmodelReference
        )
    }
}
