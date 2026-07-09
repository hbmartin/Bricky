import SceneKit
import SwiftUI
import UIKit

/// A rotatable 3D preview of a generated brick model, built from its
/// `PlacedBrick` list. Each brick becomes a coloured `SCNBox` sitting on stud
/// spacing (20 LDU) with brick height (24 LDU). Offline; no assets required.
struct BrickModelSceneView: UIViewRepresentable {
    let bricks: [PlacedBrick]
    /// When > 0, the last `highlightCount` bricks are drawn solid while the
    /// earlier bricks are ghosted, so a build step shows exactly what's new.
    var highlightCount: Int = 0
    /// Whether the user can orbit/zoom the model. Disable for tiny thumbnails.
    var interactive: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.buildScene(from: bricks, highlightCount: highlightCount)
        view.allowsCameraControl = interactive
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = .clear
        view.defaultCameraController.interactionMode = .orbitTurntable
        context.coordinator.signature = Self.signature(bricks, highlightCount)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.allowsCameraControl = interactive
        // Only rebuild the scene when the model actually changes — otherwise a
        // routine SwiftUI update would rebuild it and snap the camera back,
        // making the model feel like it can't be rotated or zoomed.
        let sig = Self.signature(bricks, highlightCount)
        guard sig != context.coordinator.signature else { return }
        context.coordinator.signature = sig
        view.scene = Self.buildScene(from: bricks, highlightCount: highlightCount)
    }

    /// Retains per-view state across SwiftUI updates so the built scene (and the
    /// user's camera position) survives re-renders.
    final class Coordinator {
        var signature: Int = 0
    }

    /// A cheap fingerprint of the inputs, so we rebuild only on real changes.
    private static func signature(_ bricks: [PlacedBrick], _ highlightCount: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(bricks.count)
        hasher.combine(highlightCount)
        if let f = bricks.first { hasher.combine(f.x); hasher.combine(f.y); hasher.combine(f.z); hasher.combine(f.color) }
        if let l = bricks.last { hasher.combine(l.x); hasher.combine(l.y); hasher.combine(l.z); hasher.combine(l.color) }
        return hasher.finalize()
    }

    // MARK: - Scene construction

    private static func buildScene(from bricks: [PlacedBrick], highlightCount: Int = 0) -> SCNScene {
        let scene = SCNScene()

        let stud: CGFloat = 20
        let layer: CGFloat = 24
        let firstNew = highlightCount > 0 ? bricks.count - highlightCount : bricks.count

        // Compute bounds to centre the model at the origin.
        let maxX = bricks.map { $0.x + $0.length }.max() ?? 1
        let maxY = (bricks.map(\.y).max() ?? 0) + 1
        let maxZ = (bricks.map(\.z).max() ?? 0) + 1
        let centreX = CGFloat(maxX) * stud / 2
        let centreY = CGFloat(maxY) * layer / 2
        let centreZ = CGFloat(maxZ) * stud / 2

        // One node per unique colour, merged as a parent for lighter scenes on
        // large models; individual boxes keep it simple and correct.
        let container = SCNNode()
        for (index, brick) in bricks.enumerated() {
            let box = SCNBox(
                width: CGFloat(brick.length) * stud,
                height: layer,
                length: stud,
                chamferRadius: 1.5
            )
            let isNew = index >= firstNew
            let material = SCNMaterial()
            material.diffuse.contents = uiColor(for: brick.color)
            material.roughness.contents = 0.55
            if highlightCount > 0 {
                if isNew {
                    // New bricks pop with a subtle glow.
                    material.emission.contents = uiColor(for: brick.color)
                    material.emission.intensity = 0.35
                } else {
                    // Already-built bricks are ghosted so the new work stands out.
                    material.transparency = 0.28
                }
            }
            box.materials = [material]

            let node = SCNNode(geometry: box)
            let bx = (CGFloat(brick.x) + CGFloat(brick.length) / 2) * stud - centreX
            let by = (CGFloat(brick.y) + 0.5) * layer - centreY
            let bz = (CGFloat(brick.z) + 0.5) * stud - centreZ
            node.position = SCNVector3(bx, by, bz)
            container.addChildNode(node)
        }
        // Flatten into a single node per material so large models (thousands of
        // bricks) still render at interactive frame rates.
        scene.rootNode.addChildNode(container.flattenedClone())

        // Frame the model with a camera pulled back proportional to its size.
        let camera = SCNCamera()
        camera.zFar = 100_000
        let camNode = SCNNode()
        camNode.camera = camera
        let span = CGFloat(max(maxX, max(maxY, maxZ)))
        let dist = span * stud * 1.9 + 120
        camNode.position = SCNVector3(dist * 0.7, dist * 0.6, dist * 0.9)
        camNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camNode)

        return scene
    }

    private static func uiColor(for color: LegoColor) -> UIColor {
        let hex = color.hex
        return UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
