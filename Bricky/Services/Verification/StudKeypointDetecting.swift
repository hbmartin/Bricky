import Foundation
import simd

/// A stud keypoint heatmap over one photo crop (ADR 0020, Proposed): the
/// seam a learned detector would sit behind. Nothing calls it yet, and no
/// model exists; the entry criterion (lattice aliasing measured on device
/// rows) is unmet.
///
/// Rules any implementation keeps:
/// - Its output may only feed a geometry term that blocks or sharpens a
///   verdict, in shadow first. It never produces a coordinate, an offset or
///   a direction that reaches the user (ADR 0015: geometry measures, models
///   only phrase).
/// - Input is a copied RGB crop, not the camera's pixel buffer: zero-copy
///   `CVPixelBuffer` input to Core AI is undemonstrated.
/// - Training data is real staged captures only, labelled by
///   `--stud-labels-bundle` and audited by hand. Never synthetic RGB
///   (ADR 0008, ADR 0014).
protocol StudKeypointDetecting: Sendable {
    /// Per-pixel stud-centre likelihood for an RGB8 crop, `width × height`,
    /// row-major; nil when no model is loaded.
    func heatmap(rgb: [UInt8], width: Int, height: Int) async throws -> StudHeatmap?
}

/// A detector's output: likelihoods in [0, 1] on its own grid, which maps
/// onto the crop by `scale`.
struct StudHeatmap: Sendable, Equatable {
    let values: [Float]
    let width: Int
    let height: Int
    /// Crop pixels per heatmap cell.
    let scale: Float
}

/// The default: no detector, no opinion. Every caller must already work
/// with this.
struct NoStudKeypointDetector: StudKeypointDetecting {
    func heatmap(rgb: [UInt8], width: Int, height: Int) async throws -> StudHeatmap? { nil }
}
