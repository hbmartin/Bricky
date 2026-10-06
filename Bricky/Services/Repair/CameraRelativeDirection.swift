import Foundation
import simd

/// Turns a repair's model-frame correction into a direction the user can
/// act on (M2.4). Computed from poses, never from a model.
///
/// The correction is carried into the world by the registered model pose,
/// then compared with two gravity-aligned axes: screen right flattened onto
/// the floor, and "away" perpendicular to it. When the camera looks nearly
/// straight down, "away from you" stops meaning anything, so the screen's
/// own directions are used instead.
enum CameraRelativeDirection {
    /// Camera pitch below the horizon, in degrees, at which wording turns
    /// screen-relative, and at which it turns back.
    static let topDownEnter: Float = 70
    static let topDownExit: Float = 62

    /// The world-frame correction for moving a placement by `offset` studs
    /// (a correction is minus the measured displacement).
    static func worldCorrection(_ offset: LatticeOffset, worldFromModel: simd_float4x4, studPitch: Float = 0.008) -> SIMD3<Float> {
        let model = SIMD3<Float>(Float(offset.dx) * studPitch, 0, Float(offset.dz) * studPitch)
        let rotation = simd_float3x3(
            SIMD3(worldFromModel.columns.0.x, worldFromModel.columns.0.y, worldFromModel.columns.0.z),
            SIMD3(worldFromModel.columns.1.x, worldFromModel.columns.1.y, worldFromModel.columns.1.z),
            SIMD3(worldFromModel.columns.2.x, worldFromModel.columns.2.y, worldFromModel.columns.2.z)
        )
        return rotation * model
    }

    /// Degrees below the horizon the camera looks.
    static func pitchDegrees(worldFromCamera: simd_float4x4) -> Float {
        let forward = -SIMD3(worldFromCamera.columns.2.x, worldFromCamera.columns.2.y, worldFromCamera.columns.2.z)
        return asin(max(-1, min(1, -simd_normalize(forward).y))) * 180 / .pi
    }

    /// The correction's bearing, in degrees, measured from "away" (0) toward
    /// "your right" (90), on the floor plane. Nil when either the correction
    /// or the screen's right axis has no horizontal extent.
    static func bearingDegrees(
        correction: SIMD3<Float>, worldFromCamera: simd_float4x4, rotation: ScreenRotation
    ) -> Float? {
        let axes = rotation.screenAxesInCamera
        let cameraRotation = simd_float3x3(
            SIMD3(worldFromCamera.columns.0.x, worldFromCamera.columns.0.y, worldFromCamera.columns.0.z),
            SIMD3(worldFromCamera.columns.1.x, worldFromCamera.columns.1.y, worldFromCamera.columns.1.z),
            SIMD3(worldFromCamera.columns.2.x, worldFromCamera.columns.2.y, worldFromCamera.columns.2.z)
        )
        var right = cameraRotation * axes.right
        right.y = 0
        let flat = SIMD3<Float>(correction.x, 0, correction.z)
        guard simd_length(right) > 1e-4, simd_length(flat) > 1e-6 else { return nil }
        right = simd_normalize(right)
        // Up × right is "away" for a right-handed, y-up world.
        let away = simd_cross(SIMD3<Float>(0, 1, 0), right)
        return atan2(simd_dot(flat, right), simd_dot(flat, away)) * 180 / .pi
    }

    /// The four-way sector of a bearing.
    static func sector(bearing: Float, topDown: Bool) -> RelativeDirection {
        let wrapped = (bearing + 360).truncatingRemainder(dividingBy: 360)
        switch wrapped {
        case 45..<135: return topDown ? .screenRight : .yourRight
        case 135..<225: return topDown ? .screenDown : .towardYou
        case 225..<315: return topDown ? .screenLeft : .yourLeft
        default: return topDown ? .screenUp : .awayFromYou
        }
    }

    /// Degrees from `bearing` to the nearest sector boundary (45°, 135°…).
    static func distanceToBoundary(bearing: Float) -> Float {
        let wrapped = (bearing + 360).truncatingRemainder(dividingBy: 360)
        let offset = (wrapped - 45).truncatingRemainder(dividingBy: 90)
        let positive = offset < 0 ? offset + 90 : offset
        return min(positive, 90 - positive)
    }
}

/// Keeps the spoken or written direction from flickering as the phone moves
/// (M2.4). A new sector is taken only once the bearing has been more than
/// `hysteresisDegrees` inside it for `dwell`; the top-down switch has its
/// own pitch hysteresis. A first reading too close to a boundary gives no
/// direction at all, rather than a coin toss.
struct DirectionStabilizer {
    static let hysteresisDegrees: Float = 8
    static let dwell: TimeInterval = 1

    private(set) var current: RelativeDirection?
    private(set) var topDown = false
    private var candidate: (direction: RelativeDirection, since: TimeInterval)?

    mutating func update(bearing: Float?, pitchDegrees: Float, at time: TimeInterval) -> RelativeDirection? {
        if topDown, pitchDegrees < CameraRelativeDirection.topDownExit {
            topDown = false
            current = nil
            candidate = nil
        } else if !topDown, pitchDegrees > CameraRelativeDirection.topDownEnter {
            topDown = true
            current = nil
            candidate = nil
        }
        guard let bearing else {
            candidate = nil
            return current
        }
        let sector = CameraRelativeDirection.sector(bearing: bearing, topDown: topDown)
        let clear = CameraRelativeDirection.distanceToBoundary(bearing: bearing) > Self.hysteresisDegrees
        guard let current else {
            if clear { self.current = sector }
            return self.current
        }
        guard sector != current, clear else {
            candidate = nil
            return current
        }
        if let candidate, candidate.direction == sector {
            if time - candidate.since >= Self.dwell {
                self.current = sector
                self.candidate = nil
            }
        } else {
            candidate = (sector, time)
        }
        return self.current
    }
}
