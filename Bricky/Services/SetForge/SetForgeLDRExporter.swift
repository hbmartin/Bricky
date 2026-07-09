import Foundation

/// Exports a Set Forge brick list to deterministic LDraw `.ldr` text.
///
/// Coordinates are LDU. X = column·20, Z = row·20, Y = −layer·24 (LDraw's Y axis
/// points down, so higher build layers get more-negative Y). A 1×N brick's part
/// origin is its centre in LDraw, so we offset by half the run length along X.
/// The result opens in BrickLink Studio, LDView, and LPub3D.
enum SetForgeLDRExporter {

    private static let identity = "1 0 0 0 1 0 0 0 1"

    private static func header(subject: String) -> [String] {
        [
            "0 \(subject.isEmpty ? "Brick Model" : subject)",
            "0 Name: model.ldr",
            "0 Author: Bricky Set Forge",
            "0 !LDRAW_ORG Unofficial_Model",
            "0 BFC CERTIFY CCW",
        ]
    }

    /// Deterministic order: layer (Y) bottom→top, row (Z) front→back, column (X).
    static func sorted(_ bricks: [PlacedBrick]) -> [PlacedBrick] {
        bricks.sorted { a, b in
            if a.y != b.y { return a.y < b.y }
            if a.z != b.z { return a.z < b.z }
            return a.x < b.x
        }
    }

    static func export(_ bricks: [PlacedBrick], subject: String = "") -> String {
        var lines = header(subject: subject)
        let stud = SetForgeContract.lduPerStud
        let layer = SetForgeContract.lduPerLayer
        for brick in sorted(bricks) {
            let code = SetForgeContract.ldrawCode(for: brick.color)
            // Centre of the 1×N run along X.
            let centreStudsX = Double(brick.x) + Double(brick.length - 1) / 2.0
            let x = Int((centreStudsX * Double(stud)).rounded())
            let y = -brick.y * layer
            let z = brick.z * stud
            lines.append("1 \(code) \(x) \(y) \(z) \(identity) \(brick.part).dat")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
