import Foundation
import UIKit
import Vision
import os.log

extension MinifigureIdentificationService {

    /// Captured-torso pattern signature, derived from the torso band
    /// crop. Distinguishes a printed torso (zipper, badge, insignia,
    /// faction emblem) from a plain solid-color torso WITHOUT requiring
    /// a trained classifier. Used by the cascade gate: a torso color
    /// match against a *common* base color (black, white, blue, red,
    /// grey…) is not enough on its own to claim the torso has been
    /// identified — there has to be either a rare base color OR
    /// detectable print to enter cascade mode.
    struct TorsoSignature {
        /// LEGO colors observed in the torso band after generic-head
        /// filtering. Patterned torsos have ≥2 entries.
        let bandColors: Set<LegoColor>
        /// Fraction of torso-band pixels that deviate substantially
        /// from the dominant cluster (i.e., "print pixels": zipper
        /// stripes, badges, insignia, faction emblems). 0.0 = perfectly
        /// solid color; >0.15 = clearly printed.
        let printPixelRatio: Double
        /// Convenience: `bandColors.count >= 2 || printPixelRatio >= 0.12`.
        let isPatterned: Bool
        /// Text fragments detected on the torso via Vision OCR.
        /// Examples: "B" (Blacktron), "M" (M-Tron), "POLICE", "FIRE".
        /// Empty when no text is detected.
        let detectedText: [String]
    }

    /// LEGO colors that show up on hundreds of distinct figure torsos
    /// across the catalog. A torso color match against one of these is
    /// NOT enough on its own to claim the figure has been identified —
    /// "the torso is black" matches Ninjago, modern Police, SWAT,
    /// Imperial officers, Batman villains, ninjas, and more. The
    /// cascade gate requires print evidence on top of these. Long-tail
    /// colors (purple, pink, lime, orange, dark red/green, light blue)
    /// are rare enough that a base-color match alone is informative.
    nonisolated static let commonTorsoColors: Set<LegoColor> = [
        .black, .white, .blue, .red, .gray, .darkGray, .darkBlue,
        .green, .brown, .tan, .yellow
    ]

    /// Extract dominant colors from an image, optionally excluding
    /// near-white/near-black pixels (background noise).
    nonisolated func extractDominantColors(
        from cgImage: CGImage,
        excludeBackground: Bool = false
    ) -> [RGB] {
        let size = 24
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
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var pixels: [RGB] = []
        pixels.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]

                if excludeBackground {
                    // Skip pixels that are likely shadows/background
                    // rather than actual LEGO colors. BUT: black IS a
                    // valid LEGO color (Blacktron, Ninja, Batman, etc.)
                    // so we only skip near-black pixels that are also
                    // completely desaturated. Dark pixels with ANY color
                    // (logo on black torso) are always kept.
                    let brightness = (Int(r) + Int(g) + Int(b)) / 3
                    let maxC = max(r, g, b)
                    let minC = min(r, g, b)
                    let saturation = Int(maxC) - Int(minC)
                    // Only skip truly black AND desaturated pixels when
                    // brightness is extremely low (< 10). The old
                    // threshold of 25 was killing LEGO black pieces.
                    if brightness < 10 && saturation < 8 { continue }
                    // Skip very low-saturation greys ONLY when they're
                    // mid-brightness — those are usually surfaces (table,
                    // paper, wall). Pure white (high brightness, low sat)
                    // is kept because it's a real LEGO color.
                    if saturation < 15 && brightness >= 60 && brightness <= 235 {
                        continue
                    }
                }

                pixels.append(RGB(r: r, g: g, b: b))
            }
        }

        guard !pixels.isEmpty else { return [] }
        return findDominantColors(pixels, count: 4)
    }

    /// Frequency-based dominant color extraction using coarse bucketing.
    nonisolated private func findDominantColors(_ pixels: [RGB], count: Int) -> [RGB] {
        var buckets: [UInt32: (count: Int, totalR: Int, totalG: Int, totalB: Int)] = [:]

        for px in pixels {
            let key = (UInt32(px.r / 32) << 16) | (UInt32(px.g / 32) << 8) | UInt32(px.b / 32)
            var entry = buckets[key, default: (0, 0, 0, 0)]
            entry.count += 1
            entry.totalR += Int(px.r)
            entry.totalG += Int(px.g)
            entry.totalB += Int(px.b)
            buckets[key] = entry
        }

        return buckets.values
            .sorted { $0.count > $1.count }
            .prefix(count)
            .map { bucket in
                RGB(
                    r: UInt8(bucket.totalR / bucket.count),
                    g: UInt8(bucket.totalG / bucket.count),
                    b: UInt8(bucket.totalB / bucket.count)
                )
            }
    }

    /// Map an RGB value to the closest non-transparent LegoColor.
    /// Thin wrapper around `LegoColor.closest(r:g:b:)` so existing call
    /// sites in this file don't have to change.
    nonisolated func closestLegoColor(r: UInt8, g: UInt8, b: UInt8) -> (color: LegoColor, distance: Double)? {
        LegoColor.closest(r: r, g: g, b: b)
    }

    // MARK: - Torso Pattern Analysis

    /// Analyze a torso-band crop for *print* — the part of the torso
    /// signal that catalog-side `LegoColor` doesn't capture. Returns the
    /// set of distinct LEGO colors found AND the fraction of pixels
    /// that deviate substantially from the dominant cluster.
    ///
    /// `printPixelRatio` is what lets us tell a printed Police torso
    /// (zipper + badge → ~20% deviating pixels) from a solid Ninjago
    /// torso (~3% deviating pixels) when both are catalogued as Black.
    /// Without this, the cascade gate would happily declare "torso
    /// confidently identified" against any common base color and
    /// collapse the candidate space onto whatever modern figure
    /// happens to share that base color.
    nonisolated func analyzeTorsoSignature(
        torsoBandImage cgImage: CGImage,
        hasGenericHead: Bool
    ) -> TorsoSignature {
        // Sample the torso band into a moderate RGB buffer. Use 48×48
        // (4× the area of the old 24×24) so small but distinctive logos
        // like Blacktron's "B" or M-Tron's "M" occupy enough pixels to
        // register in the print-pixel ratio. At 24×24 a ~10% logo only
        // covered ~30 pixels and often fell below the detection threshold.
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
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return TorsoSignature(bandColors: [], printPixelRatio: 0, isPatterned: false, detectedText: [])
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        // Build the "kept" pixel list. Skip only truly black
        // desaturated pixels (shadows), NOT LEGO black pieces.
        // Black IS a valid LEGO color (Blacktron, Ninja, Batman, etc.)
        var kept: [RGB] = []
        kept.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]
                let brightness = (Int(r) + Int(g) + Int(b)) / 3
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let saturation = Int(maxC) - Int(minC)
                // Only skip truly black AND desaturated (< 10 brightness,
                // < 8 saturation). Keeps LEGO black pieces.
                if brightness < 10 && saturation < 8 { continue }
                if saturation < 15 && brightness >= 60 && brightness <= 235 { continue }
                kept.append(RGB(r: r, g: g, b: b))
            }
        }
        guard !kept.isEmpty else {
            return TorsoSignature(bandColors: [], printPixelRatio: 0, isPatterned: false, detectedText: [])
        }

        // Distinct LEGO colors in the band (existing patterned-torso
        // signal — strong but coarse).
        let dominant = findDominantColors(kept, count: 4)
        var bandColors: Set<LegoColor> = []
        for c in dominant {
            guard let lc = closestLegoColor(r: c.r, g: c.g, b: c.b)?.color else { continue }
            if hasGenericHead && lc == .yellow { continue }
            bandColors.insert(lc)
        }

        // Print-pixel ratio: take the dominant pixel cluster (the
        // torso's base color) and count how many kept pixels fall
        // FAR from it in perceptual-RGB distance. This captures
        // zipper stripes, badges, faction insignia, dual-tone
        // printing — all the things that make a torso a primary key
        // even when the catalog only records a single base color.
        let baseRGB = dominant.first ?? kept.first!
        let baseR = Double(baseRGB.r)
        let baseG = Double(baseRGB.g)
        let baseB = Double(baseRGB.b)
        // Threshold tuned so jpeg/lighting noise (~20–40 distance)
        // doesn't register, but legible print details do (~80+).
        // Same weighted-RGB metric as `LegoColor.closest`.
        let threshold: Double = MinifigureScanTuning.printPixelDistanceThreshold
        let thresholdSq = threshold * threshold
        var printPixels = 0
        for px in kept {
            let dr = Double(px.r) - baseR
            let dg = Double(px.g) - baseG
            let db = Double(px.b) - baseB
            let distSq = 2.0 * dr * dr + 4.0 * dg * dg + 3.0 * db * db
            if distSq > thresholdSq { printPixels += 1 }
        }
        let ratio = Double(printPixels) / Double(kept.count)
        let patterned = bandColors.count >= 2 || ratio >= 0.06

        // ── OCR: detect text printed on the torso ──
        //
        // Many LEGO factions print distinctive text on the torso:
        //   "B" (Blacktron), "M" (M-Tron), "POLICE", "FIRE",
        //   "RESCUE", "COAST GUARD", letters/numbers on sports jerseys.
        // Even a single recognized character is a VERY strong signal
        // because it narrows the search space dramatically — a "B"
        // on a black torso immediately points to Blacktron.
        //
        // Use Vision's text recognizer on the original full-resolution
        // torso crop (NOT the downsampled 48×48) for better OCR quality.
        var detectedText: [String] = []
        let textHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false  // single letters/short words
        textRequest.minimumTextHeight = 0.05        // detect small text
        textRequest.recognitionLanguages = ["en-US"]
        do {
            try textHandler.perform([textRequest])
            for observation in textRequest.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && candidate.confidence > 0.3 {
                    detectedText.append(text)
                }
            }
        } catch {
            // OCR failure is non-fatal — we just won't have text signal
            Self.logger.debug("[TorsoOCR] recognition failed: \(error.localizedDescription)")
        }
        if !detectedText.isEmpty {
            Self.logger.debug("[TorsoOCR] detected text: \(detectedText.joined(separator: ", "))")
        }

        return TorsoSignature(
            bandColors: bandColors,
            printPixelRatio: ratio,
            isPatterned: patterned || !detectedText.isEmpty,
            detectedText: detectedText
        )
    }

    // MARK: - Utilities

    static func fuzzyScore(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let distance = levenshtein(a, b)
        let maxLen = max(a.count, b.count)
        return 1.0 - (Double(distance) / Double(maxLen))
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                if aChars[i-1] == bChars[j-1] {
                    dp[i][j] = dp[i-1][j-1]
                } else {
                    dp[i][j] = min(dp[i-1][j-1], dp[i-1][j], dp[i][j-1]) + 1
                }
            }
        }
        return dp[m][n]
    }
}
