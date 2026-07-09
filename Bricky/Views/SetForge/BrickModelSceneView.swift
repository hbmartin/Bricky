import SceneKit
import SwiftUI
import UIKit

/// A rotatable 3D preview of a generated brick model, built from its
/// `PlacedBrick` list. Each brick becomes a coloured `SCNBox` sitting on stud
/// spacing (20 LDU) with brick height (24 LDU). Offline; no assets required.
struct BrickModelSceneView: UIViewRepresentable {
    let bricks: [PlacedBrick]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.buildScene(from: bricks)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = .clear
        view.defaultCameraController.interactionMode = .orbitTurntable
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.scene = Self.buildScene(from: bricks)
    }

    // MARK: - Scene construction

    private static func buildScene(from bricks: [PlacedBrick]) -> SCNScene {
        let scene = SCNScene()

        let stud: CGFloat = 20
        let layer: CGFloat = 24

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
        for brick in bricks {
            let box = SCNBox(
                width: CGFloat(brick.length) * stud,
                height: layer,
                length: stud,
                chamferRadius: 1.5
            )
            let material = SCNMaterial()
            material.diffuse.contents = uiColor(for: brick.color)
            material.roughness.contents = 0.55
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
