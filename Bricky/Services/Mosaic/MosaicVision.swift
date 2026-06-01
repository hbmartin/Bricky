import Foundation
import UIKit

/// Vision pipeline: input image → stud-aligned LEGO color grid.
/// On-device port of the backend `app/vision.py`.
///
/// Steps: normalize orientation & bound size → cover-fit crop to the grid
/// aspect → linear-light area average per cell → perceptual quantization to the
/// palette. Deterministic given the same image + configuration.
///
/// PARITY NOTE: the backend resamples with PIL LANCZOS; on-device we use Core
/// Graphics' high-quality resampler. The resampling kernel differs, so cell
/// colors near boundaries can vary by a quantization step versus the Python
/// reference. The *deterministic* downstream transforms (packing, LDraw, parts)
/// are byte-identical and are locked by the backend golden fixtures. All
/// color-averaging here is done in **linear light**, exactly as the backend
/// does, so flat regions quantize identically.
enum MosaicVision {

    private static let maxSourceDim = 1024
    private static let maxSamplesPerCell = 8
    private static let lowDetailFraction = 0.95

    /// Run the full vision pipeline and return the quantized color grid.
    static func buildGrid(
        image: UIImage,
        width: Int,
        height: Int,
        palette: MosaicPalette,
        backgroundRemoval: Bool = false
    ) -> MosaicColorGrid {
        let normalized = preprocess(image)
        let cellSrgb = cellColorsSrgb(normalized, gridW: width, gridH: height)

        var cells: [[String?]] = []
        cells.reserveCapacity(height)
        for row in cellSrgb {
            cells.append(row.map { palette.nearestName(r: $0.r, g: $0.g, b: $0.b) })
        }

        var warnings: [String] = []
        if backgroundRemoval {
            warnings.append("background_removal_unavailable")
        }
        if dominantFraction(cells) >= lowDetailFraction {
            warnings.append("low_detail")
        }

        return MosaicColorGrid(
            width: width,
            height: height,
            paletteId: palette.paletteId,
            cells: cells,
            warnings: warnings
        )
    }

    // MARK: - Stages

    /// Normalize orientation (bake in EXIF), convert to a known format, and
    /// bound the longest dimension to `maxSourceDim`.
    private static func preprocess(_ image: UIImage) -> CGImage {
        // Render through UIGraphics to bake in orientation (.up).
        let oriented = bakeOrientation(image)
        guard let cg = oriented else {
            // Fall back to whatever CGImage we have; mosaic of a 1x1 is still
            // honest (it just produces a flat grid) rather than crashing.
            return image.cgImage ?? blankPixel()
        }

        let w = cg.width
        let h = cg.height
        let longest = max(w, h)
        guard longest > maxSourceDim else { return cg }

        let scale = Double(maxSourceDim) / Double(longest)
        let newW = max(1, Int((Double(w) * scale).rounded()))
        let newH = max(1, Int((Double(h) * scale).rounded()))
        return resample(cg, toWidth: newW, height: newH) ?? cg
    }

    /// Center-crop a CGImage so it matches the grid aspect ratio (no letterbox).
    private static func coverFitCropRect(imageW: Int, imageH: Int, gridW: Int, gridH: Int) -> CGRect {
        let w = Double(imageW)
        let h = Double(imageH)
        let targetAspect = Double(gridW) / Double(gridH)
        let srcAspect = w / h
        if srcAspect > targetAspect {
            // Source is wider: crop width.
            let newW = (h * targetAspect).rounded()
            let left = ((w - newW) / 2).rounded(.down)
            return CGRect(x: left, y: 0, width: newW, height: h)
        } else {
            // Source is taller: crop height.
            let newH = (w / targetAspect).rounded()
            let top = ((h - newH) / 2).rounded(.down)
            return CGRect(x: 0, y: top, width: w, height: newH)
        }
    }

    /// Return a `(gridH × gridW)` grid of sRGB `[0, 1]` colors, averaged in
    /// linear light — mirroring the backend `_cell_colors_srgb`.
    private static func cellColorsSrgb(
        _ image: CGImage,
        gridW: Int,
        gridH: Int
    ) -> [[(r: Double, g: Double, b: Double)]] {
        let cropRect = coverFitCropRect(
            imageW: image.width,
            imageH: image.height,
            gridW: gridW,
            gridH: gridH
        )
        let crop = image.cropping(to: cropRect) ?? image
        let cw = crop.width
        let ch = crop.height

        let samples = max(
            1,
            min(
                maxSamplesPerCell,
                Int((min(Double(cw) / Double(gridW), Double(ch) / Double(gridH))).rounded())
            )
        )

        let pixelW = gridW * samples
        let pixelH = gridH * samples
        guard let pixels = rgbaPixels(crop, width: pixelW, height: pixelH) else {
            // Honest fallback: a black grid rather than fabricated colors.
            return Array(
                repeating: Array(repeating: (0.0, 0.0, 0.0), count: gridW),
                count: gridH
            )
        }

        var result: [[(r: Double, g: Double, b: Double)]] = []
        result.reserveCapacity(gridH)
        let blockCount = Double(samples * samples)

        for gy in 0..<gridH {
            var row: [(r: Double, g: Double, b: Double)] = []
            row.reserveCapacity(gridW)
            for gx in 0..<gridW {
                var sumR = 0.0, sumG = 0.0, sumB = 0.0
                for sy in 0..<samples {
                    let py = gy * samples + sy
                    let rowBase = py * pixelW
                    for sx in 0..<samples {
                        let px = gx * samples + sx
                        let i = (rowBase + px) * 4
                        // Average in LINEAR light, exactly like the backend.
                        sumR += MosaicColorScience.srgbToLinear(Double(pixels[i]) / 255.0)
                        sumG += MosaicColorScience.srgbToLinear(Double(pixels[i + 1]) / 255.0)
                        sumB += MosaicColorScience.srgbToLinear(Double(pixels[i + 2]) / 255.0)
                    }
                }
                let lr = sumR / blockCount
                let lg = sumG / blockCount
                let lb = sumB / blockCount
                row.append((
                    MosaicColorScience.linearToSrgb(lr),
                    MosaicColorScience.linearToSrgb(lg),
                    MosaicColorScience.linearToSrgb(lb)
                ))
            }
            result.append(row)
        }
        return result
    }

    private static func dominantFraction(_ cells: [[String?]]) -> Double {
        var counts: [String: Int] = [:]
        var total = 0
        for row in cells {
            for name in row {
                guard let name else { continue }
                counts[name, default: 0] += 1
                total += 1
            }
        }
        guard total > 0, let maxCount = counts.values.max() else { return 0.0 }
        return Double(maxCount) / Double(total)
    }

    // MARK: - Core Graphics Helpers

    private static func bakeOrientation(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage {
            return cg
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return redrawn.cgImage
    }

    private static func resample(_ image: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Render `image` into a `width × height` sRGB RGBA8 buffer and return its
    /// bytes (4 per pixel, row-major top-to-bottom).
    private static func rgbaPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let context = makeContext(width: width, height: height) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let count = width * height * 4
        let buffer = data.bindMemory(to: UInt8.self, capacity: count)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func blankPixel() -> CGImage {
        let context = makeContext(width: 1, height: 1)!
        return context.makeImage()!
    }
}
