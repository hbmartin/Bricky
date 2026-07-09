import Foundation

/// Offline "describe a subject → brick model" adapter.
///
/// Maps a natural-language description to a procedurally generated `VoxelModel`
/// using a library of parametric templates. Every template is a **ground-supported
/// extrusion** — each occupied `(x, z)` column is filled from `y = 0` up to a
/// per-column height — so the result is always physically buildable (no floating
/// bricks) and survives the engine's gravity-settle pass unchanged.
///
/// This is the fully offline core. A future Phase-2 path can supply an
/// LLM-authored `VoxelModel` for arbitrary subjects; until then this produces a
/// genuine, buildable model for the described subject and honestly reports which
/// template it matched so the UI never over-promises.
enum VoxelShapeLibrary {

    /// A matched template plus the model it produced.
    struct Match {
        let templateName: String
        let model: VoxelModel
    }

    /// Build a model for a free-text description.
    ///
    /// - Parameters:
    ///   - description: The user's subject text.
    ///   - size: Target size preset (scales resolution).
    ///   - accent: Optional colour override for the model's primary colour.
    static func match(for description: String, size: VoxelModel.Size, accent: LegoColor? = nil) -> Match {
        let scale = size.maxDimension
        let tokens = normalize(description)
        let template = template(for: tokens)
        let voxels = template.build(scale, accent)
        let model = VoxelModel(
            width: bound(voxels, \.x),
            height: bound(voxels, \.y),
            depth: bound(voxels, \.z),
            voxels: voxels,
            source: .text,
            subject: description.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return Match(templateName: template.name, model: model)
    }

    // MARK: - Routing

    private struct Template {
        let name: String
        let keywords: [String]
        let build: (_ scale: Int, _ accent: LegoColor?) -> [Voxel]
    }

    private static func template(for tokens: Set<String>) -> Template {
        for t in templates where t.keywords.contains(where: tokens.contains) {
            return t
        }
        return fallback
    }

    private static func normalize(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let cleaned = lowered.map { $0.isLetter || $0.isNumber ? $0 : " " }
        let words = String(cleaned).split(separator: " ").map(String.init)
        // Include singular forms (strip a trailing "s") for loose matching.
        var set = Set(words)
        for w in words where w.count > 3 && w.hasSuffix("s") {
            set.insert(String(w.dropLast()))
        }
        return set
    }

    // MARK: - Primitive builders

    /// Append a filled axis-aligned box of one colour.
    private static func box(
        _ voxels: inout [Voxel],
        x: Int, y: Int, z: Int,
        w: Int, h: Int, d: Int,
        color: LegoColor
    ) {
        guard w > 0, h > 0, d > 0 else { return }
        for xx in x..<(x + w) {
            for yy in max(0, y)..<(y + h) {
                for zz in z..<(z + d) {
                    voxels.append(Voxel(x: xx, y: yy, z: zz, color: color))
                }
            }
        }
    }

    /// Build an upright model from a footprint height-map and a colour function.
    /// Fills each `(x, z)` column from the ground up to `height(x, z)`.
    private static func extrude(
        w: Int, d: Int,
        height: (_ x: Int, _ z: Int) -> Int,
        colorAt: (_ x: Int, _ y: Int, _ z: Int) -> LegoColor?
    ) -> [Voxel] {
        var voxels: [Voxel] = []
        for x in 0..<w {
            for z in 0..<d {
                let h = height(x, z)
                guard h > 0 else { continue }
                for y in 0..<h {
                    if let c = colorAt(x, y, z) {
                        voxels.append(Voxel(x: x, y: y, z: z, color: c))
                    }
                }
            }
        }
        return voxels
    }

    /// Build a flat relief lying on the table: a silhouette mask in the X-Z
    /// plane, extruded a few layers thick along Y. Always ground-supported.
    private static func flatRelief(
        w: Int, d: Int, thickness: Int,
        mask: (_ x: Int, _ z: Int) -> LegoColor?
    ) -> [Voxel] {
        var voxels: [Voxel] = []
        for x in 0..<w {
            for z in 0..<d {
                guard let c = mask(x, z) else { continue }
                for y in 0..<max(1, thickness) {
                    voxels.append(Voxel(x: x, y: y, z: z, color: c))
                }
            }
        }
        return voxels
    }

    private static func bound(_ voxels: [Voxel], _ key: KeyPath<Voxel, Int>) -> Int {
        (voxels.map { $0[keyPath: key] }.max() ?? 0) + 1
    }

    // MARK: - Templates

    private static let templates: [Template] = [
        houseTemplate, treeTemplate, carTemplate, rocketTemplate, robotTemplate,
        dogTemplate, catTemplate, fishTemplate, birdTemplate, flowerTemplate,
        heartTemplate, starTemplate, snowmanTemplate, castleTemplate,
        pyramidTemplate, mountainTemplate, boatTemplate, planeTemplate,
    ]

    private static let houseTemplate = Template(
        name: "House",
        keywords: ["house", "home", "cabin", "cottage", "hut", "building", "barn"]
    ) { scale, accent in
        let w = scale, d = max(6, scale * 3 / 4)
        let wallH = max(4, scale / 2)
        let wall = accent ?? .tan
        return extrude(w: w, d: d, height: { x, z in
            // Gabled roof: peak along the centre row, sloping to the eaves.
            let roof = max(0, (w / 2) - abs(x - w / 2))
            return wallH + roof
        }, colorAt: { x, y, z in
            let roofBase = wallH
            if y >= roofBase { return .red }
            // Door in the front-centre.
            if z == 0, abs(x - w / 2) <= 0, y < wallH * 2 / 3 { return .brown }
            // Windows.
            if z == 0, y >= wallH / 3, y < wallH * 2 / 3,
               (x == w / 4 || x == 3 * w / 4) { return .lightBlue }
            return wall
        })
    }

    private static let treeTemplate = Template(
        name: "Tree",
        keywords: ["tree", "oak", "pine", "bush", "shrub", "forest", "plant"]
    ) { scale, accent in
        let w = scale, d = scale
        let cx = w / 2, cz = d / 2
        let canopy = accent ?? .green
        let radius = Double(min(w, d)) / 2.0
        return extrude(w: w, d: d, height: { x, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            // Rounded canopy dome; trunk is the tall thin centre.
            if r < 1.5 { return scale } // trunk column height
            let dome = Int((radius - r) * 1.4)
            return max(0, dome + scale / 3)
        }, colorAt: { x, y, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            if r < 1.5, y < scale / 2 { return .brown } // trunk
            if y < 1 { return .brown }                  // grounded base
            return canopy
        })
    }

    private static let carTemplate = Template(
        name: "Car",
        keywords: ["car", "truck", "vehicle", "auto", "automobile", "racer", "van", "jeep"]
    ) { scale, accent in
        let w = max(8, scale), d = max(5, scale / 2)
        let bodyH = max(2, scale / 6)
        let cabinH = bodyH + max(2, scale / 6)
        let body = accent ?? .red
        return extrude(w: w, d: d, height: { x, _ in
            // Cabin raised over the middle third.
            (x > w / 4 && x < 3 * w / 4) ? cabinH : bodyH
        }, colorAt: { x, y, z in
            if y < 1, (x < w / 5 || x > 4 * w / 5) { return .black } // wheels
            if y >= bodyH {
                // Windows around the cabin sides/front.
                if z == 0 || z == d - 1 || x == w / 4 + 1 || x == 3 * w / 4 - 1 {
                    return .lightBlue
                }
            }
            return body
        })
    }

    private static let rocketTemplate = Template(
        name: "Rocket",
        keywords: ["rocket", "spaceship", "ship", "shuttle", "spacecraft", "missile", "ufo"]
    ) { scale, accent in
        let w = max(7, scale / 2), d = w
        let cx = w / 2, cz = d / 2
        let body = accent ?? .white
        let bodyH = scale
        let radius = Double(w) / 2.0
        return extrude(w: w, d: d, height: { x, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            if r > radius { // fins at the base corners
                return (x == 0 || x == w - 1 || z == 0 || z == d - 1) ? bodyH / 4 : 0
            }
            // Nose cone: taller near the centre.
            let cone = Int((radius - r) * 2.0)
            return bodyH + cone
        }, colorAt: { x, y, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            if r > radius { return .red }               // fins
            if y >= bodyH { return .red }               // nose cone
            if y >= bodyH / 2, y < bodyH / 2 + 2 { return .lightBlue } // window band
            return body
        })
    }

    private static let robotTemplate = Template(
        name: "Robot",
        keywords: ["robot", "mech", "android", "bot", "droid", "cyborg"]
    ) { scale, accent in
        let w = max(7, scale * 3 / 5), d = max(4, scale / 3)
        let body = accent ?? .blue
        let legH = scale / 3, bodyH = legH + scale / 3, headH = bodyH + scale / 4
        return extrude(w: w, d: d, height: { x, _ in
            let leftLeg = x < w / 3
            let rightLeg = x > 2 * w / 3
            if leftLeg || rightLeg { return legH }          // legs
            if x > w / 3 && x < 2 * w / 3 { return headH }  // torso + head column
            return bodyH
        }, colorAt: { x, y, z in
            if y >= bodyH {
                // Head with eyes.
                if y == bodyH + 1, z == 0, (x == w / 2 - 1 || x == w / 2 + 1) { return .yellow }
                return .gray
            }
            if y < legH, (x < w / 3 || x > 2 * w / 3) { return .darkGray } // legs
            return body
        })
    }

    private static let dogTemplate = Template(
        name: "Dog",
        keywords: ["dog", "puppy", "hound", "pup", "wolf"]
    ) { scale, accent in
        quadruped(scale: scale, color: accent ?? .brown, tall: false)
    }

    private static let catTemplate = Template(
        name: "Cat",
        keywords: ["cat", "kitten", "kitty", "feline", "lion", "tiger"]
    ) { scale, accent in
        quadruped(scale: scale, color: accent ?? .orange, tall: true)
    }

    /// Shared four-legged-animal body: a low body block, a raised head at the
    /// front, and four short legs — all ground-supported.
    private static func quadruped(scale: Int, color: LegoColor, tall: Bool) -> [Voxel] {
        let w = max(8, scale), d = max(4, scale / 3)
        let legH = max(2, scale / 6)
        let bodyH = legH + max(2, scale / 5)
        let headH = bodyH + (tall ? scale / 4 : scale / 6)
        return extrude(w: w, d: d, height: { x, z in
            let isLeg = (x < 2 || x == w - 2 || x == w - 3 || x == 1)
            if x >= w - 3 { return headH }        // head at the front
            if isLeg { return legH }
            if z == 0 || z == d - 1 { return bodyH }
            return bodyH
        }, colorAt: { x, y, z in
            if x >= w - 3, y == headH - 1, z == 0 { return .black } // nose/eye
            if y < legH { return color }
            return color
        })
    }

    private static let fishTemplate = Template(
        name: "Fish",
        keywords: ["fish", "shark", "whale", "dolphin", "goldfish", "carp"]
    ) { scale, accent in
        let w = max(10, scale), d = max(6, scale * 2 / 3)
        let cx = w * 2 / 5, cz = d / 2
        let body = accent ?? .orange
        let bodyRX = Double(w) * 0.35, bodyRZ = Double(d) * 0.4
        return flatRelief(w: w, d: d, thickness: max(2, scale / 8)) { x, z in
            let dx = Double(x - cx) / bodyRX, dz = Double(z - cz) / bodyRZ
            if dx * dx + dz * dz <= 1.0 {
                if x == cx + Int(bodyRX) - 1, z == cz - 1 { return .black } // eye
                return body
            }
            // Tail triangle at the back.
            let tailX = w - 1 - x
            if x > cx, tailX >= 0, abs(z - cz) <= tailX / 2, x > cx + Int(bodyRX) - 1 {
                return .red
            }
            return nil
        }
    }

    private static let birdTemplate = Template(
        name: "Bird",
        keywords: ["bird", "duck", "chicken", "parrot", "owl", "penguin", "eagle"]
    ) { scale, accent in
        let w = max(6, scale / 2), d = max(5, scale / 2)
        let cx = w / 2, cz = d / 2
        let body = accent ?? .yellow
        let bodyH = scale / 2, headH = bodyH + scale / 4
        return extrude(w: w, d: d, height: { x, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            if r > Double(min(w, d)) / 2.0 { return 0 }
            return (x >= cx) ? headH : bodyH  // head raised on one side
        }, colorAt: { x, y, z in
            if x >= cx, y == headH - 1, z == cz { return .orange } // beak
            if y < 1 { return .orange }                           // feet
            return body
        })
    }

    private static let flowerTemplate = Template(
        name: "Flower",
        keywords: ["flower", "rose", "tulip", "daisy", "blossom", "sunflower"]
    ) { scale, accent in
        let w = max(9, scale), d = max(9, scale)
        let cx = w / 2, cz = d / 2
        let petal = accent ?? .pink
        return flatRelief(w: w, d: d, thickness: max(2, scale / 8)) { x, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            if r < 1.5 { return .yellow }          // centre
            if r < Double(min(w, d)) / 2.0 - 0.5 { return petal } // petals
            // Stem running downward (in +Z from centre).
            if x == cx, z > cz { return .green }
            return nil
        }
    }

    private static let heartTemplate = Template(
        name: "Heart",
        keywords: ["heart", "love", "valentine"]
    ) { scale, accent in
        let w = max(9, scale), d = max(9, scale)
        let color = accent ?? .red
        return flatRelief(w: w, d: d, thickness: max(2, scale / 6)) { x, z in
            let fx = (Double(x) / Double(w - 1)) * 2.0 - 1.0
            let fz = 1.0 - (Double(z) / Double(d - 1)) * 2.0
            // Implicit heart curve.
            let a = fx * fx + fz * fz - 1.0
            return (a * a * a - fx * fx * fz * fz * fz) <= 0 ? color : nil
        }
    }

    private static let starTemplate = Template(
        name: "Star",
        keywords: ["star", "sheriff", "badge"]
    ) { scale, accent in
        let w = max(9, scale), d = max(9, scale)
        let cx = Double(w - 1) / 2.0, cz = Double(d - 1) / 2.0
        let color = accent ?? .yellow
        let outer = Double(min(w, d)) / 2.0
        let inner = outer * 0.45
        return flatRelief(w: w, d: d, thickness: max(2, scale / 6)) { x, z in
            let dx = Double(x) - cx, dz = Double(z) - cz
            let r = (dx * dx + dz * dz).squareRoot()
            var ang = atan2(dz, dx) + .pi / 2
            if ang < 0 { ang += 2 * .pi }
            let sector = (ang.truncatingRemainder(dividingBy: 2 * .pi / 5)) / (2 * .pi / 5)
            let edge = inner + (outer - inner) * (1 - abs(sector - 0.5) * 2)
            return r <= edge ? color : nil
        }
    }

    private static let snowmanTemplate = Template(
        name: "Snowman",
        keywords: ["snowman", "snow", "olaf"]
    ) { scale, accent in
        let w = max(7, scale / 2), d = w
        let cx = w / 2, cz = d / 2
        let radius = Double(w) / 2.0
        return extrude(w: w, d: d, height: { x, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            if r > radius { return 0 }
            // Stacked dome giving a rounded snowman silhouette.
            return Int((radius - r) * 2.5) + scale / 2
        }, colorAt: { x, y, z in
            if z == 0, y == scale * 3 / 4, abs(x - cx) <= 1 { return .black } // eyes
            if z == 0, y == scale * 2 / 3, x == cx { return .orange }         // nose
            return accent ?? .white
        })
    }

    private static let castleTemplate = Template(
        name: "Castle",
        keywords: ["castle", "fortress", "palace", "tower", "keep", "fort"]
    ) { scale, accent in
        let w = max(9, scale), d = max(9, scale)
        let wall = accent ?? .gray
        let wallH = max(4, scale / 2)
        let towerH = wallH + scale / 3
        return extrude(w: w, d: d, height: { x, z in
            let corner = (x < 2 || x > w - 3) && (z < 2 || z > d - 3)
            let edge = x == 0 || x == w - 1 || z == 0 || z == d - 1
            if corner { return towerH }     // corner towers
            if edge {
                // Crenellations along the top edge.
                return wallH + ((x + z) % 2 == 0 ? 1 : 0)
            }
            return 1                         // courtyard floor
        }, colorAt: { _, _, _ in wall })
    }

    private static let pyramidTemplate = Template(
        name: "Pyramid",
        keywords: ["pyramid", "egypt", "tomb"]
    ) { scale, accent in
        let w = max(9, scale), d = max(9, scale)
        let color = accent ?? .tan
        return extrude(w: w, d: d, height: { x, z in
            let step = min(min(x, w - 1 - x), min(z, d - 1 - z))
            return step + 1
        }, colorAt: { _, _, _ in color })
    }

    private static let mountainTemplate = Template(
        name: "Mountain",
        keywords: ["mountain", "hill", "volcano", "peak", "mount"]
    ) { scale, accent in
        let w = max(10, scale), d = max(10, scale)
        let cx = w / 2, cz = d / 2
        let base = accent ?? .darkGray
        let radius = Double(min(w, d)) / 2.0
        return extrude(w: w, d: d, height: { x, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            return max(0, Int((radius - r) * 1.8))
        }, colorAt: { x, y, z in
            let peak = Int(Double(scale) * 0.9)
            return y > peak ? .white : base   // snow cap
        })
    }

    private static let boatTemplate = Template(
        name: "Boat",
        keywords: ["boat", "sailboat", "canoe", "yacht", "raft"]
    ) { scale, accent in
        let w = max(10, scale), d = max(5, scale / 2)
        let hull = accent ?? .red
        let hullH = max(2, scale / 5)
        let mastX = w / 2
        return extrude(w: w, d: d, height: { x, z in
            // Tapered hull (pointed bow/stern), tall mast in the centre.
            let taper = min(x, w - 1 - x)
            if x == mastX, z == d / 2 { return scale }        // mast
            return (taper >= 1) ? hullH : 0
        }, colorAt: { x, y, z in
            if x == mastX, z == d / 2 { return (y > hullH) ? .brown : hull } // mast
            if y >= hullH - 1 { return .white }                             // deck
            return hull
        })
    }

    private static let planeTemplate = Template(
        name: "Airplane",
        keywords: ["plane", "airplane", "jet", "aircraft", "flight", "aeroplane"]
    ) { scale, accent in
        let w = max(11, scale), d = max(9, scale)
        let cx = w / 2, cz = d / 2
        let body = accent ?? .white
        let fuseH = max(2, scale / 6)
        return extrude(w: w, d: d, height: { x, z in
            let onFuselage = z >= cz - 1 && z <= cz + 1          // body along X
            let onWings = x >= cx - 1 && x <= cx + 1             // wings along Z
            let tail = x < 2 && abs(z - cz) <= 2
            if onFuselage || onWings || tail { return fuseH }
            return 0
        }, colorAt: { x, y, z in
            if z >= cz - 1, z <= cz + 1, x > w - 4 { return .lightBlue } // cockpit
            return body
        })
    }

    /// Honest fallback for subjects with no dedicated template: a rounded,
    /// pedestal-mounted brick bust. Still a real, buildable model.
    private static let fallback = Template(
        name: "Brick Sculpture",
        keywords: []
    ) { scale, accent in
        let w = max(8, scale * 3 / 4), d = w
        let cx = w / 2, cz = d / 2
        let color = accent ?? .lightBlue
        let radius = Double(w) / 2.0
        return extrude(w: w, d: d, height: { x, z in
            let dx = Double(x - cx), dz = Double(z - cz)
            let r = (dx * dx + dz * dz).squareRoot()
            if r > radius { return 0 }
            return Int((radius - r) * 1.6) + scale / 3   // rounded dome
        }, colorAt: { x, y, z in
            if y < 1 { return .darkGray }                // pedestal base
            return color
        })
    }
}
