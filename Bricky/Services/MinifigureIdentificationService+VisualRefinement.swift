import Foundation
import UIKit
import Vision
import os.log

extension MinifigureIdentificationService {

    /// Map a Vision feature-print distance to a calibrated 0–1
    /// confidence value. Single source of truth for the empirical
    /// piecewise curve used throughout Phase 2 visual refinement:
    ///   0.0 → 0.95, 0.4 → 0.88, 0.7 → 0.78, 1.0 → 0.55, 1.5+ → 0.30.
    /// Recalibrated because VNFeaturePrint distances on minifigure
    /// photos typically cluster in 0.5–0.8; the older curve penalized
    /// that range too harshly (~69% for correct matches).
    nonisolated static func distanceToConfidence(_ distance: Float) -> Double {
        let d = Double(distance)
        if d <= 0.4 { return 0.95 - d * 0.175 }             // 0.95 → 0.88
        if d <= 0.7 { return 0.88 - (d - 0.4) * (1.0 / 3.0) } // 0.88 → 0.78
        if d <= 1.0 { return 0.78 - (d - 0.7) * 0.767 }     // 0.78 → 0.55
        return max(0.30, 0.55 - (d - 1.0) * 0.50)
    }

    /// Re-rank fast-phase candidates by visual similarity using reference
    /// images permitted by the active scan mode.
    ///
    /// If no candidates have an allowed local image, returns an empty
    /// candidate list and the caller keeps the fast-phase results.
    func refineWithLocalReferenceImages(
        cgImage: CGImage,
        fastCandidates: [ResolvedCandidate],
        rawEmbeddingCosines: [String: Float] = [:],
        embeddingDiscrimination: Double = 0.0,
        phase1Ids: Set<String> = []
    ) async -> RefinementOutcome {
        let identificationMode = ScanSettings.shared.identificationMode
        // Generate the captured-image feature prints off the main actor.
        // Two prints: one over the full subject (silhouette / overall
        // figure shape — useful for general visual similarity) and one
        // over just the torso band (where the print pattern lives, and
        // where the figure's primary key actually resides). The torso-
        // band print is what tells "printed Police torso" apart from
        // "solid Ninjago torso" when both share Black as the catalog
        // base color.
        // Capture-side feature extraction. We compute three signatures
        // up front so each reference comparison only pays the cost
        // of the per-ref crops:
        //   • full-figure VNFeaturePrint (overall silhouette / hue)
        //   • torso-band VNFeaturePrint (print pattern in embedding space)
        //   • torso-band TorsoVisualSignature (spatial color + edge layout)
        // The TorsoVisualSignature is the new structural reranker that
        // captures *where* color/print lives, not just overall hue —
        // see TorsoVisualSignature.swift for the rationale.
        let captured: (full: VNFeaturePrintObservation?, torso: VNFeaturePrintObservation?, signature: TorsoVisualSignature?, torsoCG: CGImage?) = await Task.detached(priority: .userInitiated) { [self] in
            let subjectCG = self.cropToSalientSubject(cgImage) ?? cgImage
            let fullPrint = self.generateFeaturePrint(from: subjectCG)
            let torsoBandCG = self.cropVerticalBand(subjectCG, top: 0.30, bottom: 0.70)
            let torsoPrint = self.generateFeaturePrint(from: torsoBandCG)
            let sig = TorsoVisualSignatureExtractor.signature(for: torsoBandCG)
            return (fullPrint, torsoPrint, sig, torsoBandCG)
        }.value

        guard let capturedFullPrint = captured.full else { return .empty }
        let capturedTorsoPrint = captured.torso
        let capturedTorsoSignature = captured.signature

        // Build a list of (figure, localImage) — only figures whose image
        // is already available offline. Check the bundled reference set
        // first (curated, ships with the app), then fall back to the disk
        // URL cache (figures the user has previously viewed in the catalog).
        let cache = MinifigureImageCache.shared
        let bundled = MinifigureReferenceImageStore.shared
        let userImages = UserFigureImageStorage.shared
        var userReferenceCount = 0
        var bundledReferenceCount = 0
        var cachedReferenceCount = 0
        var fetchedReferenceCount = 0
        var fetchSkippedDueToMode = false
        var localPairs: [(figure: Minifigure, image: UIImage, colorConfidence: Double)] = []
        var colorOnly: [ResolvedCandidate] = []
        var missingForFetch: [(figure: Minifigure, url: URL, colorConfidence: Double)] = []
        for candidate in fastCandidates {
            guard let fig = candidate.figure else { continue }
            // User-added figures always have their photo on disk.
            if MinifigureCatalog.isUserFigureId(fig.id),
               let img = userImages.image(for: fig.id) {
                localPairs.append((fig, img, candidate.confidence))
                userReferenceCount += 1
                continue
            }
            if let img = bundled.image(for: fig.id) {
                localPairs.append((fig, img, candidate.confidence))
                bundledReferenceCount += 1
                continue
            }
            if identificationMode.allowsDiskCachedReferenceImages,
               let url = fig.imageURL,
               let img = cache.image(for: url) {
                localPairs.append((fig, img, candidate.confidence))
                cachedReferenceCount += 1
                continue
            }
            // No local image yet. If the figure has an HTTP(S) image
            // URL we can try to fetch it opportunistically below;
            // otherwise it stays color-only.
            if let url = fig.imageURL, !url.isFileURL {
                missingForFetch.append((fig, url, candidate.confidence))
            }
            colorOnly.append(candidate)
        }

        // ── Opportunistic on-demand reference fetch ──
        //
        // Phase 2 can only torso-band-rerank candidates whose reference
        // image is already on-device. The bundled curated set covers
        // ~3,000 popular figures, but the catalog has ~16,000 — so for
        // many real-world scans the actual figure isn't in the bundle
        // and the visual pipeline can't verify it at all.
        //
        // To fix this without ballooning the bundle, we download the
        // top-K candidate thumbnails in parallel here. Each download is
        // tiny (~10–30 KB JPEG from rebrickable's CDN) and gets written
        // to MinifigureImageCache's disk tier via .store() — so the
        // FIRST scan of a given figure pays the network cost, and every
        // scan after that uses the cached image with zero latency.
        //
        // Budget: max 24 parallel downloads with a 4s overall timeout.
        // If the network is slow / offline we silently fall back to the
        // existing color-only behavior.
        let MAX_FETCH = MinifigureScanTuning.maxReferenceFetch
        let FETCH_TIMEOUT: TimeInterval = MinifigureScanTuning.referenceFetchTimeout
        if !missingForFetch.isEmpty && identificationMode.allowsNetworkReferenceFetch {
            // DIVERSITY-AWARE FETCH: Instead of purely taking the top-K
            // by confidence (which clusters on figures with identical
            // colors), spread fetches across different themes and years.
            // This gives Phase 2 visual comparison access to a wider
            // variety of candidate appearances.
            var toFetch: [(figure: Minifigure, url: URL, colorConfidence: Double)] = []
            var seenThemes: [String: Int] = [:]
            let maxPerTheme = max(4, MAX_FETCH / 4)
            let sorted = missingForFetch.sorted { $0.colorConfidence > $1.colorConfidence }
            for item in sorted {
                guard toFetch.count < MAX_FETCH else { break }
                let theme = item.figure.theme
                let count = seenThemes[theme, default: 0]
                if count < maxPerTheme {
                    toFetch.append(item)
                    seenThemes[theme] = count + 1
                }
            }
            // If we have remaining budget, fill with remaining candidates
            if toFetch.count < MAX_FETCH {
                let fetchedIds = Set(toFetch.map { $0.figure.id })
                for item in sorted where !fetchedIds.contains(item.figure.id) {
                    guard toFetch.count < MAX_FETCH else { break }
                    toFetch.append(item)
                }
            }
            let fetchedImages = await fetchReferenceImages(
                Array(toFetch),
                overallTimeout: FETCH_TIMEOUT
            )
            if !fetchedImages.isEmpty {
                Self.logger.info("Opportunistically fetched \(fetchedImages.count) reference image(s)")
            }
            fetchedReferenceCount = fetchedImages.count
            // Promote any successfully-fetched figures from colorOnly
            // into localPairs so they get torso-band-reranked.
            for (figId, image, colorConf) in fetchedImages {
                if let fig = fastCandidates.first(where: { $0.figure?.id == figId })?.figure {
                    localPairs.append((fig, image, colorConf))
                }
            }
            // Drop fetched figures from the colorOnly fallback list so we
            // don't double-count them when the visual scoring falls
            // through to the color-only injection branch below.
            let fetchedIds = Set(fetchedImages.map { $0.0 })
            colorOnly = colorOnly.filter { ($0.figure?.id).map { !fetchedIds.contains($0) } ?? true }
        } else if !missingForFetch.isEmpty {
            fetchSkippedDueToMode = true
        }

        guard !localPairs.isEmpty else {
            Self.logger.info("No local reference images available; skipping refinement")
            return RefinementOutcome(
                candidates: [],
                userReferenceCount: userReferenceCount,
                bundledReferenceCount: bundledReferenceCount,
                cachedReferenceCount: cachedReferenceCount,
                fetchedReferenceCount: fetchedReferenceCount,
                fetchSkippedDueToMode: fetchSkippedDueToMode
            )
        }

        Self.logger.info("Refining with \(localPairs.count) locally-available reference images")

        // Score off the main actor. For each reference, compute BOTH a
        // full-figure feature-print distance AND a torso-band feature-
        // print distance, then blend them. The torso-band component is
        // weighted higher (0.65) because the torso print IS the figure's
        // primary key (see docs/MINIFIGURE_ANATOMY.md). Reference
        // images on the catalog CDN are usually centered, white-
        // background renders so the band crop lines up cleanly with the
        // captured torso band.
        let pairsCopy = localPairs
        let scored: [(Minifigure, Float, Double)] = await Task.detached(priority: .userInitiated) { [self] in
            var results: [(Minifigure, Float, Double)] = []
            for (fig, img, colorConf) in pairsCopy {
                if Task.isCancelled { break }
                guard let refCG = img.cgImage else { continue }
                let refSubjectCG = self.cropToSalientSubject(refCG) ?? refCG
                guard let refFullPrint = self.generateFeaturePrint(from: refSubjectCG) else { continue }
                var fullDist: Float = 0
                do {
                    try capturedFullPrint.computeDistance(&fullDist, to: refFullPrint)
                } catch {
                    continue
                }
                // Torso-band distance, when both sides have a print.
                var torsoDist: Float? = nil
                var sigDist: Float? = nil
                if let capturedTorsoPrint = capturedTorsoPrint {
                    let refTorsoCG = self.cropVerticalBand(refSubjectCG, top: 0.30, bottom: 0.70)
                    if let refTorsoPrint = self.generateFeaturePrint(from: refTorsoCG) {
                        var d: Float = 0
                        if (try? capturedTorsoPrint.computeDistance(&d, to: refTorsoPrint)) != nil {
                            torsoDist = d
                        }
                    }
                    // Structural torso signature distance (training-free
                    // spatial-color + edge layout). Computed on the same
                    // band crop as the print so they're directly
                    // comparable. Roughly 0.0 (identical) → 1.0+
                    // (very different).
                    if let capturedSig = capturedTorsoSignature,
                       let refSig = TorsoVisualSignatureExtractor.signature(for: refTorsoCG) {
                        sigDist = capturedSig.distance(to: refSig)
                    }
                }
                // Blend three signals when all are available:
                //   • torso-band feature print (embedding similarity) — 0.50
                //   • torso visual signature (spatial layout)         — 0.25
                //   • full-figure feature print                       — 0.25
                // The torso band is the PRIMARY identity signal for
                // minifigures — weighted highest. The structural
                // signature disambiguates similar color palettes, and
                // the full-figure print catches silhouette differences.
                //
                // SCALE FIX: TorsoVisualSignature.distance() returns
                // RMSE in ~0–1 range, while VNFeaturePrint distances
                // are ~0–2+. Multiply sigDist by 1.5 to put them on
                // comparable scales before blending. Without this, the
                // signature's 0.25 weight effectively acts like ~0.13.
                let scaledSig = sigDist.map { $0 * 1.5 }
                let combined: Float
                switch (torsoDist, scaledSig) {
                case let (td?, sd?):
                    combined = 0.50 * td + 0.25 * sd + 0.25 * fullDist
                case let (td?, nil):
                    combined = 0.70 * td + 0.30 * fullDist
                case let (nil, sd?):
                    combined = 0.55 * sd + 0.45 * fullDist
                default:
                    combined = fullDist
                }
                results.append((fig, combined, colorConf))
            }
            return results
        }.value

        guard !scored.isEmpty else {
            return RefinementOutcome(
                candidates: [],
                userReferenceCount: userReferenceCount,
                bundledReferenceCount: bundledReferenceCount,
                cachedReferenceCount: cachedReferenceCount,
                fetchedReferenceCount: fetchedReferenceCount,
                fetchSkippedDueToMode: fetchSkippedDueToMode
            )
        }

        // Confidence calibration based on EMPIRICAL Vision feature-print
        // distances on minifigure photos:
        //   < 0.4 : extremely similar (near-identical pose & lighting)
        //   0.4–0.7 : strong visual match
        //   0.7–1.0 : weak / generic match
        //   > 1.0 : essentially unrelated
        //
        // Old formula stretched relative ranks to 0.40–0.92 even when
        // every candidate scored 0.9 distance — producing "92% match"
        // for figures that look nothing like the subject. Use absolute
        // distance to set a confidence ceiling, then add a small relative
        // bonus for the better-ranked entries.
        let ranked = scored.sorted { $0.1 < $1.1 }  // smaller distance = better
        let bestDistance = ranked.first?.1 ?? 1.0

        // Absolute-distance ceiling for the BEST candidate.
        // See `distanceToConfidence` for the calibrated curve.
        let bestCeiling = Self.distanceToConfidence(bestDistance)

        // Build a map of RAW DINOv2 cosine similarities normalized to
        // a 0–1 confidence scale. Unlike the old approach which used
        // the inflated Phase 1.5 composite (color + embedding boosts
        // stacked to ~0.97), this uses the ACTUAL DINOv2 cosine
        // similarities — the true embedding signal.
        //
        // Raw cosines for minifig torsos typically range 0.60–0.85.
        // Normalize: 0.60 → 0.0, 0.85+ → 1.0, linear in between.
        let embeddingConfMap: [String: Double] = {
            var m = [String: Double]()
            for (figId, cosine) in rawEmbeddingCosines {
                let normalized = Double(max(0, min(1, (cosine - 0.60) / 0.25)))
                m[figId] = normalized
            }
            return m
        }()

        // Color cascade weight: Phase 1 performed careful color analysis
        // (torso primary match, headgear, head, legs scoring). Carrying
        // this forward prevents Phase 2's noisy visual scoring from
        // burying correct color matches. Combined with zeroing colorNorm
        // for CLIP-injected candidates (no Phase 1 color evidence), this
        // creates a meaningful gap between color-verified and unverified
        // candidates. At 20%, a Phase 1 hit with colorNorm=1.0 gets a
        // 0.20 boost that CLIP-injected candidates cannot match.
        let colorCascadeWeight: Double = MinifigureScanTuning.colorCascadeWeight
        let adjustedVisualWeight: Double
        let adjustedEmbeddingWeight: Double
        if embeddingDiscrimination > MinifigureScanTuning.embeddingDiscriminationStrong {
            adjustedEmbeddingWeight = 0.48
            adjustedVisualWeight = 0.32
        } else if embeddingDiscrimination > MinifigureScanTuning.embeddingDiscriminationModerate {
            adjustedEmbeddingWeight = 0.33
            adjustedVisualWeight = 0.47
        } else {
            adjustedEmbeddingWeight = 0.13
            adjustedVisualWeight = 0.67
        }
        Self.logger.debug("[Phase2] embedding discrimination=\(String(format: "%.4f", embeddingDiscrimination)) → visual weight=\(String(format: "%.0f%%", adjustedVisualWeight * 100)), embedding weight=\(String(format: "%.0f%%", adjustedEmbeddingWeight * 100)), color cascade weight=\(String(format: "%.0f%%", colorCascadeWeight * 100))")

        // ── EMBEDDING-AWARE PRE-SORT ──
        //
        // Compute blended score for ALL scored candidates using raw
        // DINOv2 cosines (not inflated composites), sort by blended
        // score, THEN take the top-10. This lets DINOv2 pull the
        // correct figure into the final set when it has strong
        // discrimination, without polluting results when it doesn't.
        struct ScoredEntry {
            let figure: Minifigure
            let distance: Float
            let colorConfidence: Double
            let visualConf: Double
            let embConf: Double
            let blendedConf: Double
        }

        let allEntries: [ScoredEntry] = ranked.enumerated().map { (idx, item) in
            let (fig, distance, colorConf) = item
            let vConf = Self.distanceToConfidence(distance)
            let eConf = embeddingConfMap[fig.id] ?? 0.0
            let hasEmb = eConf > 0.05
            // Normalize Phase 1 color confidence to 0–1 scale.
            // Phase 1 cascade hits: 0.55–0.85, CLIP-boosted: up to 0.98,
            // joint inference: 0.20–0.62.
            // Normalize so 0.30 → 0.0, 0.85+ → 1.0.
            //
            // CRITICAL: Only apply color weight to candidates that came
            // from the Phase 1 COLOR CASCADE. CLIP/DINOv2-injected
            // candidates have synthetic confidence (0.60–0.95) based on
            // embedding cosine, NOT on color evidence. Counting that
            // synthetic confidence as "color cascade" support lets wrong-
            // color CLIP hits score the same as correctly-color-matched
            // Phase 1 candidates — e.g., a gray-torso "Mother" figure
            // injected by CLIP at 0.80 gets colorNorm=0.91, nearly
            // identical to a Red Spaceman's Phase 1 score of 0.76
            // (colorNorm=0.84). This eliminates the 15% color weight
            // as a discriminator entirely.
            let isPhase1Candidate = phase1Ids.contains(fig.id)
            let colorNorm = isPhase1Candidate
                ? max(0, min(1, (colorConf - 0.30) / 0.55))
                : 0.0
            let blended: Double
            if hasEmb {
                blended = adjustedVisualWeight * vConf + adjustedEmbeddingWeight * eConf + colorCascadeWeight * colorNorm
            } else {
                blended = (adjustedVisualWeight + adjustedEmbeddingWeight) * vConf + colorCascadeWeight * colorNorm
            }
            return ScoredEntry(
                figure: fig,
                distance: distance,
                colorConfidence: colorConf,
                visualConf: vConf,
                embConf: eConf,
                blendedConf: blended
            )
        }

        // Sort by blended confidence (embedding-aware) instead of
        // pure VNFeaturePrint distance. This is THE key change that
        // lets DINOv2 rescue dark/patterned figures.
        let sortedByBlend = allEntries.sorted { $0.blendedConf > $1.blendedConf }

        // Diagnostic: show how the pre-sort reorders vs pure visual.
        if let topByBlend = sortedByBlend.first {
            Self.logger.debug("[Phase2-PreSort] #1 by blend: \(topByBlend.figure.id) blend=\(String(format: "%.3f", topByBlend.blendedConf)) vis=\(String(format: "%.3f", topByBlend.visualConf)) emb=\(String(format: "%.3f", topByBlend.embConf)) color=\(String(format: "%.3f", topByBlend.colorConfidence)) dist=\(String(format: "%.2f", topByBlend.distance))")
        }
        if sortedByBlend.count >= 2 {
            let e = sortedByBlend[1]
            Self.logger.debug("[Phase2-PreSort] #2 by blend: \(e.figure.id) blend=\(String(format: "%.3f", e.blendedConf)) vis=\(String(format: "%.3f", e.visualConf)) emb=\(String(format: "%.3f", e.embConf)) color=\(String(format: "%.3f", e.colorConfidence)) dist=\(String(format: "%.2f", e.distance))")
        }
        // Show what pure-visual would have picked
        if let topByVis = allEntries.min(by: { $0.distance < $1.distance }), topByVis.figure.id != sortedByBlend.first?.figure.id {
            Self.logger.debug("[Phase2-PreSort] NOTE: pure-visual #1 was \(topByVis.figure.id) dist=\(String(format: "%.2f", topByVis.distance)) — embedding-aware pre-sort changed the winner")
        }

        var visualResults = sortedByBlend.prefix(20).enumerated().map { (idx, entry) -> ResolvedCandidate in
            // Apply a small rank penalty so the #1 candidate scores
            // slightly higher than #2 etc.
            let confidence = max(0.25, entry.blendedConf - Double(idx) * 0.02)

            let qualityNote: String
            switch entry.distance {
            case ..<0.4: qualityNote = "strong visual match"
            case ..<0.7: qualityNote = "good visual match"
            case ..<1.0: qualityNote = "weak visual match"
            default: qualityNote = "low-confidence visual match"
            }
            return ResolvedCandidate(
                figure: entry.figure,
                modelName: entry.figure.name,
                confidence: confidence,
                reasoning: idx == 0
                    ? "Best \(qualityNote) (distance \(String(format: "%.2f", entry.distance)))."
                    : "\(qualityNote.capitalized) (distance \(String(format: "%.2f", entry.distance)))."
            )
        }

        // If the best visual distance is poor (>0.7), the bundled
        // reference set probably doesn't contain the actual figure.
        // Inject the top color-only candidates so the user has a chance
        // of seeing the right one. Cap their confidence so they don't
        // displace strong visual matches.
        if bestDistance > 0.7 && !colorOnly.isEmpty {
            let topColorOnly = colorOnly
                .sorted { $0.confidence > $1.confidence }
                .prefix(4)
                .map { c in
                    ResolvedCandidate(
                        figure: c.figure,
                        modelName: c.modelName,
                        confidence: min(c.confidence, bestCeiling - 0.05),
                        reasoning: "Color match (no reference image to verify visually)."
                    )
                }
            visualResults.append(contentsOf: topColorOnly)
        }

        // Keep up to 16 so the results sheet can offer a "Show more"
        // toggle that reveals candidates 9–16 on demand.
        let finalCandidates = visualResults
            .sorted { $0.confidence > $1.confidence }
            .prefix(16)
            .map { $0 }

        return RefinementOutcome(
            candidates: finalCandidates,
            userReferenceCount: userReferenceCount,
            bundledReferenceCount: bundledReferenceCount,
            cachedReferenceCount: cachedReferenceCount,
            fetchedReferenceCount: fetchedReferenceCount,
            fetchSkippedDueToMode: fetchSkippedDueToMode
        )
    }

    // MARK: - On-demand reference image fetch

    /// Download up to `requests.count` reference images in parallel
    /// against an overall wall-clock budget. Each successful download is
    /// also written to `MinifigureImageCache`'s disk tier so the next
    /// scan of any of these figures finds the image locally without
    /// hitting the network.
    ///
    /// Returns `(figureId, image, colorConfidence)` for each successful
    /// fetch. Failures and timeouts are silently dropped — the caller
    /// falls back to color-only matching for those figures.
    private func fetchReferenceImages(
        _ requests: [(figure: Minifigure, url: URL, colorConfidence: Double)],
        overallTimeout: TimeInterval
    ) async -> [(String, UIImage, Double)] {
        guard !requests.isEmpty else { return [] }

        // Each per-image request has its own short timeout. URLSession's
        // shared instance is fine — these are tiny GETs against a CDN.
        let perRequestTimeout: TimeInterval = min(overallTimeout, 3.0)
        let session = URLSession.shared

        // Race the parallel downloads against an overall wall-clock
        // timeout. If the timeout fires first, we cancel any inflight
        // tasks and return whatever has completed so far.
        return await withTaskGroup(of: (String, UIImage, Double)?.self) { group in
            for req in requests {
                group.addTask {
                    var urlRequest = URLRequest(url: req.url)
                    urlRequest.cachePolicy = .returnCacheDataElseLoad
                    urlRequest.timeoutInterval = perRequestTimeout
                    do {
                        let (data, response) = try await session.data(for: urlRequest)
                        guard let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              let image = UIImage(data: data) else {
                            return nil
                        }
                        // Write through to the disk-backed cache so the
                        // next scan of this figure finds it offline.
                        await MainActor.run {
                            MinifigureImageCache.shared.store(
                                image, for: req.url, bytes: data.count
                            )
                        }
                        return (req.figure.id, image, req.colorConfidence)
                    } catch {
                        return nil
                    }
                }
            }

            // Add a sentinel timeout task. The first task to finish that
            // is the timeout sentinel will short-circuit the wait.
            group.addTask { [overallTimeout] in
                let nanos = UInt64(overallTimeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }

            var results: [(String, UIImage, Double)] = []
            let deadline = Date().addingTimeInterval(overallTimeout)
            for await result in group {
                if let result {
                    results.append(result)
                }
                if Date() >= deadline {
                    group.cancelAll()
                    break
                }
            }
            return results
        }
    }
}
