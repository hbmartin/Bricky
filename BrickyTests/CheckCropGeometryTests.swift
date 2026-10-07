import CoreImage
import ImageIO
import simd
import XCTest
@testable import Bricky

/// The check's delta box: the verifier's visible-footprint rule, a whole-
/// pixel box, and the same upright turn the stored photo was given.
final class CheckCropGeometryTests: XCTestCase {
    func testGridScalesIntrinsicsToTheSensorAspect() throws {
        let grid = try XCTUnwrap(CheckCropGeometry.grid(
            cameraIntrinsics: [1500, 0, 0, 0, 1500, 0, 960, 720, 1], imageResolution: [1920, 1440]
        ))
        XCTAssertEqual(grid.width, 256)
        XCTAssertEqual(grid.height, 192)
        XCTAssertEqual(grid.intrinsics[0][0], 200, accuracy: 1e-4)
        XCTAssertEqual(grid.intrinsics[1][1], 200, accuracy: 1e-4)
        XCTAssertEqual(grid.intrinsics[2][0], 128, accuracy: 1e-4)
        XCTAssertEqual(grid.intrinsics[2][1], 96, accuracy: 1e-4)
        XCTAssertNil(CheckCropGeometry.grid(cameraIntrinsics: [1], imageResolution: [1920, 1440]))
        XCTAssertNil(CheckCropGeometry.grid(cameraIntrinsics: Array(repeating: 1, count: 9), imageResolution: [0, 1440]))
    }

    func testBoxCoversTheVisibleDelta() {
        let grid = CheckCropGeometry.Grid(width: 8, height: 4, intrinsics: matrix_identity_float3x3)
        var completed = [Float32](repeating: 0.5, count: 32)
        var delta = [Float32](repeating: 0, count: 32)
        for y in 1...2 {
            for x in 2...4 { delta[y * 8 + x] = 0.48 }
        }
        // Behind the completed surface, and within the 1.5 mm margin: hidden.
        delta[0] = 0.6
        delta[7] = 0.4995
        // Nothing completed behind it: visible.
        completed[31] = 0
        delta[31] = 0.7
        let record = CheckCropGeometry.record(completed: completed, delta: delta, grid: grid, rotation: .up)
        XCTAssertEqual(record.deltaPixels, 7)
        let expected = CheckGeometryRecord.Box(x: 0.25, y: 0.25, width: 0.75, height: 0.75)
        XCTAssertEqual(record.deltaBox, expected)
        XCTAssertEqual(record.gridWidth, 8)
        XCTAssertEqual(record.coordinateSpace, CheckGeometryRecord.uprightCaptureNormalized)
    }

    func testOccludedDeltaHasNoBox() {
        let grid = CheckCropGeometry.Grid(width: 4, height: 2, intrinsics: matrix_identity_float3x3)
        let completed = [Float32](repeating: 0.5, count: 8)
        var delta = [Float32](repeating: 0, count: 8)
        delta[1] = 0.6
        delta[2] = 0.499
        let record = CheckCropGeometry.record(completed: completed, delta: delta, grid: grid, rotation: .right)
        XCTAssertEqual(record.deltaPixels, 0)
        XCTAssertNil(record.deltaBox)
    }

    /// The box must land where the delta lands on the stored photo, which
    /// `RecoveryCaptureService` turns upright with `CIImage.oriented`.
    func testUprightMappingMatchesCaptureOrientation() throws {
        let width = 8, height = 4
        let sensorBox = CheckGeometryRecord.Box(x: 0.125, y: 0.25, width: 0.375, height: 0.5)
        let pairs: [(CheckCropGeometry.UprightRotation, CGImagePropertyOrientation)] = [
            (.up, .up), (.down, .down), (.left, .left), (.right, .right)
        ]
        for (rotation, orientation) in pairs {
            let source = try image(width: width, height: height, lit: sensorBox)
            let oriented = CIImage(cgImage: source).oriented(orientation)
            let context = CIContext()
            let rendered = try XCTUnwrap(context.createCGImage(oriented, from: oriented.extent))
            let observed = try litBox(of: rendered)
            XCTAssertEqual(CheckCropGeometry.upright(sensorBox, rotation: rotation), observed, "\(orientation.rawValue)")
            XCTAssertEqual(CheckCropGeometry.UprightRotation(orientation), rotation)
        }
        XCTAssertNil(CheckCropGeometry.UprightRotation(.upMirrored))
    }

    /// The Mac's copy of the device's upright rule must agree with it for
    /// every way the phone can be held, and for the straight-down fallback.
    func testUprightRotationMatchesFrameConvention() {
        func camera(x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) -> simd_float4x4 {
            simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(0, 0, 0, 1)))
        }
        let held: [(String, simd_float4x4)] = [
            ("landscape", camera(x: SIMD3(1, 0, 0), y: SIMD3(0, 1, 0), z: SIMD3(0, 0, 1))),
            ("landscape flipped", camera(x: SIMD3(-1, 0, 0), y: SIMD3(0, -1, 0), z: SIMD3(0, 0, 1))),
            ("portrait upside down", camera(x: SIMD3(0, 1, 0), y: SIMD3(-1, 0, 0), z: SIMD3(0, 0, 1))),
            ("portrait", camera(x: SIMD3(0, -1, 0), y: SIMD3(1, 0, 0), z: SIMD3(0, 0, 1))),
            ("straight down", camera(x: SIMD3(1, 0, 0), y: SIMD3(0, 0, -1), z: SIMD3(0, 1, 0))),
        ]
        for (label, transform) in held {
            XCTAssertEqual(
                CheckCropGeometry.uprightRotation(worldFromCamera: transform),
                CheckCropGeometry.UprightRotation(RecoveryFrameConvention.uprightRotation(cameraTransform: transform)),
                label
            )
        }
    }

    func testUprightPointMatchesTheBoxMapping() {
        let point = SIMD2<Float>(0.125, 0.75)
        for rotation in [CheckCropGeometry.UprightRotation.up, .down, .left, .right] {
            let box = CheckCropGeometry.upright(
                CheckGeometryRecord.Box(x: point.x, y: point.y, width: 0, height: 0), rotation: rotation
            )
            XCTAssertEqual(CheckCropGeometry.upright(point: point, rotation: rotation), SIMD2(box.x, box.y), "\(rotation)")
        }
    }

    func testMatrixRoundTripsColumnMajor() throws {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(1, 2, 3, 1)
        let flat = CheckCropGeometry.flatten(transform)
        XCTAssertEqual(Array(flat[12..<16]), [1, 2, 3, 1])
        XCTAssertEqual(CheckCropGeometry.matrix(columnMajor: flat), transform)
        XCTAssertNil(CheckCropGeometry.matrix(columnMajor: [1, 2]))
    }

    // MARK: - Helpers

    /// Grey image, row 0 at the top, white where `lit` covers.
    private func image(width: Int, height: Int, lit: CheckGeometryRecord.Box) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let x0 = Int((lit.x * Float(width)).rounded()), x1 = Int(((lit.x + lit.width) * Float(width)).rounded())
        let y0 = Int((lit.y * Float(height)).rounded()), y1 = Int(((lit.y + lit.height) * Float(height)).rounded())
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x0..<x1).contains(x) && (y0..<y1).contains(y) ? 255 : 40
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    /// The normalized box of bright pixels, reading row 0 as the top.
    private func litBox(of image: CGImage) throws -> CheckGeometryRecord.Box {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var lit: [Int] = []
        for index in 0..<(width * height) where pixels[index * 4] > 128 {
            lit.append(index)
        }
        return try XCTUnwrap(CheckCropGeometry.sensorBox(pixels: lit, width: width, height: height))
    }
}
