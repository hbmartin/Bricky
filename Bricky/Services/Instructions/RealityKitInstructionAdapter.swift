import RealityKit
import SwiftUI

@MainActor
enum RealityKitInstructionAdapter {
    static func makeEntity(
        from snapshot: InstructionGeometrySnapshot,
        highlightedColors: Set<Int> = [],
        dimmed: Bool = false
    ) throws -> Entity {
        let root = Entity()
        for buffer in snapshot.buffers where !buffer.positions.isEmpty {
            var descriptor = MeshDescriptor(name: "ldraw-\(buffer.colorCode)")
            descriptor.positions = MeshBuffers.Positions(buffer.positions)
            descriptor.normals = MeshBuffers.Normals(buffer.normals)
            descriptor.primitives = .triangles(buffer.indices)
            let mesh = try MeshResource.generate(from: [descriptor])
            root.addChild(ModelEntity(
                mesh: mesh,
                materials: [material(
                    for: buffer.colorCode,
                    dimmed: dimmed && !highlightedColors.contains(buffer.colorCode)
                )]
            ))
        }
        return root
    }

    /// Authored transparency and the dim treatment compose multiplicatively so
    /// a dimmed trans-clear part stays fainter than a dimmed opaque one.
    private static func material(for colorCode: Int, dimmed: Bool) -> SimpleMaterial {
        let base = LDrawPalette.color(colorCode)
        let definition = LDrawPalette.definition(colorCode)
        let authoredAlpha = CGFloat(definition?.alpha ?? 255) / 255
        let opacity = authoredAlpha * (dimmed ? 0.28 : 1)
        let isMetallic: Bool
        let roughness: Float
        switch definition?.finish {
        case .chrome, .metal:
            isMetallic = true
            roughness = 0.12
        case .matteMetallic:
            isMetallic = true
            roughness = 0.45
        case .pearlescent:
            isMetallic = false
            roughness = 0.15
        case .rubber:
            isMetallic = false
            roughness = 0.85
        case .plastic, .material, nil:
            isMetallic = false
            roughness = 0.28
        }
        return SimpleMaterial(
            color: base.withAlphaComponent(opacity),
            roughness: .init(floatLiteral: roughness),
            isMetallic: isMetallic
        )
    }
}

@MainActor
enum LDrawPalette {
    /// Direct colours (`0x2RRGGBB`) carry their RGB value in the low 24 bits;
    /// codes at or above this threshold bypass the palette lookup.
    private static let directColorThreshold = 0x2000000

    /// The full LDConfig palette, installed by `LDrawPartPackManager` once the
    /// part pack is ready. Until then the hardcoded fallback below serves the
    /// most common codes and everything else renders gray.
    private static var installed: [Int: LDrawColorDefinition] = [:]

    static func install(_ definitions: [Int: LDrawColorDefinition]) {
        installed = definitions
    }

    static func definition(_ code: Int) -> LDrawColorDefinition? {
        guard code < directColorThreshold else { return nil }
        return installed[code]
    }

    static func color(_ code: Int) -> UIColor {
        let rgb: UInt32 = code >= directColorThreshold
            ? UInt32(code & 0xFFFFFF)
            : installed[code]?.rgb ?? colors[code] ?? 0x8E8E93
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }

    private static let colors: [Int: UInt32] = [
        0: 0x05131D, 1: 0x0055BF, 2: 0x257A3E, 4: 0xC91A09,
        14: 0xF2CD37, 15: 0xFFFFFF, 19: 0xE4CD9E, 25: 0xFE8A18,
        27: 0xBBE90B, 33: 0x0020A0, 36: 0xC91A09, 47: 0xFCFCFC,
        70: 0x582A12, 71: 0xA0A5A9, 72: 0x6C6E68, 272: 0x0A3463,
        288: 0x184632, 320: 0x720E0F
    ]
}

/// iOS 17-compatible non-AR preview. `RealityView` is iOS 18+, while Bricky's
/// deployment contract remains iOS 17 on iPhone and iPad.
struct RealityKitModelPreview: UIViewRepresentable {
    let entity: Entity?

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.secondarySystemBackground)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        view.scene.anchors.removeAll()
        let anchor = AnchorEntity(world: .zero)
        if let entity {
            anchor.addChild(entity.clone(recursive: true))
        }

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 42
        camera.look(at: .zero, from: SIMD3<Float>(0.22, 0.18, 0.36), relativeTo: anchor)
        anchor.addChild(camera)

        let light = DirectionalLight()
        light.light.intensity = 2_500
        light.look(at: .zero, from: SIMD3<Float>(0.3, 0.5, 0.4), relativeTo: anchor)
        anchor.addChild(light)
        view.scene.addAnchor(anchor)
    }
}
