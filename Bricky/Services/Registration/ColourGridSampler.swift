import CoreVideo
import Foundation

/// Box-filters the camera image onto the LiDAR depth grid, so a verification
/// window keeps the colour evidence the RGB term will need (ADR 0008) at the
/// depth map's resolution. Evidence only: nothing reads it for a verdict.
///
/// Averaging happens in Y′CbCr before conversion, so a cell's colour is
/// gamma-space, not linear-light, mean. That is a known bias at strong edges
/// and is recorded rather than corrected.
enum ColourGridSampler {
    enum Matrix: String, Sendable {
        case bt601
        case bt709
    }

    enum Range: String, Sendable {
        /// Y and C span 0…255 (`420f`).
        case full
        /// Y spans 16…235 and C 16…240 (`420v`).
        case video
    }

    /// A view of one plane's bytes.
    struct Plane {
        let base: UnsafeRawPointer
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    static func encoding(matrix: Matrix, range: Range) -> String {
        "rgb8_\(matrix.rawValue)_\(range.rawValue)"
    }

    /// Samples a bi-planar 4:2:0 image (`luma` full size, `chroma` CbCr
    /// interleaved at half size) onto `gridWidth × gridHeight` cells,
    /// reading every `step`-th pixel of each cell in both directions.
    /// Returns RGB8, interleaved, row-major.
    static func sample(
        luma: Plane, chroma: Plane, matrix: Matrix, range: Range,
        gridWidth: Int, gridHeight: Int, step: Int = 2
    ) -> [UInt8] {
        guard gridWidth > 0, gridHeight > 0, luma.width > 0, luma.height > 0 else { return [] }
        let stride = max(1, step)
        var rgb = [UInt8](repeating: 0, count: gridWidth * gridHeight * 3)
        let lumaBytes = luma.base.assumingMemoryBound(to: UInt8.self)
        let chromaBytes = chroma.base.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<gridHeight {
            let y0 = gy * luma.height / gridHeight
            let y1 = max(y0 + 1, (gy + 1) * luma.height / gridHeight)
            for gx in 0..<gridWidth {
                let x0 = gx * luma.width / gridWidth
                let x1 = max(x0 + 1, (gx + 1) * luma.width / gridWidth)
                var ySum = 0, cbSum = 0, crSum = 0, count = 0
                var y = y0
                while y < y1 {
                    let lumaRow = lumaBytes + y * luma.bytesPerRow
                    let chromaRow = chromaBytes + min(y / 2, chroma.height - 1) * chroma.bytesPerRow
                    var x = x0
                    while x < x1 {
                        ySum += Int(lumaRow[x])
                        let c = min(x / 2, chroma.width - 1) * 2
                        cbSum += Int(chromaRow[c])
                        crSum += Int(chromaRow[c + 1])
                        count += 1
                        x += stride
                    }
                    y += stride
                }
                let (r, g, b) = convert(
                    y: Float(ySum) / Float(count), cb: Float(cbSum) / Float(count), cr: Float(crSum) / Float(count),
                    matrix: matrix, range: range
                )
                let out = (gy * gridWidth + gx) * 3
                rgb[out] = r
                rgb[out + 1] = g
                rgb[out + 2] = b
            }
        }
        return rgb
    }

    /// One Y′CbCr sample to RGB8.
    static func convert(y: Float, cb: Float, cr: Float, matrix: Matrix, range: Range) -> (UInt8, UInt8, UInt8) {
        let luma: Float
        let blue: Float
        let red: Float
        switch range {
        case .full:
            luma = y
            blue = cb - 128
            red = cr - 128
        case .video:
            luma = (y - 16) * 255 / 219
            blue = (cb - 128) * 255 / 224
            red = (cr - 128) * 255 / 224
        }
        let r, g, b: Float
        switch matrix {
        case .bt601:
            r = luma + 1.402 * red
            g = luma - 0.344136 * blue - 0.714136 * red
            b = luma + 1.772 * blue
        case .bt709:
            r = luma + 1.5748 * red
            g = luma - 0.187324 * blue - 0.468124 * red
            b = luma + 1.8556 * blue
        }
        func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
        return (byte(r), byte(g), byte(b))
    }

    /// Samples an ARKit camera image. Nil for anything but bi-planar 4:2:0.
    static func sample(_ buffer: CVPixelBuffer, gridWidth: Int, gridHeight: Int) -> (rgb: [UInt8], encoding: String)? {
        let range: Range
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: range = .full
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: range = .video
        default: return nil
        }
        let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        let matrix: Matrix = (attachment as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) ? .bt709 : .bt601
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let rgb = sample(
            luma: Plane(
                base: lumaBase,
                width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            ),
            chroma: Plane(
                base: chromaBase,
                width: CVPixelBufferGetWidthOfPlane(buffer, 1),
                height: CVPixelBufferGetHeightOfPlane(buffer, 1),
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            ),
            matrix: matrix,
            range: range,
            gridWidth: gridWidth,
            gridHeight: gridHeight
        )
        return (rgb, encoding(matrix: matrix, range: range))
    }

    /// Resamples a one-component mask (person segmentation, 0 or 255) onto
    /// the depth grid by nearest neighbour, as 0 or 1.
    static func occluderMask(_ buffer: CVPixelBuffer, gridWidth: Int, gridHeight: Int) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var mask = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let sy = min(height - 1, (gy * height + height / 2) / gridHeight)
            for gx in 0..<gridWidth {
                let sx = min(width - 1, (gx * width + width / 2) / gridWidth)
                mask[gy * gridWidth + gx] = bytes[sy * bytesPerRow + sx] > 127 ? 1 : 0
            }
        }
        return mask
    }
}
