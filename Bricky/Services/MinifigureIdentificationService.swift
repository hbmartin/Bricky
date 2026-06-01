import Foundation
import UIKit
import Vision
import os.log

/// Orchestrates torso → minifigure identification using multiple signals:
///
/// 1. **CoreML** (if a trained torso classifier model is bundled)
/// 2. **Vision feature-print comparison** — downloads reference images from
///    the catalog CDN for color-pre-filtered candidates, then ranks by
///    visual similarity using `VNFeaturePrintObservation`.
///
/// Color analysis is used only as a *pre-filter* to narrow 16K figures to
/// a manageable candidate set. The actual ranking is driven by visual
/// similarity of the full figure photo against catalog reference images.
@MainActor
final class MinifigureIdentificationService: ObservableObject {
    static let shared = MinifigureIdentificationService()

    nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.app.bricky",
        category: "MinifigureIdentification"
    )

    struct ResolvedCandidate: Identifiable, Hashable {
        let id = UUID()
        let figure: Minifigure?
        let modelName: String
        let confidence: Double
        let reasoning: String

        /// Whether this candidate was identified or boosted by the
        /// Brickognize cloud service.
        var isCloudAssisted: Bool {
            modelName == "cloud" || modelName == "local+cloud"
        }
    }

    /// Observable scan phase — views can observe this to show the user
    /// which pipeline step is currently running.
    enum ScanPhase: Equatable {
        case idle
        case colorCascade
        case embeddingRetrieval
        case visualRefinement
        case cloudValidation
        case done
    }

    /// Current scan phase. Updated on MainActor so SwiftUI views can
    /// observe it directly.
    @Published private(set) var scanPhase: ScanPhase = .idle

    /// After identification completes, indicates whether the Brickognize
    /// cloud service was queried. Views use this to show a post-scan
    /// cloud status indicator in the results.
    enum CloudStatus: Equatable {
        case notUsed        // cloud was enabled but confidence was high enough
        case used           // cloud was queried and results were merged
        case disabled       // user turned off cloud in settings
        case failed         // cloud was queried but request failed/timed out
    }
    @Published private(set) var lastCloudStatus: CloudStatus = .notUsed

    struct ScanProvenance: Equatable {
        let mode: ScanSettings.IdentificationMode
        var userReferenceCount: Int = 0
        var bundledReferenceCount: Int = 0
        var cachedReferenceCount: Int = 0
        var fetchedReferenceCount: Int = 0
        var usedCloudFallback: Bool = false

        var localReferenceSummary: String {
            "user=\(userReferenceCount), bundled=\(bundledReferenceCount), cached=\(cachedReferenceCount), fetched=\(fetchedReferenceCount)"
        }

        var statusMessage: String {
            switch mode {
            case .strictOffline:
                return "Strict offline mode — bundled and user-owned local references only"
            case .offlineFirst:
                if cachedReferenceCount > 0 {
                    return "Offline-first mode — local results with cached references"
                }
                return "Offline-first mode — local results only"
            case .assisted:
                if usedCloudFallback {
                    return "Results verified by Brickognize cloud service"
                }
                if fetchedReferenceCount > 0 {
                    return "Assisted mode — local results with downloaded references"
                }
                if cachedReferenceCount > 0 {
                    return "Assisted mode — local results with cached references"
                }
                return "Assisted mode — identified locally, cloud not needed"
            }
        }
    }

    @Published private(set) var lastScanProvenance = ScanProvenance(mode: .offlineFirst)

    /// Cleaned-up debug log from the most recent identification run.
    /// Views should read this after `identify()` returns to attach it
    /// to the scan history entry.
    @Published private(set) var lastScanDebugLog: String = ""

    struct RefinementOutcome {
        let candidates: [ResolvedCandidate]
        let userReferenceCount: Int
        let bundledReferenceCount: Int
        let cachedReferenceCount: Int
        let fetchedReferenceCount: Int
        let fetchSkippedDueToMode: Bool

        var totalReferenceCount: Int {
            userReferenceCount + bundledReferenceCount + cachedReferenceCount + fetchedReferenceCount
        }

        static let empty = RefinementOutcome(
            candidates: [],
            userReferenceCount: 0,
            bundledReferenceCount: 0,
            cachedReferenceCount: 0,
            fetchedReferenceCount: 0,
            fetchSkippedDueToMode: false
        )
    }

    enum IdentificationError: LocalizedError {
        case noResults
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .noResults:
                return "Couldn't identify this minifigure. Try a clearer torso photo."
            case .underlying(let err):
                return err.localizedDescription
            }
        }
    }

    private init() {}

    private nonisolated static var useLegacyScannerCore: Bool {
        UserDefaults.standard.bool(forKey: "Bricky.UseLegacyMinifigureScannerCore")
    }

    // MARK: - Public API

    /// Identify a minifigure from a captured photo.
    ///
    /// Two-phase strategy (mode-aware):
    /// 1. **Fast phase** (always runs, completes in <1s): color-based
    ///    catalog filtering returns a list of candidates immediately.
    /// 2. **Refinement phase** (best-effort, capped at 6s): re-ranks
    ///    candidates by visual similarity using reference images allowed by
    ///    the active scan mode (strict local-only, offline-first, or assisted).
    ///
    /// The function ALWAYS returns results — it never throws unless the
    /// catalog is empty or the image is unreadable.
    func identify(torsoImage: UIImage) async throws -> [ResolvedCandidate] {
        await MinifigureCatalog.shared.load()

        let scanImage = torsoImage.normalizedOrientation()
        guard let cgImage = scanImage.cgImage else {
            throw IdentificationError.noResults
        }

        Self.logger.info("Identification started")
        let identificationMode = ScanSettings.shared.identificationMode
        scanPhase = .colorCascade
        lastCloudStatus = identificationMode.allowsCloudFallback ? .notUsed : .disabled
        var provenance = ScanProvenance(mode: identificationMode)
        lastScanProvenance = provenance

        // ── Debug log accumulator ──
        let scanStart = Date()
        var logLines: [String] = []
        func logAppend(_ line: String) { logLines.append(line) }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        logLines.append("═══════════════════════════════════════")
        logLines.append("  Minifigure Scan Debug Log")
        logLines.append("  \(dateFmt.string(from: scanStart))")
        logLines.append("═══════════════════════════════════════")
        logLines.append("  Scan mode: \(identificationMode.rawValue)")

        // Snapshot the catalog on the MainActor BEFORE going to background.
        // Calling MainActor.assumeIsolated from a detached task would crash.
        let catalogSnapshot = MinifigureCatalog.shared.allFigures

        if !Self.useLegacyScannerCore {
            return try await identifyWithEvidenceCore(
                scanImage: scanImage,
                cgImage: cgImage,
                catalogSnapshot: catalogSnapshot,
                identificationMode: identificationMode,
                provenance: provenance,
                scanStart: scanStart,
                logLines: logLines
            )
        }

        // ── Phase 1: Fast color-based candidates (no network, <1s) ──
        let fastResults = await Task.detached(priority: .userInitiated) { [self, catalogSnapshot] in
            self.fastColorBasedCandidates(cgImage: cgImage, allFigures: catalogSnapshot)
        }.value

        Self.logger.info("Fast phase returned \(fastResults.count) candidates")
        logAppend("")
        logAppend("▸ Phase 1 — Color Cascade")
        logAppend("  Candidates: \(fastResults.count)")
        if !fastResults.isEmpty {
            let top5 = fastResults.prefix(5).compactMap { c -> String? in
                guard let fig = c.figure else { return nil }
                return "\(fig.id)(\(String(format: "%.2f", c.confidence)))"
            }.joined(separator: ", ")
            Self.logger.info("[Phase1] top-5: \(top5)")
            logAppend("  Top-5: \(top5)")
        }

        guard !fastResults.isEmpty else {
            scanPhase = .done
            throw IdentificationError.noResults
        }

        scanPhase = .embeddingRetrieval

        // ── Phase 1.5: Embedding Retrieval ──
        //
        // CLIP (LEGO-domain-specific) is the primary embedding signal.
        // DINOv2 (ImageNet-trained) is a fallback when CLIP isn't available.
        // CLIP produces 512-D embeddings fine-tuned on 12,966 LEGO
        // minifigure images, giving much better discrimination than
        // DINOv2's generic ImageNet features.
        let clipAvailable = ClipEmbeddingService.shared.isAvailable
        Self.logger.info("[Phase1.5] CLIP available=\(clipAvailable), TorsoEmbedding available=\(TorsoEmbeddingService.shared.isAvailable), FaceEmbedding available=\(FaceEmbeddingService.shared.isAvailable)")

        logAppend("")
        logAppend("▸ Phase 1.5 — Embedding Retrieval")
        logAppend("  CLIP: \(clipAvailable ? "available" : "unavailable") | TorsoEmbed: \(TorsoEmbeddingService.shared.isAvailable ? "available" : "unavailable") | FaceEmbed: \(FaceEmbeddingService.shared.isAvailable ? "available" : "unavailable")")

        let embeddingResult: (candidates: [ResolvedCandidate], rawCosines: [String: Float], embeddingDiscrimination: Double)
        if clipAvailable {
            embeddingResult = await mergeWithClipHits(
                cgImage: cgImage,
                fastResults: fastResults
            )
            Self.logger.info("[Phase1.5] CLIP embedding merge complete — \(embeddingResult.candidates.count) candidates (was \(fastResults.count))")
            logAppend("  Model: CLIP (LEGO-finetuned, 512-D)")
        } else {
            embeddingResult = await mergeWithEmbeddingHits(
                cgImage: cgImage,
                fastResults: fastResults
            )
            Self.logger.info("[Phase1.5] DINOv2 fallback merge complete — \(embeddingResult.candidates.count) candidates (was \(fastResults.count))")
            logAppend("  Model: DINOv2 (generic fallback, 384-D)")
        }
        let mergedFastResults = embeddingResult.candidates
        let rawEmbeddingCosines = embeddingResult.rawCosines
        let embeddingDiscrimination = embeddingResult.embeddingDiscrimination

        // Log embedding details
        let injectedCount = mergedFastResults.count - fastResults.count
        logAppend("  Injected: \(injectedCount) new candidate(s) | Total: \(mergedFastResults.count)")
        if !rawEmbeddingCosines.isEmpty {
            let topCosines = rawEmbeddingCosines.sorted { $0.value > $1.value }.prefix(5)
            let cosineStr = topCosines.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: ", ")
            logAppend("  Top-5 cosines: \(cosineStr)")
        }
        let discQuality = embeddingDiscrimination > 0.06 ? "GOOD" : embeddingDiscrimination > 0.03 ? "MODERATE" : "POOR"
        logAppend("  Discrimination (top1−top5): \(String(format: "%.4f", embeddingDiscrimination)) — \(discQuality)")

        scanPhase = .visualRefinement

        // ── Phase 2: Refinement using locally-available reference images ──
        let phase1Ids = Set(fastResults.compactMap { $0.figure?.id })
        let refinementOutcome = await withTaskGroup(of: RefinementOutcome.self) { group in
            group.addTask { [self, mergedFastResults, phase1Ids] in
                await self.refineWithLocalReferenceImages(
                    cgImage: cgImage,
                    fastCandidates: mergedFastResults,
                    rawEmbeddingCosines: rawEmbeddingCosines,
                    embeddingDiscrimination: embeddingDiscrimination,
                    phase1Ids: phase1Ids
                )
            }
            group.addTask { [mergedFastResults] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                return RefinementOutcome(
                    candidates: mergedFastResults,
                    userReferenceCount: 0,
                    bundledReferenceCount: 0,
                    cachedReferenceCount: 0,
                    fetchedReferenceCount: 0,
                    fetchSkippedDueToMode: false
                )
            }

            let first = await group.next() ?? .empty
            group.cancelAll()
            return first
        }

        provenance.userReferenceCount = refinementOutcome.userReferenceCount
        provenance.bundledReferenceCount = refinementOutcome.bundledReferenceCount
        provenance.cachedReferenceCount = refinementOutcome.cachedReferenceCount
        provenance.fetchedReferenceCount = refinementOutcome.fetchedReferenceCount

        let refined = refinementOutcome.candidates
        let baseResult = refined.isEmpty
            ? calibrateUnrefinedCandidates(
                mergedFastResults,
                refinementOutcome: refinementOutcome,
                embeddingDiscrimination: embeddingResult.embeddingDiscrimination
            )
            : refined
        logAppend("")
        logAppend("▸ Phase 2 — Visual Refinement")
        logAppend("  Reference sources: \(provenance.localReferenceSummary)")
        if refinementOutcome.fetchSkippedDueToMode {
            logAppend("  Network fetches skipped by \(identificationMode.rawValue) mode")
        }
        if !refined.isEmpty {
            let top5 = refined.prefix(5).compactMap { c -> String? in
                guard let fig = c.figure else { return nil }
                return "\(fig.id)(\(String(format: "%.2f", c.confidence)))"
            }.joined(separator: ", ")
            Self.logger.info("[Phase2] refined top-5: \(top5)")
            logAppend("  Top-5: \(top5)")
            // Log discrimination: how much confidence gap between #1 and #2
            if refined.count >= 2 {
                let gap = refined[0].confidence - refined[1].confidence
                Self.logger.info("[Phase2] #1-#2 gap: \(String(format: "%.3f", gap)) — \(gap > 0.08 ? "good discrimination" : "POOR discrimination")")
                logAppend("  #1-#2 gap: \(String(format: "%.3f", gap)) — \(gap > 0.08 ? "good discrimination" : "POOR discrimination")")
            }
        } else {
            Self.logger.info("[Phase2] no refinement (no local refs or timed out)")
            logAppend("  Skipped (no local reference images or timed out)")
            if refinementOutcome.totalReferenceCount == 0,
               embeddingResult.embeddingDiscrimination < 0.03 {
                logAppend("  Confidence cap: no reference images and poor embedding discrimination")
            }
        }

        // ── Phase 3: Cloud fallback (Brickognize API) ──
        // When local confidence is low and cloud is enabled, ask the
        // Brickognize public API for a second opinion. If it returns a
        // high-confidence match, inject or boost that figure.
        let topConfidenceForCloud = baseResult.first?.confidence ?? 0
        let willTryCloud = ScanSettings.shared.cloudFallbackEnabled && topConfidenceForCloud < MinifigureScanTuning.cloudConfidenceFloor
        logAppend("")
        logAppend("▸ Phase 3 — Cloud Validation")
        if !ScanSettings.shared.cloudFallbackEnabled {
            logAppend("  Status: blocked by \(identificationMode.rawValue) mode")
        } else if !willTryCloud {
            logAppend("  Status: skipped (local confidence \(String(format: "%.2f", topConfidenceForCloud)) ≥ 0.80)")
        } else {
            logAppend("  Status: attempting (local confidence \(String(format: "%.2f", topConfidenceForCloud)) < 0.80)")
        }
        if willTryCloud {
            scanPhase = .cloudValidation
        } else if !ScanSettings.shared.cloudFallbackEnabled {
            lastCloudStatus = .disabled
        }
        let cloudEnhanced = await cloudFallbackIfNeeded(
            torsoImage: scanImage,
            localCandidates: baseResult
        )
        provenance.usedCloudFallback = lastCloudStatus == .used

        // Log cloud outcome
        if willTryCloud {
            if cloudEnhanced.first?.figure?.id != baseResult.first?.figure?.id {
                logAppend("  Cloud changed #1 candidate")
            } else {
                logAppend("  Cloud did not change ranking")
            }
        }

        // Apply the user-correction reranker: if the current captured
        // image looks like a past scan the user manually corrected,
        // inject or boost the figure(s) they confirmed for that scan.
        // This is what makes manual catalog selections actually carry
        // forward to future scans without a model retrain.
        let final = await UserCorrectionReranker.shared.rerank(
            capturedImage: scanImage,
            currentCandidates: cloudEnhanced
        )

        // ── Build final log section ──
        logAppend("")
        logAppend("▸ Final Result")
        for (idx, c) in final.prefix(5).enumerated() {
            if let fig = c.figure {
                logAppend("  #\(idx + 1): \(fig.id) \"\(fig.name)\" conf=\(String(format: "%.2f", c.confidence))")
            }
        }
        let elapsed = Date().timeIntervalSince(scanStart)
        logAppend("")
        logAppend("  Total candidates: \(final.count)")
        logAppend("  Elapsed: \(String(format: "%.2f", elapsed))s")
        logAppend("═══════════════════════════════════════")

        lastScanProvenance = provenance
        lastScanDebugLog = logLines.joined(separator: "\n")

        if let top = final.first, let fig = top.figure {
            Self.logger.info("[Final] #1: \(fig.id) \"\(fig.name)\" conf=\(String(format: "%.2f", top.confidence))")
        }
        Self.logger.info("Identification complete: returning \(final.count) candidates")
        scanPhase = .done
        return final
    }

    private func identifyWithEvidenceCore(
        scanImage: UIImage,
        cgImage: CGImage,
        catalogSnapshot: [Minifigure],
        identificationMode: ScanSettings.IdentificationMode,
        provenance initialProvenance: ScanProvenance,
        scanStart: Date,
        logLines initialLogLines: [String]
    ) async throws -> [ResolvedCandidate] {
        var provenance = initialProvenance
        var logLines = initialLogLines
        func logAppend(_ line: String) { logLines.append(line) }

        scanPhase = .embeddingRetrieval
        let clipAvailable = ClipEmbeddingService.shared.isAvailable
        let evidence = await Task.detached(priority: .userInitiated) { [self] in
            self.extractScanColorEvidence(from: cgImage)
        }.value
        let hatEvidence = await Task.detached(priority: .userInitiated) { [self] in
            self.extractHatColorEvidence(from: cgImage)
        }.value
        let clipHits: [ClipEmbeddingIndex.Hit]
        if clipAvailable {
            let crops = clipCandidateCrops(cgImage: cgImage)
            // 240 (was 160) — wider pool gives near-twin variants
            // (e.g. Forestman fig-006868 vs. moustache reissue) a better
            // chance to surface when the catalog reference image quality
            // varies between variants.
            clipHits = await ClipEmbeddingService.shared.nearestFigures(
                for: crops,
                topK: 240
            )
        } else {
            clipHits = []
        }

        let ranked = await Task.detached(priority: .userInitiated) { [self, catalogSnapshot, evidence, clipHits, hatEvidence] in
            self.rankWithEvidenceCore(
                allFigures: catalogSnapshot,
                evidence: evidence,
                clipHits: clipHits,
                hatEvidence: hatEvidence
            )
        }.value

        let clipCosines = Dictionary(uniqueKeysWithValues: clipHits.map { ($0.figureId, $0.cosine) })
        let clipDiscrimination: Double = {
            guard clipHits.count >= 5 else { return 0 }
            return Double(clipHits[0].cosine - clipHits[4].cosine)
        }()

        guard !ranked.isEmpty else {
            scanPhase = .done
            throw IdentificationError.noResults
        }

        logAppend("")
        logAppend("▸ Scanner Core — Embedding + Color Evidence")
        logAppend("  Legacy cascade: bypassed")
        logAppend("  CLIP: \(clipAvailable ? "available" : "unavailable")")
        logAppend("  Captured colors: \(evidence.debugSummary)")
        if let hat = hatEvidence {
            logAppend("  Captured hat: \(hat.color.rawValue) (cov \(String(format: "%.2f", hat.coverage)), chromatic=\(hat.isChromatic))")
        } else {
            logAppend("  Captured hat: none / insufficient")
        }
        if !clipHits.isEmpty {
            let topCosines = clipHits.prefix(5).map {
                "\($0.figureId)=\(String(format: "%.3f", $0.cosine))"
            }.joined(separator: ", ")
            logAppend("  Top-5 cosines: \(topCosines)")
        }
        let top5 = ranked.prefix(5).compactMap { c -> String? in
            guard let fig = c.figure else { return nil }
            return "\(fig.id)(\(String(format: "%.2f", c.confidence)))"
        }.joined(separator: ", ")
        logAppend("  Top-5: \(top5)")

        scanPhase = .visualRefinement
        logAppend("")
        logAppend("▸ Phase 2 — Visual Refinement")
        let refinementOutcome = await refineWithLocalReferenceImages(
            cgImage: cgImage,
            fastCandidates: ranked,
            rawEmbeddingCosines: clipCosines,
            embeddingDiscrimination: clipDiscrimination
        )
        provenance.userReferenceCount = refinementOutcome.userReferenceCount
        provenance.bundledReferenceCount = refinementOutcome.bundledReferenceCount
        provenance.cachedReferenceCount = refinementOutcome.cachedReferenceCount
        provenance.fetchedReferenceCount = refinementOutcome.fetchedReferenceCount
        logAppend("  Reference sources: \(provenance.localReferenceSummary)")

        let refined: [ResolvedCandidate]
        if refinementOutcome.candidates.isEmpty {
            refined = ranked
            logAppend("  Status: skipped (no local reference images or visual comparison failed)")
            if refinementOutcome.fetchSkippedDueToMode {
                logAppend("  Note: additional reference fetches blocked by \(identificationMode.rawValue) mode")
            }
        } else {
            refined = refinementOutcome.candidates
            logAppend("  Status: applied to \(refinementOutcome.totalReferenceCount) reference image(s)")
            if let top = refined.first, let fig = top.figure {
                let visualConfidence = String(format: "%.2f", top.confidence)
                logAppend("  Visual #1: \(fig.id) conf=\(visualConfidence)")
            }
        }

        let topConfidenceForCloud = refined.first?.confidence ?? 0
        let willTryCloud = ScanSettings.shared.cloudFallbackEnabled && topConfidenceForCloud < 0.72
        logAppend("")
        logAppend("▸ Phase 3 — Cloud Validation")
        if !ScanSettings.shared.cloudFallbackEnabled {
            lastCloudStatus = .disabled
            logAppend("  Status: blocked by \(identificationMode.rawValue) mode")
        } else if !willTryCloud {
            lastCloudStatus = .notUsed
            logAppend("  Status: skipped (local confidence \(String(format: "%.2f", topConfidenceForCloud)) ≥ 0.72)")
        } else {
            scanPhase = .cloudValidation
            logAppend("  Status: attempting (local confidence \(String(format: "%.2f", topConfidenceForCloud)) < 0.72)")
        }

        let cloudEnhanced = await cloudFallbackIfNeeded(
            torsoImage: scanImage,
            localCandidates: refined
        )
        provenance.usedCloudFallback = lastCloudStatus == .used
        if willTryCloud {
            if cloudEnhanced.first?.figure?.id != refined.first?.figure?.id {
                logAppend("  Cloud changed #1 candidate")
            } else {
                logAppend("  Cloud did not change ranking")
            }
        }

        let final = await UserCorrectionReranker.shared.rerank(
            capturedImage: scanImage,
            currentCandidates: cloudEnhanced
        )

        logAppend("")
        logAppend("▸ Final Result")
        for (idx, c) in final.prefix(5).enumerated() {
            if let fig = c.figure {
                logAppend("  #\(idx + 1): \(fig.id) \"\(fig.name)\" conf=\(String(format: "%.2f", c.confidence))")
            }
        }
        let elapsed = Date().timeIntervalSince(scanStart)
        logAppend("")
        logAppend("  Total candidates: \(final.count)")
        logAppend("  Elapsed: \(String(format: "%.2f", elapsed))s")
        logAppend("═══════════════════════════════════════")

        lastScanProvenance = provenance
        lastScanDebugLog = logLines.joined(separator: "\n")
        if let top = final.first, let fig = top.figure {
            Self.logger.info("[Final/Core] #1: \(fig.id) \"\(fig.name)\" conf=\(String(format: "%.2f", top.confidence))")
        }
        scanPhase = .done
        return final
    }


    // MARK: - Phase 3: Cloud Fallback (Brickognize)

    /// If local confidence is low and cloud fallback is enabled, query the
    /// Brickognize API for a second opinion. The cloud result is merged into
    /// the local candidate list: if Brickognize identifies a figure that's
    /// already in our local results, boost it; if it's a new figure, inject
    /// it at the appropriate rank.
    ///
    /// Cloud is skipped when:
    /// - The user has disabled cloud fallback in settings
    /// - The top local candidate already has high confidence (≥0.80)
    /// - The cloud request fails or times out (3s cap)
    private func cloudFallbackIfNeeded(
        torsoImage: UIImage,
        localCandidates: [ResolvedCandidate]
    ) async -> [ResolvedCandidate] {
        // Check setting
        let cloudEnabled = ScanSettings.shared.cloudFallbackEnabled
        guard cloudEnabled else {
            Self.logger.info("[Phase3] Cloud fallback blocked by \(ScanSettings.shared.identificationMode.rawValue) mode")
            lastCloudStatus = .disabled
            return localCandidates
        }

        // Skip if local confidence is already high
        let topConfidence = localCandidates.first?.confidence ?? 0
        guard topConfidence < MinifigureScanTuning.cloudConfidenceFloor else {
            Self.logger.info("[Phase3] Local confidence \(String(format: "%.2f", topConfidence)) ≥ 0.80, skipping cloud")
            lastCloudStatus = .notUsed
            return localCandidates
        }

        Self.logger.info("[Phase3] Local confidence \(String(format: "%.2f", topConfidence)) < 0.80, trying cloud fallback")

        // Fire cloud request with 3s timeout
        let cloudTask = Task<[BrickognizeService.MatchedResult], Never> {
            do {
                return try await BrickognizeService.shared.identify(image: torsoImage, maxResults: 3)
            } catch {
                Self.logger.warning("[Phase3] Cloud request failed: \(error.localizedDescription)")
                return []
            }
        }

        let timeoutTask = Task<[BrickognizeService.MatchedResult], Never> {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            cloudTask.cancel()
            return []
        }

        let cloudResults = await cloudTask.value
        timeoutTask.cancel()

        guard !cloudResults.isEmpty else {
            Self.logger.info("[Phase3] No cloud results, keeping local candidates")
            lastCloudStatus = .failed
            return localCandidates
        }

        lastCloudStatus = .used

        // Merge cloud results into local candidates with cross-validation.
        // Cloud results that CONFIRM a local candidate get a strong boost.
        // Merge cloud results with local candidates.
        //
        // KEY INSIGHT: Brickognize is a purpose-built LEGO recognition
        // service trained specifically on minifigures. When it returns a
        // HIGH-confidence result (score > 0.80), that signal is almost
        // certainly more reliable than our local pipeline (which uses
        // general-purpose DINOv2 + VNFeaturePrint models NOT trained on
        // LEGO). The old code penalized cloud-only results to max 0.50 —
        // this meant the cloud's correct answer was consistently buried
        // beneath wrong local candidates.
        //
        // New logic:
        //   - Cloud score ≥ 0.80: TRUST IT. Inject at the cloud's own
        //     score (scaled to 0.85–0.95 range). This beats weak local
        //     candidates that scored 0.6–0.75 through random color overlap.
        //   - Cloud score 0.60–0.80: moderate confidence. Inject at a
        //     scaled-down score but still competitive with local results.
        //   - Cloud confirms a local candidate: boost as before.
        //
        // Additionally, when the cloud returns a high-confidence result
        // that the local pipeline missed entirely, that's a strong signal
        // the local pipeline failed — penalize local candidates that
        // DON'T match the cloud, not the other way around.
        var merged = localCandidates
        var highConfCloudInjected = false

        for cloudMatch in cloudResults {
            guard let cloudFigure = cloudMatch.matchedFigure else { continue }
            let cloudScore = cloudMatch.prediction.score

            // Check if this figure is already in local results
            if let existingIdx = merged.firstIndex(where: { $0.figure?.id == cloudFigure.id }) {
                // Cloud confirms local candidate — strong boost.
                let existing = merged[existingIdx]
                let boost = cloudScore * 0.35
                let boostedConfidence = min(0.98, existing.confidence + boost)
                let boosted = ResolvedCandidate(
                    figure: existing.figure,
                    modelName: "local+cloud",
                    confidence: boostedConfidence,
                    reasoning: "\(existing.reasoning) | Cloud confirmed (score=\(String(format: "%.2f", cloudScore)))"
                )
                merged[existingIdx] = boosted
                if cloudScore >= 0.80 { highConfCloudInjected = true }
                Self.logger.info("[Phase3] Boosted \(cloudFigure.id) from \(String(format: "%.2f", existing.confidence)) → \(String(format: "%.2f", boostedConfidence))")

            } else if cloudScore >= 0.80 {
                // HIGH-CONFIDENCE cloud-only: Brickognize is very sure about
                // a figure our local pipeline didn't even consider. Trust it.
                // Scale 0.80→0.85, 0.90→0.90, 1.0→0.95.
                let injectedConfidence = 0.85 + (cloudScore - 0.80) * 0.50
                let injected = ResolvedCandidate(
                    figure: cloudFigure,
                    modelName: "cloud",
                    confidence: injectedConfidence,
                    reasoning: "Brickognize: \"\(cloudMatch.prediction.name)\" (score=\(String(format: "%.2f", cloudScore))) — high-confidence cloud identification"
                )
                merged.append(injected)
                highConfCloudInjected = true
                Self.logger.info("[Phase3] HIGH-CONF cloud inject \(cloudFigure.id) \"\(cloudFigure.name)\" conf=\(String(format: "%.2f", injectedConfidence)) (cloud score=\(String(format: "%.2f", cloudScore)))")

            } else if cloudScore > 0.60 {
                // MODERATE cloud-only: inject at a competitive but not
                // dominant confidence. Scale 0.60→0.55, 0.79→0.70.
                let injectedConfidence = 0.55 + (cloudScore - 0.60) * 0.75
                let injected = ResolvedCandidate(
                    figure: cloudFigure,
                    modelName: "cloud",
                    confidence: injectedConfidence,
                    reasoning: "Brickognize: \"\(cloudMatch.prediction.name)\" (score=\(String(format: "%.2f", cloudScore)))"
                )
                merged.append(injected)
                Self.logger.info("[Phase3] Moderate cloud inject \(cloudFigure.id) conf=\(String(format: "%.2f", injectedConfidence))")

            } else {
                Self.logger.info("[Phase3] Rejected cloud result \(cloudFigure.id) — score=\(String(format: "%.2f", cloudScore)) too low")
            }
        }

        // When a high-confidence cloud result was injected for a figure
        // the local pipeline MISSED, that's evidence the local pipeline
        // failed. Penalize local-only candidates (those NOT confirmed by
        // the cloud) so the cloud result can surface to #1.
        if highConfCloudInjected {
            for i in merged.indices {
                guard merged[i].modelName != "cloud" && merged[i].modelName != "local+cloud" else { continue }
                let demoted = merged[i].confidence * 0.75
                merged[i] = ResolvedCandidate(
                    figure: merged[i].figure,
                    modelName: merged[i].modelName,
                    confidence: demoted,
                    reasoning: merged[i].reasoning + " (demoted: cloud identified different figure with high confidence)"
                )
            }
        }

        // Re-sort by confidence
        merged.sort { $0.confidence > $1.confidence }

        if let top = merged.first, let fig = top.figure {
            Self.logger.info("[Phase3] Post-cloud top: \(fig.id) conf=\(String(format: "%.2f", top.confidence))")
        }

        return merged
    }

    // MARK: - Phase 2: Local Reference Image Refinement

    /// Merge color-cascade results (`fastResults`) with hits from the
    // MARK: - Phase 1.5: CLIP Embedding Retrieval (Primary)

    /// Merge color-cascade candidates with LEGO-specific CLIP embedding
    /// hits. CLIP produces embeddings fine-tuned on LEGO minifigures,
    /// giving much better discrimination than DINOv2's generic features.
    ///
    /// Returns merged candidates, raw cosine map, and discrimination score.
    private func mergeWithClipHits(
        cgImage: CGImage,
        fastResults: [ResolvedCandidate]
    ) async -> (candidates: [ResolvedCandidate], rawCosines: [String: Float], embeddingDiscrimination: Double) {
        let clipService = ClipEmbeddingService.shared
        guard clipService.isAvailable else {
            return (fastResults, [:], 0.0)
        }

        // Live camera photos are much less controlled than catalog renders:
        // saliency can choose the full figure, a torso crop, or too much desk.
        // Embed a few cheap crop variants and merge by best cosine so strict
        // offline scans still get a broad candidate pool from fresh photos.
        let clipInputs = await Task.detached(priority: .userInitiated) { [self] in
            self.clipCandidateCrops(cgImage: cgImage)
        }.value
        let subject = clipInputs.first ?? cgImage

        // Kick off CLIP and Face inference in PARALLEL. The face crop
        // is independent of CLIP results — it only boosts existing
        // candidates afterward. Running them concurrently saves the
        // face encoder's ~30-80ms latency.
        let faceService = FaceEmbeddingService.shared
        let faceAvailable = faceService.isAvailable

        async let clipHitsTask = clipService.nearestFigures(for: clipInputs, topK: 36)
        async let faceResultTask: [FaceEmbeddingIndex.Hit] = {
            guard faceAvailable else { return [] }
            let faceCG = await Task.detached(priority: .userInitiated) { [self] in
                // Reuse the already-computed subject crop instead of
                // calling cropToSalientSubject a second time.
                self.cropVerticalBand(subject, top: 0.17, bottom: 0.35)
            }.value
            return await faceService.nearestFigures(for: faceCG, topK: 12)
        }()

        let hits = await clipHitsTask
        guard !hits.isEmpty else {
            return (fastResults, [:], 0.0)
        }

        if let top = hits.first {
            Self.logger.debug("[CLIPEmbed] top-1 cosine=\(top.cosine) id=\(top.figureId)")
        }
        if hits.count >= 5 {
            let top5 = hits.prefix(5).map { String(format: "%.3f", $0.cosine) }.joined(separator: ", ")
            Self.logger.debug("[CLIPEmbed] top-5 cosines: \(top5)")
        }

        // CLIP injection threshold — lower than DINOv2 because CLIP's
        // domain-specific training produces more spread in cosine scores.
        let injectionThreshold: Float = 0.30
        let usefulHits = hits.filter { $0.cosine >= injectionThreshold }
        Self.logger.debug("[CLIPEmbed] \(usefulHits.count)/\(hits.count) hits pass threshold \(injectionThreshold)")

        var rawCosineMap: [String: Float] = [:]
        for hit in usefulHits {
            rawCosineMap[hit.figureId] = max(rawCosineMap[hit.figureId] ?? 0, hit.cosine)
        }

        // Compute discrimination: spread between #1 and #5.
        var embeddingDiscrimination: Double = 0.0
        if hits.count >= 5 {
            let top1 = Double(hits[0].cosine)
            let top5val = Double(hits[4].cosine)
            embeddingDiscrimination = top1 - top5val
            Self.logger.debug("[CLIPEmbed] discrimination (top1-top5): \(String(format: "%.4f", embeddingDiscrimination)) — \(embeddingDiscrimination > 0.06 ? "GOOD" : embeddingDiscrimination > 0.03 ? "MODERATE" : "POOR")")
        }

        let existingIds: Set<String> = Set(fastResults.compactMap { $0.figure?.id })
        var merged = fastResults

        // Boost existing color-cascade candidates that CLIP also returns.
        // Agreement between color cascade and CLIP is a very strong signal.
        let clipHitMap = Dictionary(usefulHits.map { ($0.figureId, $0.cosine) }, uniquingKeysWith: max)
        for i in merged.indices {
            guard let figId = merged[i].figure?.id,
                  let cosine = clipHitMap[figId],
                  !merged[i].reasoning.contains("CLIP") else { continue }
            // CLIP boost is stronger than DINOv2 because it's domain-specific.
            let boost = Double(cosine) * 0.30
            let boosted = min(merged[i].confidence + boost, 0.98)
            merged[i] = ResolvedCandidate(
                figure: merged[i].figure,
                modelName: merged[i].modelName,
                confidence: boosted,
                reasoning: merged[i].reasoning + " CLIP agreement (cosine \(String(format: "%.2f", cosine)))."
            )
        }

        // Inject new candidates from CLIP that aren't in the color cascade.
        for hit in usefulHits where !existingIds.contains(hit.figureId) {
            guard let figure = MinifigureCatalog.shared.figure(id: hit.figureId) else { continue }
            let normalized = Double((hit.cosine - injectionThreshold) / (1.0 - injectionThreshold))
            let confidence = 0.60 + max(0.0, min(1.0, normalized)) * 0.35
            merged.append(ResolvedCandidate(
                figure: figure,
                modelName: figure.name,
                confidence: confidence,
                reasoning: "LEGO CLIP match (cosine \(String(format: "%.2f", hit.cosine)))."
            ))
        }

        // Apply face embedding boosts from the parallel inference.
        let faceHitsResult = await faceResultTask
        if faceAvailable && !faceHitsResult.isEmpty {
            let faceThreshold: Float = 0.40
            let usefulFaceHits = faceHitsResult.filter { $0.cosine >= faceThreshold }
            let faceHitIds = Set(usefulFaceHits.map(\.figureId))

            for i in merged.indices {
                guard let figId = merged[i].figure?.id,
                      faceHitIds.contains(figId),
                      !merged[i].reasoning.contains("face-embedding") else { continue }
                let boosted = min(merged[i].confidence + 0.15, 0.98)
                merged[i] = ResolvedCandidate(
                    figure: merged[i].figure,
                    modelName: merged[i].modelName,
                    confidence: boosted,
                    reasoning: merged[i].reasoning + " Boosted by face-embedding agreement."
                )
            }
        }

        Self.logger.info(
            "CLIP embedding retrieval injected \(merged.count - fastResults.count) candidate(s)"
        )
        merged.sort { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return (lhs.figure?.year ?? 0) > (rhs.figure?.year ?? 0)
        }
        return (merged, rawCosineMap, embeddingDiscrimination)
    }

    /// Candidate crops for CLIP retrieval from fresh camera photos.
    ///
    /// The shipped index is built from clean catalog-like figure renders, but
    /// live scans can include background, skew, and either torso-only or full-
    /// figure framing. Querying several deterministic crops and taking each
    /// figure's best cosine improves offline recall without any network call.
    /// Crops used as input to CLIP retrieval. Exposed (internal) so the
    /// ground-truth harness can run the same retrieval that production
    /// runs and report production-faithful CLIP rankings.
    nonisolated func clipCandidateCrops(cgImage: CGImage) -> [CGImage] {
        let best = bestSubjectCrop(cgImage: cgImage)
        var crops: [CGImage] = [best]

        if let center = cropCenter(cgImage: cgImage, widthRatio: 0.72, heightRatio: 0.92) {
            crops.append(center)
        }

        var seen = Set<String>()
        return crops.filter { crop in
            let key = "\(crop.width)x\(crop.height)"
            return seen.insert(key).inserted
        }
    }

    nonisolated private func cropCenter(
        cgImage: CGImage,
        widthRatio: CGFloat,
        heightRatio: CGFloat
    ) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let cropW = max(20, min(w, w * widthRatio))
        let cropH = max(20, min(h, h * heightRatio))
        let cropRect = CGRect(
            x: (w - cropW) / 2,
            y: (h - cropH) / 2,
            width: cropW,
            height: cropH
        ).integral
        guard cropRect.width > 10 && cropRect.height > 10 else { return nil }
        return cgImage.cropping(to: cropRect)
    }

    // MARK: - Phase 1.5: DINOv2 Embedding Retrieval (Fallback)

    private func calibrateUnrefinedCandidates(
        _ candidates: [ResolvedCandidate],
        refinementOutcome: RefinementOutcome,
        embeddingDiscrimination: Double
    ) -> [ResolvedCandidate] {
        guard refinementOutcome.totalReferenceCount == 0,
              embeddingDiscrimination < 0.03
        else { return candidates }

        return candidates.map { candidate in
            let isEmbeddingSupported = candidate.reasoning.contains("CLIP")
                || candidate.reasoning.contains("embedding")
            let isClassicSpaceSupported = candidate.figure.map { classicSpaceSuitColor(for: $0) != nil } ?? false
            guard !isEmbeddingSupported, !isClassicSpaceSupported else { return candidate }
            let cappedConfidence = min(candidate.confidence, 0.58)
            guard cappedConfidence < candidate.confidence else { return candidate }
            return ResolvedCandidate(
                figure: candidate.figure,
                modelName: candidate.modelName,
                confidence: cappedConfidence,
                reasoning: candidate.reasoning + " Confidence capped: no local references and poor embedding discrimination."
            )
        }.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return (lhs.figure?.year ?? 0) > (rhs.figure?.year ?? 0)
        }
    }

    nonisolated func classicSpaceSuitColor(for figure: Minifigure) -> LegoColor? {
        let name = figure.name.lowercased()
        guard name.contains("classic spaceman")
            || name.contains("classic spacewoman")
            || name.contains("classic space figure")
            || name.contains("classic space, white")
        else { return nil }
        guard let torsoPart = figure.torsoPart else { return nil }
        let torsoName = torsoPart.displayName.lowercased()
        guard torsoName.contains("classic space logo") else { return nil }
        return LegoColor(fromString: torsoPart.color)
    }

    nonisolated func isRedWhiteClassicSpaceVariant(_ figure: Minifigure) -> Bool {
        guard let suitColor = classicSpaceSuitColor(for: figure), suitColor == .red else {
            return false
        }
        let name = figure.name.lowercased()
        if name.contains("white") { return true }
        return figure.parts.contains { part in
            guard [.torso, .legLeft, .legRight, .hips].contains(part.slot) else {
                return false
            }
            return LegoColor(fromString: part.color) == .white
        }
    }

    /// Merge color-cascade candidates with DINOv2 embedding hits.
    /// Used as a fallback when CLIP embeddings are not available.
    ///
    /// The merge intentionally keeps the color-cascade order and only
    /// *adds* embedding hits — it never reorders existing candidates.
    /// Phase 2's structural reranker is the place where final ranking
    /// happens; this method's only job is to ensure the right figure
    /// is *in* the pool of candidates Phase 2 sees.
    ///
    /// No-op (returns `fastResults` unchanged) when the embedding
    /// service hasn't been trained / bundled yet.
    /// Merge color-cascade candidates with DINOv2 embedding hits.
    /// Returns merged candidates AND a map of raw DINOv2 cosine
    /// similarities per figure ID, so Phase 2 can use the actual
    /// embedding signal rather than the inflated composite confidence.
    private func mergeWithEmbeddingHits(
        cgImage: CGImage,
        fastResults: [ResolvedCandidate]
    ) async -> (candidates: [ResolvedCandidate], rawCosines: [String: Float], embeddingDiscrimination: Double) {
        let torsoService = TorsoEmbeddingService.shared
        let faceService = FaceEmbeddingService.shared
        guard torsoService.isAvailable || faceService.isAvailable else {
            return (fastResults, [:], 0.0)
        }

        // Crop regions in parallel.
        let (torsoCG, faceCG): (CGImage, CGImage?) = await Task.detached(priority: .userInitiated) { [self] in
            let subject = self.cropToSalientSubject(cgImage) ?? cgImage
            let torso = self.cropVerticalBand(subject, top: 0.30, bottom: 0.70)
            let face: CGImage? = faceService.isAvailable
                ? self.cropVerticalBand(subject, top: 0.17, bottom: 0.35)
                : nil
            return (torso, face)
        }.value

        let existingIds: Set<String> = Set(fastResults.compactMap { $0.figure?.id })
        var merged = fastResults
        let injectionThreshold: Float = 0.25

        // Track raw DINOv2 cosines per figure ID — these are the
        // ACTUAL embedding signal, not the inflated composites that
        // result from stacking color + embedding + face boosts.
        var rawCosineMap: [String: Float] = [:]
        var embeddingDiscrimination: Double = 0.0

        // Torso embedding hits.
        if torsoService.isAvailable {
            let hits = await torsoService.nearestFigures(for: torsoCG, topK: 40)
            if let top = hits.first {
                Self.logger.debug("[TorsoEmbed] top-1 cosine=\(top.cosine) id=\(top.figureId)  |  threshold=\(injectionThreshold)")
            }
            if hits.count >= 5 {
                let top5 = hits.prefix(5).map { String(format: "%.3f", $0.cosine) }.joined(separator: ", ")
                Self.logger.debug("[TorsoEmbed] top-5 cosines: \(top5)")
            }
            let usefulHits = hits.filter { $0.cosine >= injectionThreshold }
            Self.logger.debug("[TorsoEmbed] \(usefulHits.count)/\(hits.count) hits pass threshold \(injectionThreshold)")

            // Store raw cosines for every hit.
            for hit in usefulHits {
                rawCosineMap[hit.figureId] = max(rawCosineMap[hit.figureId] ?? 0, hit.cosine)
            }

            // Compute embedding discrimination: spread between #1 and #5.
            // High spread (>0.05) = DINOv2 can tell figures apart.
            // Low spread (<0.03) = DINOv2 is guessing, all look similar.
            if hits.count >= 5 {
                let top1 = Double(hits[0].cosine)
                let top5val = Double(hits[4].cosine)
                embeddingDiscrimination = top1 - top5val
                Self.logger.debug("[TorsoEmbed] discrimination (top1-top5): \(String(format: "%.4f", embeddingDiscrimination)) — \(embeddingDiscrimination > 0.04 ? "GOOD" : embeddingDiscrimination > 0.02 ? "MODERATE" : "POOR")")
            }

            // Boost existing color-cascade candidates that also appear
            // in the torso embedding results — agreement between color
            // cascade and embedding retrieval is a strong signal.
            let torsoHitMap = Dictionary(usefulHits.map { ($0.figureId, $0.cosine) }, uniquingKeysWith: max)
            for i in merged.indices {
                guard let figId = merged[i].figure?.id,
                      let cosine = torsoHitMap[figId],
                      !merged[i].reasoning.contains("torso-embedding") else { continue }
                let boost = Double(cosine) * 0.25
                let boosted = min(merged[i].confidence + boost, 0.98)
                merged[i] = ResolvedCandidate(
                    figure: merged[i].figure,
                    modelName: merged[i].modelName,
                    confidence: boosted,
                    reasoning: merged[i].reasoning + " Torso-embedding agreement (cosine \(String(format: "%.2f", cosine)))."
                )
            }

            for hit in usefulHits where !existingIds.contains(hit.figureId) {
                guard let figure = MinifigureCatalog.shared.figure(id: hit.figureId) else { continue }
                let normalized = Double((hit.cosine - injectionThreshold) / (1.0 - injectionThreshold))
                let confidence = 0.55 + max(0.0, min(1.0, normalized)) * 0.40
                merged.append(ResolvedCandidate(
                    figure: figure,
                    modelName: figure.name,
                    confidence: confidence,
                    reasoning: "Trained torso-embedding match (cosine \(String(format: "%.2f", hit.cosine)))."
                ))
            }
        }

        // Face embedding hits — boost candidates with matching faces
        // or inject new candidates the torso pass missed (e.g. when
        // scanning a distinctive face like a unique licensed character).
        // Face hits get a lower weight than torso because many faces are
        // generic; the threshold is slightly higher to reduce noise.
        let faceInjectionThreshold: Float = 0.40
        if faceService.isAvailable, let faceCG {
            let hits = await faceService.nearestFigures(for: faceCG, topK: 12)
            if let top = hits.first {
                Self.logger.debug("[FaceEmbed] top-1 cosine=\(top.cosine) id=\(top.figureId)  |  threshold=\(faceInjectionThreshold)")
            }
            let usefulHits = hits.filter { $0.cosine >= faceInjectionThreshold }
            Self.logger.debug("[FaceEmbed] \(usefulHits.count)/\(hits.count) hits pass threshold \(faceInjectionThreshold)")
            let mergedIds = Set(merged.compactMap { $0.figure?.id })
            for hit in usefulHits where !mergedIds.contains(hit.figureId) {
                guard let figure = MinifigureCatalog.shared.figure(id: hit.figureId) else { continue }
                let normalized = Double((hit.cosine - faceInjectionThreshold) / (1.0 - faceInjectionThreshold))
                let confidence = 0.35 + max(0.0, min(1.0, normalized)) * 0.35
                merged.append(ResolvedCandidate(
                    figure: figure,
                    modelName: figure.name,
                    confidence: confidence,
                    reasoning: "Trained face-embedding match (cosine \(String(format: "%.2f", hit.cosine)))."
                ))
            }
            // Boost existing candidates that also appear in face hits.
            // A figure matching both torso AND face is much more likely
            // to be correct.
            let faceHitIds = Set(usefulHits.map(\.figureId))
            for i in merged.indices {
                guard let figId = merged[i].figure?.id,
                      faceHitIds.contains(figId),
                      !merged[i].reasoning.contains("face-embedding") else { continue }
                let boosted = min(merged[i].confidence + 0.18, 0.98)
                merged[i] = ResolvedCandidate(
                    figure: merged[i].figure,
                    modelName: merged[i].modelName,
                    confidence: boosted,
                    reasoning: merged[i].reasoning + " Boosted by face-embedding agreement."
                )
            }
        }

        Self.logger.info(
            "Embedding retrieval injected \(merged.count - fastResults.count) candidate(s)"
        )
        return (merged, rawCosineMap, embeddingDiscrimination)
    }

    // MARK: - Pre-scan Probe

    /// Lightweight probe to determine if an image likely contains a single
    /// minifigure vs. a pile of bricks. Uses only on-device Vision analysis
    /// (saliency + aspect ratio) — no network downloads required.
    ///
    /// This is designed to be fast (<2 seconds) for the pre-scan type
    /// detection screen. Actual identification is deferred to `identify()`.
    func probeForMinifigure(image: UIImage) async -> (isMinifigure: Bool, candidates: [ResolvedCandidate]) {
        guard let cgImage = image.cgImage else {
            return (false, [])
        }

        let result = await Task.detached(priority: .userInitiated) {
            self.classifyImageContent(cgImage)
        }.value

        Self.logger.info("Minifigure probe: isMinifigure=\(result)")
        return (result, [])
    }
}
