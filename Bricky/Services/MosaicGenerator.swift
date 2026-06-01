import CoreGraphics
import Foundation
import UIKit

/// Stage 1 of the LEGO model-generation pipeline: turn a source photo into
/// a deterministic, quantized `MosaicGrid`.
///
/// The transform is intentionally pure and offline:
/// 1. Normalize EXIF orientation.
/// 2. **Cover-fit** the source into the target stud grid (aspect fill +
///    center crop) so the subject fills the frame without distortion.
/// 3. Downsample to `width × height` pixels with high-quality
///    interpolation — one pixel per stud, area-averaged.
/// 4. Quantize each pixel to the nearest `LegoColor` via the shared
///    perceptual matcher in `LegoColor.closest`.
///
/// Conforms to the Color Grid Contract in
/// `docs/LEGO Model Generation System/DATA_CONTRACTS.md` §3 and the
/// projection/quantization rules in `VISION_PIPELINE.md` §4–§5.
///
/// The same input image and parameters always yield the same grid
/// (determinism is verified in tests), so downstream packing, LDraw
/// export, and instructions are reproducible.
struct MosaicGenerator {

    /// Default palette identifier for the MVP color set.
    static let defaultPaletteId = "mvp-v1"

    /// Alpha below this (0–255) marks a stud as background (`nil`).
    /// Opaque photos never trip this; cut-outs / PNGs with transparency do.
    private let backgroundAlphaThreshold: UInt8

    /// Whether to exclude transparent LEGO colors from matching. Solid
    /// mosaics should keep this `true` so a red stud never becomes
    /// "Trans Red".
    private let excludeTransparentColors: Bool

    /// Palette id stamped onto produced grids.
    private let paletteId: String

    init(
        paletteId: String = MosaicGenerator.defaultPaletteId,
        excludeTransparentColors: Bool = true,
        backgroundAlphaThreshold: UInt8 = 16
    ) {
        self.paletteId = paletteId
        self.excludeTransparentColors = excludeTransparentColors
        self.backgroundAlphaThreshold = backgroundAlphaThreshold
    }

    // MARK: - Public API

    /// Generate a square grid using a size preset.
    func generate(from image: UIImage, preset: MosaicGridPreset) -> MosaicGrid? {
        generate(from: image, width: preset.studs, height: preset.studs)
    }

    /// Generate a grid of an explicit stud size.
    ///
    /// - Parameters:
    ///   - image: Source photo. Orientation is normalized internally.
    ///   - width: Target studs across (1...96).
    ///   - height: Target studs down (1...96).
    /// - Returns: A validated `MosaicGrid`, or `nil` if the image has no
    ///   readable bitmap or the dimensions are out of range.
    func generate(from image: UIImage, width: Int, height: Int) -> MosaicGrid? {
        let cap = MosaicGridPreset.maxStudsPerSide
        guard width >= 1, height >= 1, width <= cap, height <= cap else {
            return nil
        }
        guard let cgImage = image.normalizedOrientation().cgImage else {
            return nil
        }

        guard let pixels = downsampleCoverFit(
            cgImage,
            targetWidth: width,
            targetHeight: height
        ) else {
            return nil
        }

        var cells: [[LegoColor?]] = []
        cells.reserveCapacity(height)

        for y in 0..<height {
            var row: [LegoColor?] = []
            row.reserveCapacity(width)
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = pixels[offset]
                let g = pixels[offset + 1]
                let b = pixels[offset + 2]
                let a = pixels[offset + 3]

                if a < backgroundAlphaThreshold {
                    row.append(nil)
                } else {
                    let match = LegoColor.closest(
                        r: r, g: g, b: b,
                        excludeTransparent: excludeTransparentColors
                    )
                    row.append(match?.color)
                }
            }
            cells.append(row)
        }

        let grid = MosaicGrid(
            width: width,
            height: height,
            paletteId: paletteId,
            cells: cells
        )
        assert(grid.isShapeValid, "MosaicGenerator produced a malformed grid")
        return grid
    }

    /// Aspect-preserving stud dimensions whose longest side equals
    /// `maxStuds`. Useful for "fit" sizing from an arbitrary photo. The
    /// result is clamped to the 96-stud cap.
    static func fittedDimensions(
        for imageSize: CGSize,
        maxStuds: Int
    ) -> (width: Int, height: Int) {
        let cap = MosaicGridPreset.maxStudsPerSide
        let longest = max(1, min(maxStuds, cap))
        let w = max(imageSize.width, 1)
        let h = max(imageSize.height, 1)

        if w >= h {
            let height = Int((CGFloat(longest) * h / w).rounded())
            return (longest, Swift.max(1, height))
        } else {
            let width = Int((CGFloat(longest) * w / h).rounded())
            return (Swift.max(1, width), longest)
        }
    }

    // MARK: - Pixel sampling

    /// Render `cgImage` into a `targetWidth × targetHeight` RGBA8 bitmap
    /// using cover-fit (aspect fill + center crop) and high-quality
    /// interpolation, returning the raw premultiplied pixel buffer.
    ///
    /// The bitmap context has a top-left origin (rows top→bottom) so the
    /// returned buffer indexes directly as `(y * width + x) * 4`.
    private func downsampleCoverFit(
        _ cgImage: CGImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = targetWidth * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * targetHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let made = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.interpolationQuality = .high
            // No manual flip: a CGBitmapContext stores rows top-to-bottom in
            // memory, so drawing the CGImage directly lands row 0 of the
            // buffer at the top of the image — matching the row-major,
            // top-left-origin Color Grid Contract.

            let drawRect = Self.coverFitRect(
                source: CGSize(width: cgImage.width, height: cgImage.height),
                target: CGSize(width: targetWidth, height: targetHeight)
            )
            context.draw(cgImage, in: drawRect)
            return true
        }

        return made ? buffer : nil
    }

    /// The rect, in target space, that scales `source` to **cover** the
    /// `target` box (longest overflow cropped, centered).
    static func coverFitRect(source: CGSize, target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else {
            return CGRect(origin: .zero, size: target)
        }
        let scale = max(target.width / source.width, target.height / source.height)
        let scaledW = source.width * scale
        let scaledH = source.height * scale
        let originX = (target.width - scaledW) / 2
        let originY = (target.height - scaledH) / 2
        return CGRect(x: originX, y: originY, width: scaledW, height: scaledH)
    }
}
