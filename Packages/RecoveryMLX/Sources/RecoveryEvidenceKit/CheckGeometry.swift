import Foundation

/// Where a photo check's step delta fell in its photo (ADR 0007 amendment
/// 3). Rendered on device from the photo's own camera under the locked
/// registration, because the Mac cannot: bundles carry neither the
/// instruction model nor the part pack. It is what lets a replay "locate with
/// geometry, crop, and ask a closed question" — geometry places the crop;
/// no model is ever asked where anything is.
public struct CheckGeometryRecord: Codable, Sendable, Equatable {
    /// `deltaBox` is normalized to the upright stored photo: origin top-left,
    /// x right, y down, each in 0...1 of the photo's width and height.
    public static let uprightCaptureNormalized = "upright_capture_normalized"

    public struct Box: Codable, Sendable, Equatable {
        public var x: Float
        public var y: Float
        public var width: Float
        public var height: Float

        public init(x: Float, y: Float, width: Float, height: Float) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var coordinateSpace: String
    /// Nil when no pixel of the delta is visible from this camera: the
    /// delta is hidden behind completed parts or out of frame.
    public var deltaBox: Box?
    /// Visible delta pixels on the render grid.
    public var deltaPixels: Int
    /// The render grid the box was measured on, in the landscape sensor frame.
    public var gridWidth: Int
    public var gridHeight: Int

    public init(
        coordinateSpace: String = CheckGeometryRecord.uprightCaptureNormalized,
        deltaBox: Box?, deltaPixels: Int, gridWidth: Int, gridHeight: Int
    ) {
        self.coordinateSpace = coordinateSpace
        self.deltaBox = deltaBox
        self.deltaPixels = deltaPixels
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
    }

    enum CodingKeys: String, CodingKey {
        case coordinateSpace = "coordinate_space"
        case deltaBox = "delta_box"
        case deltaPixels = "delta_pixels"
        case gridWidth = "grid_width"
        case gridHeight = "grid_height"
    }
}
