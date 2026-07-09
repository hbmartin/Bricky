import CoreGraphics
import Foundation
import UIKit
import Vision

/// Offline "scan a photo / live subject → brick model" adapter.
///
/// Turns a single photo into a colored `VoxelModel`:
/// 1. Isolate the subject with Vision's foreground-instance segmentation
///    (iOS 17). If segmentation is unavailable, fall back to the whole image.
/// 2. Aspect-fit the masked subject into a stud grid and quantize each cell to
///    the nearest `LegoColor` (shared perceptual matcher).
/// 3. Extrude the silhouette into a chunky flat relief that lies on the table —
///    every column is ground-supported, so the result is always buildable.
///
/// This is the fully offline M1 path. Multi-photo Object Capture → true
/// volumetric reconstruction is the planned Phase-2 upgrade (see
/// `docs/set-forge-plan.md`); it produces a richer `VoxelModel` for the same
/// engine without changing this contract.
enum PhotoVoxelizer {

    enum VoxelizeError: LocalizedError {
        case unreadableImage
        case noSubject

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                return "That image couldn't be read. Try another photo."
            case .noSubject:
                return "No clear subject was found in the photo. Try a photo with a single subject on a plain background."
            }
        }
    }

    /// Build a voxel model from a photo.
    ///
    /// - Parameters:
    ///   - image: The source photo.
    ///   - size: Target size preset (sets the grid's longest side).
    ///   - subject: Caption for naming the resulting set.
    static func voxelize(
        image: UIImage,
        size: VoxelModel.Size,
        subject: String = "Photo"
    ) throws -> VoxelModel {
        guard let cg = image.normalizedOrientation().cgImage else {
            throw VoxelizeError.unreadableImage
        }

        // 1. Isolate the subject (transparent background) when possible.
        let masked = foregroundMasked(cg) ?? cg

        // 2. Grid dimensions from the image aspect ratio, longest side = maxDim.
        let maxDim = size.maxDimension
        let aspect = Double(cg.width) / Double(cg.height)
        let gridW: Int
        let gridH: Int
        if aspect >= 1 {
            gridW = maxDim
            gridH = max(6, Int((Double(maxDim) / aspect).rounded()))
        } else {
            gridH = maxDim
            gridW = max(6, Int((Double(maxDim) * aspect).rounded()))
        }

        guard let pixels = downsampleAspectFit(masked, targetWidth: gridW, targetHeight: gridH) else {
            throw VoxelizeError.unreadableImage
        }

        // 3. Extrude the silhouette into a flat, ground-supported relief. Depth
        //    is kept modest (and independent of resolution) so the higher
        //    footprint detail survives the engine's brick-budget pass instead of
        //    being downsampled away.
        let thickness = 4
        var voxels: [Voxel] = []
        voxels.reserveCapacity(gridW * gridH)

        for row in 0..<gridH {
            for col in 0..<gridW {
                let offset = (row * gridW + col) * 4
                let a = pixels[offset + 3]
                guard a >= 40 else { continue } // background
                let r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2]
                guard let match = LegoColor.closest(r: r, g: g, b: b, excludeTransparent: true) else { continue }
                // Image top → back of the model; lay flat with thickness along Y.
                let z = gridH - 1 - row
                for y in 0..<thickness {
                    voxels.append(Voxel(x: col, y: y, z: z, color: match.color))
                }
            }
        }

        guard !voxels.isEmpty else { throw VoxelizeError.noSubject }

        return VoxelModel(
            width: gridW,
            height: thickness,
            depth: gridH,
            voxels: voxels,
            source: .photo,
            subject: subject
        )
    }

    // MARK: - Vision segmentation

    /// Returns the subject cut out onto a transparent background, or `nil` if
    /// segmentation isn't available or finds nothing.
    private static func foregroundMasked(_ cg: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first,
                  !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: true
            )
            return cgImage(from: buffer)
        } catch {
            return nil
        }
    }

    private static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: - Downsampling

    /// Aspect-fit `cg` into a `targetWidth × targetHeight` RGBA buffer on a
    /// transparent canvas (so occupancy comes from alpha). One cell per stud,
    /// high-quality interpolation.
    private static func downsampleAspectFit(
        _ cg: CGImage,
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8]? {
        guard targetWidth > 0, targetHeight > 0 else { return nil }
        let bytesPerRow = targetWidth * 4
        var data = [UInt8](repeating: 0, count: targetHeight * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let created = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }

            ctx.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            ctx.interpolationQuality = .high

            // Fit while preserving aspect ratio, centered.
            let scale = min(
                Double(targetWidth) / Double(cg.width),
                Double(targetHeight) / Double(cg.height)
            )
            let drawW = Double(cg.width) * scale
            let drawH = Double(cg.height) * scale
            let originX = (Double(targetWidth) - drawW) / 2.0
            let originY = (Double(targetHeight) - drawH) / 2.0
            ctx.draw(cg, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
            return true
        }
        return created ? data : nil
    }
}
