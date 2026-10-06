import Foundation
import simd

/// Where a photo check's step delta falls in its photo (ADR 0007 amendment
/// 3), measured from expected-depth renders at the photo's own camera under
/// the locked registration. Geometry places the crop; no model is ever asked
/// where anything is (ADR 0015).
enum CheckCropGeometry {
    /// The render grid's width: about the LiDAR depth grid, plenty for a box.
    static let gridWidth = 256
    /// The delta counts as visible only this far in front of the completed
    /// surface behind it — the verifier's visible-footprint rule
    /// (`GeometricStepVerifier.ingestReporting`), kept identical.
    static let visibleMargin: Float = 0.0015

    struct Grid: Equatable {
        let width: Int
        let height: Int
        /// Native intrinsics scaled to the grid, in the renderer's
        /// column-major convention.
        let intrinsics: simd_float3x3
    }

    /// How the stored photo was turned upright: the four rotations
    /// `RecoveryFrameConvention.uprightRotation` can return, with
    /// `CGImagePropertyOrientation`'s meaning (`.right` turns the landscape
    /// sensor image a quarter turn clockwise for display).
    enum UprightRotation: Equatable {
        case up
        case down
        case left
        case right
    }

    /// A grid `width` wide at the sensor's aspect, with the native
    /// column-major intrinsics `[fx 0 0 | 0 fy 0 | cx cy 1]` scaled to it.
    static func grid(cameraIntrinsics: [Float], imageResolution: [Float], width: Int = gridWidth) -> Grid? {
        guard cameraIntrinsics.count == 9, imageResolution.count == 2,
              imageResolution[0] > 0, imageResolution[1] > 0, width > 0 else { return nil }
        let scale = Float(width) / imageResolution[0]
        let height = max(1, Int((imageResolution[1] * scale).rounded()))
        let intrinsics = simd_float3x3(columns: (
            SIMD3(cameraIntrinsics[0] * scale, 0, 0),
            SIMD3(0, cameraIntrinsics[4] * scale, 0),
            SIMD3(cameraIntrinsics[6] * scale, cameraIntrinsics[7] * scale, 1)
        ))
        return Grid(width: width, height: height, intrinsics: intrinsics)
    }

    /// Pixels where the delta is the nearest expected surface.
    static func visibleDelta(completed: [Float32], delta: [Float32]) -> [Int] {
        delta.indices.filter { index in
            guard delta[index] > 0 else { return false }
            let behind = completed[index]
            return behind <= 0 || delta[index] < behind - visibleMargin
        }
    }

    /// The smallest box covering whole `pixels`, normalized to the grid in
    /// the landscape sensor frame: origin top-left, y down.
    static func sensorBox(pixels: [Int], width: Int, height: Int) -> CheckGeometryRecord.Box? {
        guard !pixels.isEmpty, width > 0, height > 0 else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for pixel in pixels {
            let x = pixel % width
            let y = pixel / width
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        let gridWidth = Float(width)
        let gridHeight = Float(height)
        let x = Float(minX) / gridWidth
        let y = Float(minY) / gridHeight
        let boxWidth = Float(maxX - minX + 1) / gridWidth
        let boxHeight = Float(maxY - minY + 1) / gridHeight
        return CheckGeometryRecord.Box(x: x, y: y, width: boxWidth, height: boxHeight)
    }

    /// `box` as it reads on the upright photo.
    static func upright(_ box: CheckGeometryRecord.Box, rotation: UprightRotation) -> CheckGeometryRecord.Box {
        switch rotation {
        case .up:
            return box
        case .down:
            return .init(x: 1 - box.x - box.width, y: 1 - box.y - box.height, width: box.width, height: box.height)
        case .right:
            // A quarter turn clockwise: (x, y) → (1 − y, x).
            return .init(x: 1 - box.y - box.height, y: box.x, width: box.height, height: box.width)
        case .left:
            // A quarter turn counterclockwise: (x, y) → (y, 1 − x).
            return .init(x: box.y, y: 1 - box.x - box.width, width: box.height, height: box.width)
        }
    }

    /// The record for one check, from the completed and delta renders.
    static func record(
        completed: [Float32], delta: [Float32], grid: Grid, rotation: UprightRotation
    ) -> CheckGeometryRecord {
        let visible = visibleDelta(completed: completed, delta: delta)
        return CheckGeometryRecord(
            deltaBox: sensorBox(pixels: visible, width: grid.width, height: grid.height)
                .map { upright($0, rotation: rotation) },
            deltaPixels: visible.count,
            gridWidth: grid.width,
            gridHeight: grid.height
        )
    }

    /// A column-major 4×4 flattened as ARKit transforms are recorded.
    static func matrix(columnMajor values: [Float]) -> simd_float4x4? {
        guard values.count == 16 else { return nil }
        return simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }

    static func flatten(_ matrix: simd_float4x4) -> [Float] {
        (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }
    }
}
