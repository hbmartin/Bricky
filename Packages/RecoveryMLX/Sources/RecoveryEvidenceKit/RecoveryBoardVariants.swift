import CoreGraphics
import CoreText
import Foundation

/// Board, label, slot-order, and prompt variants (ADR 0010 amendment). Each
/// changes what the model sees, so each is a recorded variant axis; the
/// baseline values reproduce what the app has always sent, byte for byte.
public enum BoardLayoutVersion: String, Codable, CaseIterable, Sendable {
    /// `RecoveryBoardLayoutV1`: a 4-column grid of up to 8 tiles.
    case v1
    /// `RecoveryBoardLayoutV2`: at most 4 tall tiles in one row for the
    /// finalist pass (about 3× the image tokens per tile), a side-by-side
    /// board for checks, and V1's grid for larger passes.
    case v2
}

public enum TileLabelStyle: String, Codable, CaseIterable, Sendable {
    /// "B · Step 12" — the baseline. The step number is visible to the
    /// model, which confounds any test of positional bias.
    case slotAndStep = "slot_step"
    /// "B" alone.
    case slotOnly = "slot"

    public func label(slot: String, stepNumber: Int) -> String {
        switch self {
        case .slotAndStep: "\(slot) · Step \(stepNumber)"
        case .slotOnly: slot
        }
    }
}

public enum SlotOrder: String, Codable, CaseIterable, Sendable {
    /// Finalists in step order every view — the true step is slot B
    /// whenever the narrowing pass was right.
    case sorted
    /// Finalists rotated per view, so each lands in each slot once across
    /// the three views and a model that favours a position gains nothing.
    case rotated
}

public enum PromptStyle: String, Codable, CaseIterable, Sendable {
    case baseline
    /// Names the slots actually on the board ("A–C") instead of always
    /// "A–H".
    case dynamicRange = "dynamic_range"
}

/// Where a step check's target render is drawn from. Each changes what the
/// model sees, so it is a recorded variant axis; the baseline is the guide
/// camera, the only target the app has ever sent.
public enum CheckTarget: String, Codable, CaseIterable, Sendable {
    /// The fixed three-quarter guide camera, independent of the photo.
    case guideCamera = "guide_camera"
    /// The photo's own camera pose under the locked registration, so the
    /// target shares the photo's viewpoint. Available only in AR.
    case registered
}

public enum SlotAssignment {
    /// View `v` gets the finalists rotated left by `v`.
    public static func rotated<Candidate>(_ finalists: [Candidate], viewIndex: Int) -> [Candidate] {
        guard !finalists.isEmpty else { return [] }
        let shift = ((viewIndex % finalists.count) + finalists.count) % finalists.count
        return Array(finalists[shift...] + finalists[..<shift])
    }

    public static func order<Candidate>(_ finalists: [Candidate], viewIndex: Int, order: SlotOrder) -> [Candidate] {
        order == .rotated ? rotated(finalists, viewIndex: viewIndex) : finalists
    }
}

/// The prompts the app sends, in one place. The baseline strings are the
/// ones the estimator and the step check have always used, byte for byte,
/// so recorded evidence replays unchanged.
public enum RecoveryPrompts {
    public static let baselineRank = "The large top image is a physical brick build. The labeled renders A–H are cumulative authored instruction steps in one fixed model frame. Rank the closest labels from best to worst. Return insufficient when angle, occlusion, or evidence cannot support a comparison."
    public static let baselineCheck = "The top image is the physical build. Candidate A is the cumulative authored target for this step. Decide complete, incomplete, or uncertain. Do not diagnose individual missing parts."

    public static func rank(slotCount: Int, style: PromptStyle) -> String {
        switch style {
        case .baseline:
            return baselineRank
        case .dynamicRange:
            let letters = "ABCDEFGH"
            let count = min(max(slotCount, 1), letters.count)
            let range = count == 1 ? "A" : "A–\(letters[letters.index(letters.startIndex, offsetBy: count - 1)])"
            return "The large top image is a physical brick build. The labeled renders \(range) are cumulative authored instruction steps in one fixed model frame. Rank the closest labels from best to worst. Return insufficient when angle, occlusion, or evidence cannot support a comparison."
        }
    }

    public static func check(style: PromptStyle, layout: BoardLayoutVersion = .v1) -> String {
        guard layout == .v2 else { return baselineCheck }
        return "The left image is the physical build. Candidate A, on the right, is the cumulative authored target for this step. Decide complete, incomplete, or uncertain. Do not diagnose individual missing parts."
    }
}

/// The second board layout. V1 stays untouched so its evidence replays
/// exactly; boards drawn here are recorded as `board_layout: v2`.
public enum RecoveryBoardLayoutV2 {
    public typealias Candidate = RecoveryBoardLayoutV1.Candidate
    public static let boardSide = RecoveryBoardLayoutV1.boardSide
    public static let maximumRowTiles = 4

    /// Up to 4 candidates share one row of tall tiles under the photo;
    /// larger passes fall back to V1's grid geometry with the chosen labels.
    public static func composeBoard(physical: CGImage, candidates: [Candidate], labels: TileLabelStyle) throws -> CGImage {
        guard (1...8).contains(candidates.count) else {
            throw RecoveryBoardLayoutV1.LayoutError.invalidCandidateCount(candidates.count)
        }
        let tall = candidates.count <= maximumRowTiles
        return try draw { context in
            RecoveryBoardLayoutV1.drawAspectFill(
                physical, in: RecoveryBoardLayoutV1.physicalRect,
                cornerRadius: RecoveryBoardLayoutV1.cornerRadius, context: context
            )
            let gap = RecoveryBoardLayoutV1.tileGap
            let top = RecoveryBoardLayoutV1.tileTop
            for (offset, candidate) in candidates.enumerated() {
                let frame: CGRect
                if tall {
                    let width = (992 - gap * CGFloat(candidates.count - 1)) / CGFloat(candidates.count)
                    frame = CGRect(x: 16 + CGFloat(offset) * (width + gap), y: top, width: width, height: CGFloat(boardSide) - top - 16)
                } else {
                    let row = offset / RecoveryBoardLayoutV1.columns
                    let column = offset % RecoveryBoardLayoutV1.columns
                    frame = CGRect(
                        x: 16 + CGFloat(column) * (RecoveryBoardLayoutV1.tileWidth + gap),
                        y: top + CGFloat(row) * (RecoveryBoardLayoutV1.tileHeight + gap),
                        width: RecoveryBoardLayoutV1.tileWidth,
                        height: RecoveryBoardLayoutV1.tileHeight
                    )
                }
                drawTile(candidate, in: frame, labels: labels, context: context)
            }
        }
    }

    /// Photo on the left, target on the right, each half the board.
    public static func composeCheckBoard(physical: CGImage, target: Candidate, labels: TileLabelStyle) throws -> CGImage {
        try draw { context in
            let half = (992 - RecoveryBoardLayoutV1.tileGap) / 2
            RecoveryBoardLayoutV1.drawAspectFill(
                physical, in: CGRect(x: 16, y: 16, width: half, height: 992),
                cornerRadius: RecoveryBoardLayoutV1.cornerRadius, context: context
            )
            drawTile(target, in: CGRect(x: 16 + half + RecoveryBoardLayoutV1.tileGap, y: 16, width: half, height: 992), labels: labels, context: context)
        }
    }

    private static func draw(_ body: (CGContext) throws -> Void) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: boardSide, height: boardSide, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw RecoveryBoardLayoutV1.LayoutError.contextUnavailable
        }
        context.translateBy(x: 0, y: CGFloat(boardSide))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.setFillColor(RecoveryBoardLayoutV1.gray(0.06))
        context.fill(CGRect(x: 0, y: 0, width: boardSide, height: boardSide))
        try body(context)
        guard let image = context.makeImage() else { throw RecoveryBoardLayoutV1.LayoutError.renderFailed }
        return image
    }

    private static func drawTile(_ candidate: Candidate, in frame: CGRect, labels: TileLabelStyle, context: CGContext) {
        let radius = RecoveryBoardLayoutV1.cornerRadius
        context.setFillColor(RecoveryBoardLayoutV1.gray(0.14))
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        RecoveryBoardLayoutV1.drawAspectFit(candidate.image, in: frame.insetBy(dx: 8, dy: 30), context: context)
        RecoveryBoardLayoutV1.drawLabel(
            labels.label(slot: candidate.slot, stepNumber: candidate.stepNumber),
            topLeft: CGPoint(x: frame.minX + 10, y: frame.minY + 7),
            font: CTFontCreateWithName("Menlo-Bold" as CFString, 19, nil),
            context: context
        )
    }
}
