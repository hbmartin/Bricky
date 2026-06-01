import Foundation
import UIKit
import Vision
import os.log

extension MinifigureIdentificationService {
    // MARK: - Phase 1: Fast Color-Based Candidates

    /// Extract dominant colors from the captured image and filter the catalog
    /// for figures whose torso/major parts match. Sorts by recency (year desc).
    /// Pure on-device, no network — completes in well under a second.
    nonisolated func fastColorBasedCandidates(
        cgImage: CGImage,
        allFigures: [Minifigure]
    ) -> [ResolvedCandidate] {
        // Crop to subject for cleaner color extraction. If saliency returns
        // a region covering most of the image (i.e. nothing was isolated),
        // fall back to a tighter center crop to remove background.
        let subjectCG = bestSubjectCrop(cgImage: cgImage)

        // Region-aware color extraction:
        //   - HEAD band (top 0–30%): used to detect generic yellow LEGO
        //     head so we can deweight yellow when it's not informative.
        //   - TORSO band (30–70%): the most distinctive region. Drives
        //     the primary color signal for matching.
        //   - FULL crop: secondary signal for legs/accessories.
        let headBand = cropVerticalBand(subjectCG, top: 0.0, bottom: 0.30)
        let torsoBand = cropVerticalBand(subjectCG, top: 0.30, bottom: 0.70)

        let headDominant = extractDominantColors(from: headBand, excludeBackground: true)
        let torsoDominant = extractDominantColors(from: torsoBand, excludeBackground: true)
        let fullDominant = extractDominantColors(from: subjectCG, excludeBackground: true)

        // Generic head detection: if the head region is dominated by a
        // pixel cluster very close to LEGO yellow (#F2CD37), the head is
        // generic and yellow should NOT be used as a primary torso
        // signal. Otherwise every chef/doctor/scientist (white torso,
        // yellow head) gets matched against yellow-torso figures.
        let hasGenericHead: Bool = {
            guard let headTop = headDominant.first else { return false }
            // LEGO yellow F2CD37 = (242, 205, 55). Use a generous distance
            // (~50 in weighted-RGB) so off-tone lighting still classifies.
            let dr = Double(headTop.r) - 242
            let dg = Double(headTop.g) - 205
            let db = Double(headTop.b) - 55
            let dist = sqrt(2.0 * dr * dr + 4.0 * dg * dg + 3.0 * db * db)
            return dist < 90
        }()

        // ── Silhouette layer: hair / headgear presence ──
        // Per the LEGO design heuristic (see docs/MINIFIGURE_ANATOMY.md),
        // hair/headgear is the SILHOUETTE layer — the first thing the
        // human eye registers. We don't try to attribute "this hair
        // looks like X's hair" (too widely shared across characters),
        // but PRESENCE/ABSENCE of headgear and its color does help
        // narrow the catalog: a figure with a tall white feather on
        // top should not match a bald yellow figure, and vice versa.
        //
        // Detection: sample the very top of the head band. If the
        // topmost stripe is dominated by a NON-yellow LEGO color with
        // decent coverage, the figure is wearing headgear of that color.
        //
        // MOVED ABOVE palette building so headgear color can be stripped
        // from fullDominant before it pollutes the torso scoring palette.
        let silhouetteBand = cropVerticalBand(subjectCG, top: 0.0, bottom: 0.15)
        let silhouetteDominant = extractDominantColors(from: silhouetteBand, excludeBackground: true)
        let headgearColor: LegoColor? = {
            guard let top = silhouetteDominant.first,
                  let lc = closestLegoColor(r: top.r, g: top.g, b: top.b)?.color
            else { return nil }
            // Yellow at the top = bald yellow head, not headgear.
            if lc == .yellow { return nil }
            return lc
        }()
        let figureHasHeadgear = headgearColor != nil

        // Build the primary palette from the TORSO band first (most
        // distinctive region), then fill from full-crop colors. Keeps
        // the torso color signal from being drowned out by a yellow
        // generic head, which is otherwise ~30% of the visible figure.
        //
        // When headgear is detected, filter its color out of the full-
        // crop contributions. A large black helmet or white hat can
        // dominate the full-image palette and shift the primary color
        // away from the torso — e.g. a black Space Police helmet on a
        // green-torso figure makes "black" the primary, matching every
        // black-torso figure instead of the correct green-torso one.
        let filteredFullDominant: [RGB] = {
            guard let hgColor = headgearColor else {
                return Array(fullDominant.prefix(3))
            }
            // Strip pixels whose closest LEGO color matches the headgear.
            return fullDominant.filter { pixel in
                guard let lc = closestLegoColor(r: pixel.r, g: pixel.g, b: pixel.b)?.color else { return true }
                return lc != hgColor
            }.prefix(3).map { $0 }
        }()
        let primaryRGB = torsoDominant.prefix(2) + filteredFullDominant
        var matchedPairs = primaryRGB.compactMap {
            closestLegoColor(r: $0.r, g: $0.g, b: $0.b)
        }

        // If generic head detected, strip yellow out of the matched
        // colors so it doesn't drive scoring (or compete to be primary).
        if hasGenericHead {
            matchedPairs.removeAll { $0.color == .yellow }
            Self.logger.debug("Generic LEGO head detected — deweighting yellow")
        }

        // Deduplicate while preserving order (first occurrence = highest
        // priority signal). The first surviving entry is our primary.
        var seen: Set<LegoColor> = []
        let matched = matchedPairs.filter { seen.insert($0.color).inserted }
        let colorSet = Set(matched.map(\.color))
        let primaryColor = matched.first?.color

        // Torso pattern signature: distinct LEGO colors in the band PLUS
        // a print-pixel ratio. The ratio captures real print detail
        // (zipper stripes, badges, insignia) that the color-only check
        // misses on a printed-but-monochromatic-looking torso such as
        // a black police jacket where the white print is small.
        let torsoSignature = analyzeTorsoSignature(
            torsoBandImage: torsoBand,
            hasGenericHead: hasGenericHead
        )
        let torsoBandColors = torsoSignature.bandColors
        let torsoIsPatterned = torsoSignature.isPatterned
        let torsoDetectedText = torsoSignature.detectedText

        Self.logger.debug(
            "Fast phase colors: \(matched.map { $0.color.rawValue }.joined(separator: ", ")) | torsoBand: \(torsoBandColors.map(\.rawValue).joined(separator: ", ")) | patterned: \(torsoIsPatterned) | printRatio: \(String(format: "%.2f", torsoSignature.printPixelRatio)) | OCR: \(torsoDetectedText.isEmpty ? "none" : torsoDetectedText.joined(separator: ", "))"
        )

        // ── Disambiguator layer: non-yellow head color ──
        // Per docs/MINIFIGURE_SCANNER_LESSONS.md: non-yellow heads
        // (Star Wars helmets, Harry Potter flesh-tone, alien colors,
        // etc.) are licensed-character / specific-character signals
        // and carry meaningful identity information. Yellow heads are
        // generic and carry none. Capture the captured head color
        // here for use as a per-figure scoring bonus below.
        let capturedNonYellowHeadColor: LegoColor? = {
            guard !hasGenericHead, let head = headDominant.first,
                  let lc = closestLegoColor(r: head.r, g: head.g, b: head.b)?.color
            else { return nil }
            return lc == .yellow ? nil : lc
        }()

        // ── Printed-legs detection ──
        // Per the same doc: most legs are solid color and add no
        // signal, BUT printed/dual-molded legs (boots, armor, tuxedo)
        // are character-specific and jump to torso-tier discriminative
        // power. Detect a "printed" capture by sampling whether the
        // legs band has 2+ distinct LEGO colors after background
        // filtering — same heuristic we already use for torsos.
        let legsBandColors: Set<LegoColor> = {
            // Sampled below; computed early so it's available when we
            // build legSlots / legsPrimary.
            var set: Set<LegoColor> = []
            // Reuse the same legs band sampled below by sampling here
            // first — a tiny duplicated sample, but keeps scoring
            // straight-line readable.
            let band = cropVerticalBand(subjectCG, top: 0.65, bottom: 1.0)
            for c in extractDominantColors(from: band, excludeBackground: true).prefix(4) {
                guard let lc = closestLegoColor(r: c.r, g: c.g, b: c.b)?.color else { continue }
                if hasGenericHead && lc == .yellow { continue }
                set.insert(lc)
            }
            return set
        }()
        let capturedHasPrintedLegs = legsBandColors.count >= 2

        // Score each figure. Heavy weight on combined torso+legs match
        // because that's the most distinctive signal once head color is
        // discounted (generic yellow heads dominate the catalog).
        let legSlots: Set<MinifigurePartSlot> = [.legLeft, .legRight, .hips]
        // Build the legs color band sample once — used to detect when
        // the captured legs color is distinctively present (boosts figs
        // whose leg parts also match that exact color).
        let legsBand = cropVerticalBand(subjectCG, top: 0.65, bottom: 1.0)
        let legsDominant = extractDominantColors(from: legsBand, excludeBackground: true)
        let legsPrimary: LegoColor? = {
            guard let firstLeg = legsDominant.first,
                  let mapped = closestLegoColor(r: firstLeg.r, g: firstLeg.g, b: firstLeg.b)?.color
            else { return nil }
            return (mapped == .yellow && hasGenericHead) ? nil : mapped
        }()

        let capturedClassicSpaceSuitColor: LegoColor? = {
            guard hasGenericHead,
                  torsoIsPatterned,
                  let helmetColor = headgearColor,
                  torsoBandColors.contains(helmetColor)
            else { return nil }
            let classicSuitColors: Set<LegoColor> = [.red, .blue, .white, .yellow, .black, .green, .orange, .brown, .pink]
            guard classicSuitColors.contains(helmetColor) else { return nil }
            if let legsPrimary, legsPrimary != helmetColor { return nil }
            return helmetColor
        }()

        var matches: [(figure: Minifigure, composite: Double, scores: PartScores, torsoConfident: Bool)] = []
        for fig in allFigures {
            guard fig.imageURL != nil else { continue }
            var s = PartScores()

            // ── Torso (PRIMARY CLASSIFIER, ~70–75% of total signal) ──
            // Torsos are nearly in 1:1 correspondence with figures: LEGO
            // almost never ships two distinct figures with the same torso
            // print, so a strong torso match collapses the hypothesis
            // space to ~one figure. We compute a normalized 0..1 torso
            // score and treat it as the primary classifier in the
            // cascade below.
            if let torso = fig.torsoPart, let tc = LegoColor(fromString: torso.color) {
                if colorSet.contains(tc) {
                    // Base: torso color appears anywhere on the captured figure.
                    s.torso = 0.50
                    if let primary = primaryColor, primary == tc {
                        // Torso color is the LARGEST captured cluster — the
                        // single strongest individual signal we can extract.
                        s.torso = 1.00
                    } else if torsoIsPatterned && torsoBandColors.contains(tc) {
                        // Patterned torso: catalog records ONE base color
                        // but the visible torso has multiple. A torso-band
                        // hit on a patterned figure is just as discriminating
                        // as a primary-color hit.
                        s.torso = 0.95
                    } else if torsoBandColors.contains(tc) {
                        // Match falls inside the torso band specifically
                        // (not just somewhere on the figure).
                        s.torso = 0.80
                    }
                }
            }

            // ── Headgear / hair (~10%, SILHOUETTE consistency check) ──
            // We do NOT try to attribute "this hair = X's hair" (hair
            // molds are aggressively reused). We only check whether the
            // captured silhouette is *consistent* with the candidate's
            // headgear presence + color.
            //
            // The check is intentionally ASYMMETRIC. Loose minifigures
            // are routinely photographed without their hat/hair (the
            // part falls off, gets lost, or the user deliberately
            // removes it to scan the head). So:
            //
            //   captured = NO hat, candidate = HAS hat → NEUTRAL
            //     (don't penalize — this is the most common real-world
            //     case for older Town/Castle figures whose hats are
            //     loose and easily separated)
            //   captured = HAS hat, candidate = NO hat → MISMATCH
            //     (less common; if the user kept the hat on, a bald
            //     candidate genuinely doesn't fit)
            //   match (both bald or both hatted) → consistency
            //   color match on top of presence → confirmation bonus
            let figHeadgearPart = fig.parts.first(where: { $0.slot == .hairOrHeadgear })
            let figHasHeadgear = figHeadgearPart != nil
            if figureHasHeadgear == figHasHeadgear {
                // Presence agreement (both bald or both wearing something).
                s.hair = 0.50
                if let captured = headgearColor,
                   let figColor = figHeadgearPart.flatMap({ LegoColor(fromString: $0.color) }),
                   captured == figColor {
                    // Color agreement on top of presence agreement.
                    s.hair = 1.00
                }
            } else if !figureHasHeadgear && figHasHeadgear {
                // Captured shows no hat but the catalog figure has one.
                // Likely the hat is just off in the photo. Treat as
                // neutral so a hatted catalog figure isn't ranked below
                // an actually-bald figure with the same torso colors.
                s.hair = 0.30
            }
            // (Captured HAS hat but candidate doesn't → leaves
            // s.hair = 0; that's a real mismatch worth penalizing.)

            // ── Head / face (~10%, DISAMBIGUATOR for licensed chars) ──
            // Yellow heads carry no identity signal (every generic
            // figure has one). Non-yellow heads (Star Wars helmets,
            // flesh-tone Harry Potter, etc.) are strong signals of a
            // specific licensed character — used as a consistency
            // booster against the candidate's catalog head color.
            if let captured = capturedNonYellowHeadColor,
               let headPart = fig.parts.first(where: { $0.slot == .head }),
               let figHeadColor = LegoColor(fromString: headPart.color),
               figHeadColor != .yellow,
               captured == figHeadColor {
                s.head = 1.00
            }

            // ── Legs (~3–5%, only meaningful when printed/dual-molded) ──
            // Solid leg colors are not figure-specific. They only
            // contribute when the captured legs band is itself
            // multi-colored (printed/dual-mold) AND the candidate
            // figure has dual-color leg parts.
            var legsMatched = false
            for part in fig.parts where legSlots.contains(part.slot) {
                if let pc = LegoColor(fromString: part.color) {
                    if colorSet.contains(pc) { legsMatched = true }
                    if let lp = legsPrimary, pc == lp { legsMatched = true }
                }
            }
            if capturedHasPrintedLegs {
                let legParts = fig.parts.filter { legSlots.contains($0.slot) }
                let figLegColorStrings = Set(legParts.map(\.color))
                if figLegColorStrings.count >= 2 {
                    // Both captured AND figure show printed legs.
                    s.legs = 0.70
                    let figLegLegoColors = Set(figLegColorStrings.compactMap(LegoColor.init(rawValue:)))
                    if !figLegLegoColors.isDisjoint(with: legsBandColors) {
                        // Plus actual color overlap — character-specific.
                        s.legs = 1.00
                    }
                }
            } else if legsMatched {
                // Plain solid-color legs match: tiny tiebreaker only.
                s.legs = 0.30
            }

            // ── Cascade combine ──
            // Torso-first cascade: when the torso classifier is
            // confident (torso score >= 0.80 AND we have actual
            // identifying evidence beyond a common base color), this
            // is essentially the figure — other parts only confirm/
            // refute. When torso confidence is low (occluded, faded,
            // ambiguous, or "the torso is just black"), fall back to
            // joint inference using the weighted priors documented in
            // docs/MINIFIGURE_ANATOMY.md §"Weighting".
            //
            // Why the extra evidence requirement: catalog `torso.color`
            // is just the base plastic color, shared by hundreds of
            // distinct figures (every black-jacket figure is
            // "Black"). Treating "color matched" as "torso is the
            // figure's primary key" would collapse every black-torso
            // scan onto whichever same-color figure happens to win the
            // year-desc tiebreak. The cascade only fires when EITHER:
            //   • the captured torso shows print evidence (multi-
            //     color band OR high print-pixel ratio), OR
            //   • the figure's catalog torso is a *rare* color
            //     (purple, lime, orange, dark red/green, light blue,
            //     pink) — these long-tail colors carry enough signal
            //     on their own that a base-color match is meaningful.
            let figureTorsoBaseColor: LegoColor? = fig.torsoPart.flatMap {
                LegoColor(fromString: $0.color)
            }
            let isRareTorsoColor: Bool = {
                guard let c = figureTorsoBaseColor else { return false }
                return !Self.commonTorsoColors.contains(c)
            }()
            let hasIdentifyingEvidence = torsoSignature.isPatterned || isRareTorsoColor
            let torsoConfident = s.torso >= MinifigureScanTuning.torsoConfidentScore && hasIdentifyingEvidence
            let composite: Double
            if torsoConfident {
                // Cascade: torso primary + small consistency-check bonuses.
                // Bonuses cap at ~0.15 total so torso always dominates.
                composite = s.torso
                    + 0.07 * s.hair
                    + 0.07 * s.head
                    + 0.03 * s.legs
            } else {
                // ADAPTIVE joint inference: when the torso color is
                // common (shared by hundreds/thousands of figures),
                // the base color alone is near-meaningless for ranking.
                // Boost the weight on auxiliary signals (head, hair,
                // legs) to break ties among the massive same-color pool.
                //
                // A common solid black torso matched by ~2400 figures
                // all scoring torso=1.0 — without boosted aux signals,
                // the ranking within this group is essentially random.
                let isCommonTorsoMatch = (figureTorsoBaseColor.map { Self.commonTorsoColors.contains($0) } ?? false)
                    && s.torso >= MinifigureScanTuning.torsoConfidentScore
                    && !torsoSignature.isPatterned
                if isCommonTorsoMatch {
                    // Common solid torso: downweight torso, upweight aux.
                    // Head/hair matter most for distinguishing licensed
                    // characters (HP, SW) within the same color group.
                    composite = 0.40 * s.torso
                              + 0.22 * s.head
                              + 0.22 * s.hair
                              + 0.10 * s.legs
                } else {
                    // Standard joint inference.
                    composite = 0.72 * s.torso
                              + 0.10 * s.head
                              + 0.10 * s.hair
                              + 0.04 * s.legs
                }
            }

            // Gate: require at minimum a torso color match to enter the
            // pool. Figures with s.torso == 0 (no color overlap at all)
            // that sneak through via neutral aux signals (s.hair = 0.30)
            // are noise — they scored 0.03 composite and would pollute
            // the candidate pool without contributing signal.
            //
            // OCR BOOST: If Vision detected text on the torso (e.g. "B",
            // "M", "POLICE"), boost figures whose name contains that text.
            // This is an extremely strong signal — a "B" on a black torso
            // with green accents immediately points to Blacktron. Match is
            // case-insensitive and checks both the figure name and theme.
            var ocrBoost: Double = 0.0
            if !torsoDetectedText.isEmpty && composite > 0 && s.torso > 0 {
                let nameLower = fig.name.lowercased()
                let themeLower = fig.theme.lowercased()
                for text in torsoDetectedText {
                    let textLower = text.lowercased()
                    // Match: name or theme contains the OCR text, OR
                    // the OCR text is a single letter that starts the name
                    // (e.g., "B" matches "Blacktron", "M" matches "M-Tron").
                    if nameLower.contains(textLower) || themeLower.contains(textLower) {
                        ocrBoost = max(ocrBoost, 0.30)
                    } else if textLower.count == 1 {
                        // Single letter: check if any word in the name starts with it
                        let words = nameLower.split(separator: " ").map(String.init)
                            + nameLower.split(separator: "-").map(String.init)
                        if words.contains(where: { $0.hasPrefix(textLower) }) {
                            ocrBoost = max(ocrBoost, 0.20)
                        }
                    }
                }
            }

            var classicSpaceBoost: Double = 0.0
            if let suitColor = capturedClassicSpaceSuitColor,
               let candidateSuitColor = classicSpaceSuitColor(for: fig),
               candidateSuitColor == suitColor {
                let torsoName = fig.torsoPart?.displayName.lowercased() ?? ""
                classicSpaceBoost = torsoName.contains("classic space logo") ? 0.35 : 0.12
            }

            if composite > 0 && s.torso > 0 {
                let finalComposite = min(composite + ocrBoost + classicSpaceBoost, 1.0)
                if ocrBoost > 0 {
                    Self.logger.debug("[TorsoOCR] boost \(fig.id) '\(fig.name)' +\(String(format: "%.2f", ocrBoost)) → \(String(format: "%.3f", finalComposite))")
                }
                if classicSpaceBoost > 0 {
                    Self.logger.debug("[ClassicSpace] boost \(fig.id) '\(fig.name)' +\(String(format: "%.2f", classicSpaceBoost)) → \(String(format: "%.3f", finalComposite))")
                }
                matches.append((fig, finalComposite, s, torsoConfident))
            }
        }

        // If color extraction failed entirely, fall back to recent figures
        if matches.isEmpty {
            Self.logger.info("Color match empty; using recent figures fallback")
            let recent = allFigures
                .filter { $0.imageURL != nil }
                .sorted { $0.year > $1.year }
                .prefix(8)
            return recent.map { fig in
                ResolvedCandidate(
                    figure: fig,
                    modelName: fig.name,
                    confidence: 0.3,
                    reasoning: "Recent catalog suggestion (color extraction inconclusive)."
                )
            }
        }

        // Cascade ordering: torso-confident figures ALWAYS rank above
        // non-confident ones (the cascade's primary classifier output is
        // never overridden by aux-signal noise). Within each tier, sort
        // by composite score, then by consistency hits (count of aux
        // slots whose color agrees), then by recency. The consistency
        // tiebreak matters when many figures share the same base
        // colors — without it, year-desc sorting alone would always
        // promote modern figures over older same-color ones.
        matches.sort {
            if $0.torsoConfident != $1.torsoConfident {
                return $0.torsoConfident && !$1.torsoConfident
            }
            if $0.composite != $1.composite { return $0.composite > $1.composite }
            let lhsHits =
                ($0.scores.head > 0 ? 1 : 0) +
                ($0.scores.hair > 0 ? 1 : 0) +
                ($0.scores.legs > 0 ? 1 : 0)
            let rhsHits =
                ($1.scores.head > 0 ? 1 : 0) +
                ($1.scores.hair > 0 ? 1 : 0) +
                ($1.scores.legs > 0 ? 1 : 0)
            if lhsHits != rhsHits { return lhsHits > rhsHits }
            return $0.figure.year > $1.figure.year
        }

        // Quality gate: if NO candidate could enter cascade mode AND
        // the captured torso shows essentially no print evidence, the
        // image is probably too low-quality to identify (blurry,
        // shadowed, or just a solid common-color torso that no
        // automated system can disambiguate from base color alone).
        // Cap top-result confidence and advise a retake.
        let anyCascadeHit = matches.contains(where: { $0.torsoConfident })
        let lowQualityScan = !anyCascadeHit
            && torsoSignature.printPixelRatio < 0.05
            && torsoSignature.bandColors.count <= 1

        // Return a wide pool so Phase 2 (visual feature-print refinement)
        // has plenty of figures to visually compare. Phase 2 trims down
        // to the top results by visual similarity. Without a wide pool
        // here, Phase 2 just re-ranks a handful of figures all picked
        // by color alone.
        //
        // ADAPTIVE POOL SIZE: When cascade mode fires (patterned /
        // rare-color torso), a small pool is fine — the color signal
        // already narrows the hypothesis space. When falling back to
        // joint inference on a common solid color (black, white, red,
        // blue…), thousands of figures tie on the same composite and
        // the correct one can easily fall outside a fixed-60 window.
        // Use a larger pool in the joint-inference case so Phase 2's
        // visual comparison has a fighting chance.
        let ambiguousCascadeTie: Bool = {
            guard let bestComposite = matches.first?.composite else { return false }
            let nearBest = matches.prefix(160).filter { bestComposite - $0.composite < 0.015 }.count
            return anyCascadeHit && nearBest >= 40
        }()
        let poolSize: Int = {
            if anyCascadeHit {
                if ambiguousCascadeTie { return 160 }
                return 60       // cascade narrows well — 60 is plenty
            }
            if lowQualityScan {
                return 100      // low quality, cast wider net
            }
            return 250          // joint inference on common color — need depth
        }()
        let top = matches.prefix(poolSize)
        Self.logger.info("[Phase1] pool size \(poolSize), returning \(top.count) candidates")
        return top.enumerated().map { (idx, match) in
            // Confidence comes primarily from torso classification quality
            // (cascade philosophy). Aux-signal matches can nudge it up
            // slightly but cannot rescue a low-torso-confidence candidate.
            var confidence: Double
            if match.torsoConfident {
                // 0.55 floor (any cascade hit) → ~0.85 ceiling.
                let auxBoost = 0.07 * match.scores.hair
                             + 0.07 * match.scores.head
                             + 0.03 * match.scores.legs
                confidence = min(0.85, 0.55 + 0.30 * match.scores.torso + auxBoost)
            } else {
                // Joint-inference fallback: lower ceiling, scaled by composite.
                // Ceiling at 0.62 (just below the 0.65 cloud trigger) so that
                // strong joint-inference matches can stand on their own without
                // requiring network confirmation.
                confidence = min(0.62, 0.20 + 0.35 * match.composite)
            }
            // Quality cap: when the scan can't carry identifying
            // evidence, no candidate deserves >0.40 confidence.
            if lowQualityScan {
                confidence = min(confidence, 0.40)
            }

            var reasoning: String
            if match.torsoConfident {
                reasoning = "Torso primary match (cascade)."
            } else if match.scores.torso > 0 {
                reasoning = "Torso color match only — falling back to joint inference (no print evidence on the captured torso)."
            } else {
                reasoning = "Joint inference: no torso color match."
            }
            // Surface the retake advisory on the top result so the UI
            // can show it without needing a separate API change.
            if lowQualityScan && idx == 0 {
                reasoning = "Low-quality torso capture — try retaking closer, with even lighting and no shadows. " + reasoning
            }

            return ResolvedCandidate(
                figure: match.figure,
                modelName: match.figure.name,
                confidence: confidence,
                reasoning: reasoning
            )
        }
    }

    /// Best available crop of the subject from a captured frame:
    /// 1. Try saliency. If it returns a tight region (<70% of image), use it.
    /// 2. Otherwise fall back to a centered crop (60% width × 80% height)
    ///    which approximately matches the pre-scan viewfinder rectangle.
    nonisolated func bestSubjectCrop(cgImage: CGImage) -> CGImage {
        if let salient = cropToSalientSubject(cgImage) {
            let w = CGFloat(cgImage.width)
            let h = CGFloat(cgImage.height)
            let salientArea = CGFloat(salient.width) * CGFloat(salient.height)
            let totalArea = w * h
            if salientArea / totalArea < 0.70 {
                return salient
            }
        }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let cropW = w * 0.60
        let cropH = h * 0.80
        let cropRect = CGRect(
            x: (w - cropW) / 2,
            y: (h - cropH) / 2,
            width: cropW,
            height: cropH
        )
        return cgImage.cropping(to: cropRect) ?? cgImage
    }

    /// Crop a vertical band from an image using normalized coordinates
    /// (0.0 = top, 1.0 = bottom). Used for region-aware color sampling
    /// — head band 0.0–0.30, torso band 0.30–0.70, legs band 0.70–1.0.
    /// Falls back to the input image if the band is degenerate.
    nonisolated func cropVerticalBand(_ cgImage: CGImage, top: CGFloat, bottom: CGFloat) -> CGImage {
        let h = CGFloat(cgImage.height)
        let w = CGFloat(cgImage.width)
        let y = max(0, top * h)
        let height = max(1, (bottom - top) * h)
        let rect = CGRect(x: 0, y: y, width: w, height: height)
        return cgImage.cropping(to: rect) ?? cgImage
    }
}
