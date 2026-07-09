import Foundation

/// Single source of truth for Set Forge brick geometry and LDraw mapping.
///
/// Mirrors the Mosaic `MosaicContract`, but for genuine 3D models: bricks are
/// standard 1×N *bricks* (not plates), tiled along the grid's X axis within each
/// build layer. Coordinates are LDraw Units (LDU).
enum SetForgeContract {
    /// 1 stud (X/Z spacing) = 20 LDU.
    static let lduPerStud = 20
    /// 1 brick tall = 24 LDU (a plate is 8; a brick is three plates).
    static let lduPerLayer = 24

    /// Brick length (studs, along X) → LDraw part id for a 1×N brick.
    static let partByLength: [Int: String] = [
        1: "3005",  // 1×1
        2: "3004",  // 1×2
        3: "3622",  // 1×3
        4: "3010",  // 1×4
        6: "3009",  // 1×6
        8: "3008",  // 1×8
    ]

    /// Brick length → human-readable name for the parts list / instructions.
    static let nameByLength: [Int: String] = [
        1: "1×1 Brick",
        2: "1×2 Brick",
        3: "1×3 Brick",
        4: "1×4 Brick",
        6: "1×6 Brick",
        8: "1×8 Brick",
    ]

    /// Lengths the packer may emit, greedy longest-first.
    static let allowedLengths: [Int] = [8, 6, 4, 3, 2, 1]

    static func part(forLength length: Int) -> String {
        partByLength[length] ?? "3005"
    }

    static func name(forLength length: Int) -> String {
        nameByLength[length] ?? "Brick"
    }

    /// Map a `LegoColor` to its standard LDraw colour code so exported `.ldr`
    /// files open correctly in Studio / LDView / LPub3D.
    static func ldrawCode(for color: LegoColor) -> Int {
        switch color {
        case .red: return 4
        case .blue: return 1
        case .yellow: return 14
        case .green: return 2
        case .black: return 0
        case .white: return 15
        case .gray: return 7          // light gray
        case .darkGray: return 8      // dark gray
        case .orange: return 25
        case .brown: return 6
        case .tan: return 19
        case .darkBlue: return 272
        case .darkGreen: return 288
        case .darkRed: return 320
        case .lime: return 27
        case .purple: return 22
        case .pink: return 13
        case .lightBlue: return 9
        case .transparent: return 47
        case .transparentBlue: return 41
        case .transparentRed: return 36
        }
    }
}

/// A brick placed in a finished Set Forge model. A run of `length` studs along
/// +X starting at `(x, y, z)`, all one colour.
struct PlacedBrick: Equatable, Codable, Hashable {
    var x: Int
    var y: Int
    var z: Int
    var length: Int
    var color: LegoColor

    var part: String { SetForgeContract.part(forLength: length) }
    var name: String { SetForgeContract.name(forLength: length) }
}
