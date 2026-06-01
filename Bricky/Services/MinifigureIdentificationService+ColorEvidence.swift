import Foundation
import UIKit
import Vision
import os.log

extension MinifigureIdentificationService {

    /// Fast, on-device classification using saliency and shape analysis.
    /// Returns true if the image likely contains a single minifigure-like
    /// object (portrait aspect, focused attention, few distinct objects).
    ///
    /// Important bias note: a pile shot from typical phone distance often
    /// has 1–3 attention regions and a near-square primary object — which
    /// would trivially out-score "pile" if minifigure signals were not
    /// gated. So the rules here REQUIRE positive minifigure evidence
    /// (portrait aspect AND tight attention) before classifying as a
    /// minifigure. Ties default to PILE (the safer scan path), reversing
    /// the previous behavior where any focused-but-square subject got
    /// flagged as a minifigure.
    nonisolated func classifyImageContent(_ cgImage: CGImage) -> Bool {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()

        try? handler.perform([objectnessRequest, attentionRequest])

        let objectRegions = objectnessRequest.results?.first?.salientObjects ?? []
        let attentionRegions = attentionRequest.results?.first?.salientObjects ?? []

        var minifigureScore = 0
        var pileScore = 0

        // Signal 1: Object count — fewer objects → more likely single figure.
        // Bias toward pile because a single tightly-cropped pile sometimes
        // registers as 1–2 attention objects (the whole pile silhouette).
        if objectRegions.count == 1 {
            minifigureScore += 2
        } else if objectRegions.count == 2 {
            minifigureScore += 1
        } else if objectRegions.count >= 4 {
            pileScore += 4
        } else {
            pileScore += 1
        }

        // Signal 2: Attention focus — tight attention → single subject.
        // A pile fills the frame; a minifigure occupies a small portrait
        // slice. Raised the pile threshold so a wide subject scores pile.
        let attentionArea = attentionRegions.reduce(0.0) { sum, obj in
            sum + Double(obj.boundingBox.width * obj.boundingBox.height)
        }
        if attentionArea < 0.12 {
            minifigureScore += 3
        } else if attentionArea < 0.25 {
            minifigureScore += 1
        } else if attentionArea < 0.45 {
            pileScore += 1
        } else {
            pileScore += 3
        }

        // Signal 3: Primary object aspect ratio — minifigures are tall
        // (~2:1 portrait). A near-square primary or landscape primary is
        // almost certainly NOT a single figure. Aspect is the strongest
        // structural signal for minifigure-vs-pile.
        var aspectIsPortrait = false
        var aspectIsLandscape = false
        if let primaryBox = objectRegions
            .max(by: { ($0.boundingBox.width * $0.boundingBox.height) <
                       ($1.boundingBox.width * $1.boundingBox.height) })?
            .boundingBox {
            let aspect = primaryBox.height / max(primaryBox.width, 0.001)
            if aspect > 1.5 {
                minifigureScore += 4   // Strongly portrait
                aspectIsPortrait = true
            } else if aspect > 1.05 {
                minifigureScore += 2
                aspectIsPortrait = true
            } else if aspect < 0.7 {
                pileScore += 3         // Distinctly landscape → pile
                aspectIsLandscape = true
            }
            // 0.7..1.05 = roughly square → no aspect signal either way
            // (saliency commonly snaps to a square box around a small
            // portrait subject + its hand/shadow on a flat surface)
        }

        // Signal 4: Scene simplicity (attention region count).
        if attentionRegions.count <= 1 {
            minifigureScore += 1
        } else if attentionRegions.count >= 3 {
            pileScore += 2
        }

        // Hard guardrail: a *landscape* primary subject is essentially
        // never a single standing figure — that's a horizontal pile or
        // an overhead bin shot. Square primaries are still allowed as
        // minifigures because saliency often boxes a small portrait
        // figure together with hand/shadow into a near-square region.
        if aspectIsLandscape {
            return false
        }
        // Bonus: portrait + tight attention (<25%) is the canonical
        // minifigure signature (single figure, lots of background).
        if aspectIsPortrait && attentionArea < 0.25 {
            minifigureScore += 2
        }

        // Strict win required. Ties go to pile, the safer default —
        // pile scans degrade gracefully, but a misclassified minifigure
        // scan launches the wrong UI flow entirely.
        return minifigureScore > pileScore
    }

    // MARK: - Saliency Detection

    /// Use Vision's attention-based saliency to crop to the main subject,
    /// isolating the minifigure from the background.
    nonisolated func cropToSalientSubject(_ cgImage: CGImage) -> CGImage? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let observation = request.results?.first,
              let salientObject = observation.salientObjects?.first else {
            return nil
        }

        // VNRectangleObservation has normalized coordinates (0–1), origin bottom-left
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let box = salientObject.boundingBox

        // Add a small margin around the salient region
        let margin: CGFloat = 0.03
        let x = max(0, box.origin.x - margin) * w
        let y = max(0, (1.0 - box.origin.y - box.height) - margin) * h
        let cropW = min(w - x, (box.width + 2 * margin) * w)
        let cropH = min(h - y, (box.height + 2 * margin) * h)

        let cropRect = CGRect(x: x, y: y, width: cropW, height: cropH)
        guard cropRect.width > 10 && cropRect.height > 10 else { return nil }

        return cgImage.cropping(to: cropRect)
    }

    // MARK: - Feature Print

    /// Generate a `VNFeaturePrintObservation` for image similarity comparison.
    nonisolated func generateFeaturePrint(from cgImage: CGImage) -> VNFeaturePrintObservation? {
        VisionUtilities.featurePrint(for: cgImage)
    }

    // MARK: - Color Extraction

    struct RGB: Sendable {
        let r: UInt8, g: UInt8, b: UInt8
    }

    /// Per-part normalized scores (each 0.0–1.0) used by the torso-first
    /// cascade. See `fastColorBasedCandidates(...)` for how these combine:
    /// when `torso >= 0.80` the cascade uses torso as the primary
    /// classifier with the others as small consistency-check bonuses;
    /// otherwise it falls back to weighted joint inference using the
    /// priors documented in `docs/MINIFIGURE_ANATOMY.md`.
    struct PartScores {
        var torso: Double = 0
        var head: Double = 0
        var hair: Double = 0
        var legs: Double = 0
    }

    struct ScanColorEvidence: Equatable {
        let weights: [LegoColor: Double]
        let dominantColors: [LegoColor]

        var redWeight: Double {
            (weights[.red] ?? 0) + (weights[.darkRed] ?? 0)
        }

        var whiteWeight: Double { weights[.white] ?? 0 }
        var yellowWeight: Double { weights[.yellow] ?? 0 }

        var hasStrongRed: Bool { redWeight >= 0.08 }
        var hasStrongWhite: Bool { whiteWeight >= 0.08 }

        var looksLikeClassicSpacePalette: Bool {
            hasStrongRed && hasStrongWhite && yellowWeight >= 0.03
        }

        var debugSummary: String {
            dominantColors.prefix(6).map { color in
                "\(color.rawValue)=\(String(format: "%.2f", weights[color] ?? 0))"
            }.joined(separator: ", ")
        }
    }

    /// Color signal extracted from the top "hair / hat / headgear" band
    /// of the captured image. Used as a tiebreaker for ranking when
    /// CLIP and torso color cannot distinguish near-identical figures
    /// that differ only in hat color (e.g. Forestman fig-006867 with a
    /// brown hat vs. fig-006868 with a green hat — both share the same
    /// torso print and leg color, so neither CLIP nor generic color
    /// agreement can break the tie).
    struct HatColorEvidence: Equatable {
        let color: LegoColor
        /// 0…1 — fraction of band pixels classified as foreground.
        let coverage: Double

        /// True when the hat color carries discriminating signal —
        /// excludes neutrals (yellow/black/white/gray) where many
        /// catalog entries share the color and a match conveys little.
        var isChromatic: Bool {
            switch color {
            case .yellow, .black, .white, .gray, .darkGray, .transparent,
                 .transparentBlue, .transparentRed:
                return false
            default:
                return true
            }
        }

        /// Group near-equivalent LegoColors so a captured "Green" hat
        /// matches a catalog "Dark Green" hat without penalty.
        static func family(for c: LegoColor) -> Set<LegoColor> {
            switch c {
            case .red, .darkRed: return [.red, .darkRed]
            case .green, .darkGreen, .lime: return [.green, .darkGreen, .lime]
            case .blue, .darkBlue, .lightBlue: return [.blue, .darkBlue, .lightBlue]
            case .brown, .tan: return [.brown, .tan]
            case .gray, .darkGray: return [.gray, .darkGray]
            case .purple, .pink: return [.purple, .pink]
            default: return [c]
            }
        }
    }

    /// Sample the top hair/hat band of the captured image and return
    /// the dominant LegoColor with coverage. Mirrors the band geometry
    /// used by `HybridFigureAnalyzer` (top 12% Y, central 30–70% X)
    /// but classifies pixels with the same `mapForegroundLegoColor`
    /// pipeline that powers `extractScanColorEvidence`, so the two
    /// signals stay coherent.
    nonisolated func extractHatColorEvidence(from cgImage: CGImage) -> HatColorEvidence? {
        let subject = foregroundEvidenceCrop(cgImage: cgImage) ?? bestSubjectCrop(cgImage: cgImage)
        let w = subject.width
        let h = subject.height
        guard w > 8, h > 8 else { return nil }
        let bandRect = CGRect(
            x: Int(Double(w) * 0.30),
            y: 0,
            width: max(1, Int(Double(w) * 0.40)),
            height: max(1, Int(Double(h) * 0.12))
        )
        guard let band = subject.cropping(to: bandRect) else { return nil }

        let size = 48
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(band, in: CGRect(x: 0, y: 0, width: size, height: size))

        var counts: [LegoColor: Double] = [:]
        var totalWeight = 0.0
        var classifiedPixels = 0
        let totalPixels = size * size
        for offset in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let r = pixelData[offset]
            let g = pixelData[offset + 1]
            let b = pixelData[offset + 2]
            guard let mapped = mapForegroundLegoColor(r: r, g: g, b: b) else { continue }
            let weight = foregroundPixelWeight(r: r, g: g, b: b, color: mapped)
            counts[mapped, default: 0] += weight
            totalWeight += weight
            classifiedPixels += 1
        }

        guard totalWeight > 0,
              let (dominant, _) = counts.max(by: { $0.value < $1.value })
        else { return nil }
        let coverage = Double(classifiedPixels) / Double(totalPixels)
        return HatColorEvidence(color: dominant, coverage: coverage)
    }

    nonisolated func rankWithEvidenceCore(
        allFigures: [Minifigure],
        evidence: ScanColorEvidence,
        clipHits: [ClipEmbeddingIndex.Hit],
        hatEvidence: HatColorEvidence? = nil
    ) -> [ResolvedCandidate] {
        let clipById = Dictionary(uniqueKeysWithValues: clipHits.map { ($0.figureId, $0.cosine) })
        // CLIP retrieval gate: when CLIP returned hits, restrict ranking to
        // figures CLIP actually retrieved. Without this, candidates that have
        // no CLIP signal at all can outrank correct CLIP top-1 figures whenever
        // their color-only score happens to land near the confidence cap.
        // Ground-truth harness diagnosed this as the dominant failure mode
        // (CLIP top-1 correct on 5/9, but pipeline returned 2/9).
        // The Brickognize cloud fallback still covers cases where CLIP misses.
        //
        // Color-evidence rescue lane: CLIP can miss the correct figure
        // entirely when the catalog reference photo is low-quality (old
        // 1989 product shots vs. modern Icons photography). To avoid
        // permanent exclusion, also admit a small set of figures whose
        // catalog colors strongly agree with the captured palette AND
        // whose primary color family matches. These rescue candidates
        // get no CLIP score, so they can only displace CLIP candidates
        // when CLIP genuinely had no good match.
        let clipIdSet: Set<String> = Set(clipHits.map { $0.figureId })
        let requiredPrimaryFamilies = requiredPrimaryColorFamilies(for: evidence)
        let colorRescueSet: Set<String> = {
            guard !clipHits.isEmpty else { return [] }
            // Score every figure by colorAgreement, take the top 60
            // outside the CLIP set that pass the primary-color gate.
            let scoredOutsideClip: [(String, Double)] = allFigures.compactMap { fig in
                guard fig.imageURL != nil else { return nil }
                if clipIdSet.contains(fig.id) { return nil }
                let cols = weightedFigureColors(for: fig)
                if failsPrimaryColorGate(
                    figureColors: cols,
                    requiredFamilies: requiredPrimaryFamilies
                ) { return nil }
                let s = colorAgreementScore(figureColors: cols, evidence: evidence)
                guard s >= 0.55 else { return nil }
                return (fig.id, s)
            }
            let topIds = scoredOutsideClip
                .sorted { $0.1 > $1.1 }
                .prefix(60)
                .map { $0.0 }
            return Set(topIds)
        }()
        let clipGate: Set<String>? = clipHits.isEmpty
            ? nil
            : clipIdSet.union(colorRescueSet)
        let clipDiscrimination: Double = {
            guard clipHits.count >= 5 else { return 0 }
            return Double(clipHits[0].cosine - clipHits[4].cosine)
        }()

        let ranked = allFigures.compactMap { figure -> (ResolvedCandidate, Double)? in
            guard figure.imageURL != nil else { return nil }
            if let gate = clipGate, !gate.contains(figure.id) { return nil }
            let figureColors = weightedFigureColors(for: figure)
            // Primary-color gate: only used when CLIP isn't pre-filtering.
            // The CLIP top-160 is already a strong prefilter — adding the
            // color-family gate on top of it eliminates correct figures
            // whenever the scan's dominant color extraction misfires
            // (background tints, helmet visors, JPEG bleed). Ground-truth
            // harness diagnosed this as the cause of "missing entirely"
            // for several CLIP top-1 figures. We let the score's color
            // weighting and bonuses do the demoting instead, which is
            // graceful rather than binary.
            // Apply the primary-color gate when:
            //  - CLIP isn't pre-filtering, OR
            //  - one color family is overwhelmingly dominant (≥0.36)
            //    AND it leads the next family by ≥0.20.
            // The strong-dominance branch lets us eliminate clearly-wrong
            // CLIP near-twins (e.g. red/white figures when the scan is
            // unambiguously green) without harming the more typical case
            // where dominant-color extraction is noisy.
            let strongDominance = isStronglyDominantPalette(evidence)
            if (clipGate == nil || strongDominance),
               failsPrimaryColorGate(
                figureColors: figureColors,
                requiredFamilies: requiredPrimaryFamilies
               ) {
                return nil
            }
            let colorScore = colorAgreementScore(
                figureColors: figureColors,
                evidence: evidence
            )
            let hasRed = figureColors.contains { color, _ in
                color == .red || color == .darkRed
            }
            let hasWhite = figureColors.contains { color, _ in color == .white }
            let redVeto = evidence.hasStrongRed && !hasRed
            let whitePenalty = evidence.hasStrongWhite && !hasWhite ? 0.10 : 0.0

            let clipCosine = clipById[figure.id]
            let clipScore = clipCosine.map { normalizedClipScore($0) } ?? 0
            let hasClipSignal = clipCosine != nil

            // CLIP-led blend. Color is a tiebreaker, not a flipper.
            // The CLIP gate already restricted us to figures CLIP retrieved,
            // so the embedding has already done the visual matching work.
            // Heavy color weighting / bonuses were band-aids for the
            // pre-CLIP era and now actively harm accuracy by promoting
            // visually-unrelated figures whose catalog colors happen to
            // overlap with the scan (e.g. Imperial Soldier II's red+white
            // beating Johnny Thunder's correct CLIP rank-3 match).
            var score = hasClipSignal
                ? 0.96 * clipScore + 0.04 * colorScore
                : colorScore

            let redWhiteClassicVariant = evidence.looksLikeClassicSpacePalette
                && isRedWhiteClassicSpaceVariant(figure)

            // Hat-color tiebreaker. The torso/legs/CLIP signals all
            // tie when two figures share a torso print but differ only
            // in headgear color (e.g. Forestman fig-006867 brown hat
            // vs. fig-006868 green hat). The generic colorAgreement
            // pool can't separate them because both share equal green
            // torso/leg pixels. Sample the hair band directly and:
            //   * boost candidates whose catalog hat color matches
            //   * demote candidates whose catalog hat color is a
            //     different chromatic family
            // Skipped when captured hair coverage is low (bald/occluded)
            // or the captured hat color is non-chromatic (yellow/black/
            // gray hats are too common to discriminate).
            var hatPenaltyApplied = false
            if let hat = hatEvidence,
               hat.isChromatic,
               hat.coverage >= 0.18,
               let figureHatColor = figure.parts
                .first(where: { $0.slot == .hairOrHeadgear })
                .flatMap({ LegoColor(fromString: $0.color) }) {
                let capturedFamily = HatColorEvidence.family(for: hat.color)
                let figureFamily = HatColorEvidence.family(for: figureHatColor)
                if !capturedFamily.intersection(figureFamily).isEmpty {
                    score = min(score + 0.05, 1.0)
                } else {
                    let figureHatChromatic: Bool = {
                        switch figureHatColor {
                        case .yellow, .black, .white, .gray, .darkGray,
                             .transparent, .transparentBlue, .transparentRed:
                            return false
                        default:
                            return true
                        }
                    }()
                    if figureHatChromatic {
                        score *= 0.85
                        hatPenaltyApplied = true
                    }
                }
            }

            // Whitepenalty stays disabled — it was demoting CLIP-correct
            // figures that happened to lack white in their catalog parts list
            // (Johnny Thunder's brown jacket).
            _ = whitePenalty

            // Moustache / beard demotion. When the scan shows a hat
            // covering or framing the head, figures whose name highlights
            // a facial-hair distinguishing feature can't be discriminated
            // from their clean-faced siblings — and they're rarely the
            // right pick. This was added after the Forestmen Icons 2022
            // "Thin Moustache" reissue kept beating the original 1989
            // archer on near-tied CLIP cosines, despite the user's scan
            // showing no facial print under the green hat.
            if let hat = hatEvidence, hat.isChromatic, hat.coverage >= 0.18 {
                let lowerName = figure.name.lowercased()
                let mentionsFacialHair =
                    lowerName.contains("moustache")
                    || lowerName.contains("mustache")
                    || lowerName.contains("beard")
                    || lowerName.contains("goatee")
                if mentionsFacialHair {
                    score *= 0.92
                }
            }

            // Modern Icons reissue de-emphasis. The "Icons" line (2020+)
            // re-releases vintage figures with cleaner photography than
            // their 1989-era originals, which biases CLIP cosines toward
            // the reissue. A small constant haircut lets the original-era
            // variant of the same character compete when both are in the
            // top-N.
            if figure.year >= 2020,
               figure.theme.localizedCaseInsensitiveContains("Icons") {
                score *= 0.95
            }

            // Re-enable the red+white classic-space variant bonus narrowly:
            // when scan palette unmistakably looks classic-space (red+white+
            // yellow head) and the figure is a confirmed red+white classic
            // spaceman, give it a small boost. This is the only signal
            // distinguishing red+white-leg variants from all-red variants
            // when CLIP cosines are within 0.02 of each other.
            if redWhiteClassicVariant {
                score = min(score + 0.10, 1.0)
            }
            // Red veto. The scan's "strong red" detector fires at just 0.08
            // red weight, which is too low to justify hard exclusion when
            // some other color is actually dominant (e.g. a green figure
            // with red plume, or a yellow scan with a red accessory bleed).
            //  • If red is *substantially* dominant (≥0.30 weight) AND CLIP
            //    cosine isn't a near-perfect match (≥0.85), filter the
            //    candidate. The 0.85 cosine floor preserves the Johnny
            //    Thunder safeguard.
            //  • Otherwise, soft-penalize so a non-red CLIP near-twin can't
            //    silently overtake a correct red figure.
            if redVeto {
                let rawCosine = clipCosine.map(Double.init) ?? 0
                let redIsDominant = evidence.redWeight >= 0.30
                if redIsDominant && rawCosine < 0.85 {
                    return nil      // filter — red is clearly dominant
                } else if hasClipSignal && rawCosine >= 0.85 {
                    score *= 0.90   // mild penalty, keep CLIP's voice
                } else if clipScore >= 0.50 {
                    score *= 0.65   // moderate penalty
                } else {
                    score *= 0.25   // strong penalty for low-CLIP cases
                }
            }
            score = min(max(score, 0), 1)

            var confidence = 0.24 + 0.52 * score
            let colorAndClipAgree = colorScore >= 0.42 && clipScore >= 0.50
            if colorAndClipAgree && clipDiscrimination >= 0.045 {
                confidence += 0.08
            }
            if redVeto {
                // Survivors of the red-veto filter get capped by CLIP strength.
                let rawCosine = clipCosine.map(Double.init) ?? 0
                if hasClipSignal && rawCosine >= 0.85 {
                    confidence = min(confidence, 0.78)
                } else if clipScore >= 0.50 {
                    confidence = min(confidence, 0.55)
                } else {
                    confidence = min(confidence, 0.34)
                }
            } else if colorScore < 0.20 {
                // Looser cap (was 0.44). With the CLIP gate, "low color
                // score" usually just means catalog colors don't match
                // — not that the figure is wrong.
                confidence = min(confidence, 0.70)
            } else if !colorAndClipAgree {
                confidence = min(confidence, 0.78)
            }
            if hatPenaltyApplied {
                // Strong evidence the captured hat color disagrees with
                // the catalog hat color → cap confidence so a wrong-hat
                // CLIP near-twin can't claim a green-checkmark match.
                confidence = min(confidence, 0.55)
            }
            let confidenceCeiling = 0.92
            confidence = min(max(confidence, 0.05), confidenceCeiling)

            let reasoning: String
            if redVeto {
                reasoning = "Color conflict: scan contains strong red, but this candidate has no red catalog parts."
            } else if colorAndClipAgree {
                reasoning = "Embedding and captured colors agree."
            } else if hasClipSignal {
                reasoning = "Embedding candidate with limited color support — confidence capped."
            } else {
                reasoning = "Color evidence candidate — confidence capped until visual agreement improves."
            }

            return (
                ResolvedCandidate(
                    figure: figure,
                    modelName: hasClipSignal ? "clip+color" : "color-evidence",
                    confidence: confidence,
                    reasoning: reasoning
                ),
                score
            )
        }
        .sorted { lhs, rhs in
            if lhs.0.confidence != rhs.0.confidence { return lhs.0.confidence > rhs.0.confidence }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return (lhs.0.figure?.year ?? 0) > (rhs.0.figure?.year ?? 0)
        }

        return ranked.prefix(160).map(\.0)
    }

    nonisolated private func requiredPrimaryColorFamilies(for evidence: ScanColorEvidence) -> [Set<LegoColor>] {
        let families: [Set<LegoColor>] = [
            [.green, .darkGreen, .lime],
            [.red, .darkRed],
            [.blue, .darkBlue, .lightBlue],
            [.orange],
            [.purple, .pink],
            [.brown, .tan]
        ]
        let weightedFamilies = families
            .map { family in
                (family: family, weight: family.reduce(0.0) { $0 + (evidence.weights[$1] ?? 0) })
            }
            .sorted { $0.weight > $1.weight }
        guard let strongest = weightedFamilies.first,
              strongest.weight >= 0.16
        else { return [] }

        let second = weightedFamilies.dropFirst().first?.weight ?? 0
        guard strongest.weight >= second + 0.06 || strongest.weight >= 0.28 else { return [] }
        return [strongest.family]
    }

    nonisolated private func failsPrimaryColorGate(
        figureColors: [(LegoColor, Double)],
        requiredFamilies: [Set<LegoColor>]
    ) -> Bool {
        guard !requiredFamilies.isEmpty else { return false }
        let candidateColors = Set(figureColors.map(\.0))
        return requiredFamilies.contains { family in
            family.allSatisfy { !candidateColors.contains($0) }
        }
    }

    /// True when one chromatic color family is overwhelmingly dominant
    /// in the scan (≥0.36 weight AND leads the next family by ≥0.20).
    /// Used to decide whether to enforce the primary-color gate even
    /// when CLIP has already pre-filtered candidates — the CLIP top-K
    /// can still surface visually-similar figures from wrong color
    /// families when the captured subject's color is unmistakable.
    nonisolated private func isStronglyDominantPalette(_ evidence: ScanColorEvidence) -> Bool {
        let families: [Set<LegoColor>] = [
            [.green, .darkGreen, .lime],
            [.red, .darkRed],
            [.blue, .darkBlue, .lightBlue],
            [.orange],
            [.purple, .pink],
            [.brown, .tan]
        ]
        let weights = families
            .map { family in family.reduce(0.0) { $0 + (evidence.weights[$1] ?? 0) } }
            .sorted(by: >)
        guard let strongest = weights.first, strongest >= 0.36 else { return false }
        let second = weights.dropFirst().first ?? 0
        return strongest >= second + 0.20
    }

    nonisolated func extractScanColorEvidence(from cgImage: CGImage) -> ScanColorEvidence {
        let subject = foregroundEvidenceCrop(cgImage: cgImage) ?? bestSubjectCrop(cgImage: cgImage)
        let size = 72
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return ScanColorEvidence(weights: [:], dominantColors: [])
        }

        context.interpolationQuality = .medium
        context.draw(subject, in: CGRect(x: 0, y: 0, width: size, height: size))

        var counts: [LegoColor: Double] = [:]
        var total = 0.0
        for offset in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let r = pixelData[offset]
            let g = pixelData[offset + 1]
            let b = pixelData[offset + 2]
            guard let mapped = mapForegroundLegoColor(r: r, g: g, b: b) else { continue }
            let weight = foregroundPixelWeight(r: r, g: g, b: b, color: mapped)
            counts[mapped, default: 0] += weight
            total += weight
        }

        guard total > 0 else {
            return ScanColorEvidence(weights: [:], dominantColors: [])
        }

        let weights = counts.mapValues { $0 / total }
        let dominant = weights.sorted { $0.value > $1.value }.map(\.key)
        return ScanColorEvidence(weights: weights, dominantColors: dominant)
    }

    nonisolated private func weightedFigureColors(for figure: Minifigure) -> [(LegoColor, Double)] {
        figure.parts.compactMap { part in
            guard let color = LegoColor(fromString: part.color) else { return nil }
            let weight: Double
            switch part.slot {
            case .torso: weight = 0.45
            case .hairOrHeadgear: weight = 0.16
            case .head: weight = color == .yellow ? 0.06 : 0.12
            case .hips, .legLeft, .legRight: weight = 0.09
            case .armLeft, .armRight, .handLeft, .handRight: weight = 0.04
            case .accessory: weight = 0.03
            }
            return (color, weight)
        }
    }

    nonisolated private func colorAgreementScore(
        figureColors: [(LegoColor, Double)],
        evidence: ScanColorEvidence
    ) -> Double {
        var score = 0.0
        var maxPossible = 0.0
        for (color, weight) in figureColors {
            maxPossible += weight
            score += weight * (evidence.weights[color] ?? 0)
        }
        guard maxPossible > 0 else { return 0 }
        return min(score / maxPossible * 2.8, 1.0)
    }

    nonisolated private func normalizedClipScore(_ cosine: Float) -> Double {
        min(max((Double(cosine) - 0.55) / 0.27, 0), 1)
    }

    nonisolated private func mapForegroundLegoColor(r: UInt8, g: UInt8, b: UInt8) -> LegoColor? {
        let maxChannel = max(r, g, b)
        let minChannel = min(r, g, b)
        let saturation = Int(maxChannel) - Int(minChannel)
        let brightness = (Int(r) + Int(g) + Int(b)) / 3

        if r > 115,
           Int(r) > Int(g) + 35,
           Int(r) > Int(b) + 35,
           saturation > 45 {
            return brightness < 90 ? .darkRed : .red
        }

        if saturation < 18 && brightness >= 218 { return .white }
        if saturation <= 42 && brightness >= 188 { return .white }
        if saturation < 18 && brightness >= 45 && brightness <= 218 { return nil }
        if brightness < 10 && saturation < 8 { return nil }

        guard let nearest = LegoColor.closest(r: r, g: g, b: b),
              nearest.distance <= 110
        else { return nil }
        if [.gray, .darkGray, .tan, .brown].contains(nearest.color),
           saturation < 58 {
            return nil
        }
        return nearest.color
    }

    nonisolated private func foregroundEvidenceCrop(cgImage: CGImage) -> CGImage? {
        let size = 96
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var minX = size
        var minY = size
        var maxX = 0
        var maxY = 0
        var count = 0
        for y in 0..<size {
            for x in 0..<size {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]
                guard isFigureForegroundPixel(r: r, g: g, b: b) else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                count += 1
            }
        }

        guard count >= 16, maxX > minX, maxY > minY else { return nil }
        let scaleX = CGFloat(cgImage.width) / CGFloat(size)
        let scaleY = CGFloat(cgImage.height) / CGFloat(size)
        var rect = CGRect(
            x: CGFloat(minX) * scaleX,
            y: CGFloat(minY) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY
        )
        rect = rect.insetBy(dx: -max(rect.width * 0.35, scaleX * 5),
                            dy: -max(rect.height * 0.35, scaleY * 5))
        rect.origin.x = max(0, rect.origin.x)
        rect.origin.y = max(0, rect.origin.y)
        rect.size.width = min(CGFloat(cgImage.width) - rect.origin.x, rect.width)
        rect.size.height = min(CGFloat(cgImage.height) - rect.origin.y, rect.height)
        let areaRatio = (rect.width * rect.height) / CGFloat(cgImage.width * cgImage.height)
        guard areaRatio >= 0.03 && areaRatio <= 0.65 else { return nil }
        return cgImage.cropping(to: rect.integral)
    }

    nonisolated private func isFigureForegroundPixel(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let maxChannel = max(r, g, b)
        let minChannel = min(r, g, b)
        let saturation = Int(maxChannel) - Int(minChannel)
        let brightness = (Int(r) + Int(g) + Int(b)) / 3
        if brightness < 12 { return false }
        if r > 105 && Int(r) > Int(g) + 28 && Int(r) > Int(b) + 28 { return true }
        if g > 125 && Int(g) > Int(r) + 20 && Int(g) > Int(b) + 20 { return true }
        if r > 175 && g > 125 && b < 120 { return true }
        if saturation > 62 && brightness > 28 { return true }
        if saturation < 35 && brightness > 205 { return true }
        if brightness < 65 && saturation > 18 { return true }
        return false
    }

    nonisolated private func foregroundPixelWeight(
        r: UInt8,
        g: UInt8,
        b: UInt8,
        color: LegoColor
    ) -> Double {
        let maxChannel = max(r, g, b)
        let minChannel = min(r, g, b)
        let saturation = Double(Int(maxChannel) - Int(minChannel)) / 255.0
        switch color {
        case .red, .darkRed:
            return 1.8 + saturation
        case .white:
            return 0.85
        case .yellow:
            return 0.75 + saturation * 0.4
        default:
            return 0.70 + saturation * 0.6
        }
    }
}
