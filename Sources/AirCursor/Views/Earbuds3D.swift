import AppKit
import SceneKit
import SwiftUI

/// What the 3D earbuds are doing.
enum EarbudsState: Equatable {
    /// Gentle float and sway.
    case idle
    /// Looking for headphones: sonar pulses.
    case searching
    /// Headphone motion is live: the earbuds mirror your head.
    case live
}

/// Original, stylized 3D earbuds built from primitives (no Apple assets), lit with
/// physically based materials. When motion is live they follow your head in real time.
@MainActor
final class EarbudsScene {
    let scene = SCNScene()

    private let floatNode = SCNNode()
    private let swayNode = SCNNode()
    private let pairNode = SCNNode()
    private let pulseRoot = SCNNode()
    private var state: EarbudsState?
    private var baseline: (yaw: Double, pitch: Double)?

    init() {
        buildLighting()
        buildCamera()

        scene.rootNode.addChildNode(floatNode)
        floatNode.addChildNode(swayNode)
        swayNode.addChildNode(pairNode)
        scene.rootNode.addChildNode(pulseRoot)

        pairNode.addChildNode(makeEarbud(side: 1))
        pairNode.addChildNode(makeEarbud(side: -1))
        // A three-quarter view reads as "3D" immediately.
        pairNode.eulerAngles = SCNVector3(0.12, 0, 0)

        let up = SCNAction.moveBy(x: 0, y: 0.09, z: 0, duration: 1.8)
        up.timingMode = .easeInEaseOut
        floatNode.runAction(.repeatForever(.sequence([up, up.reversed()])))
    }

    // MARK: State

    func setState(_ newState: EarbudsState) {
        guard newState != state else { return }
        let previous = state
        state = newState

        pulseRoot.childNodes.forEach { $0.removeFromParentNode() }
        swayNode.removeAction(forKey: "sway")

        switch newState {
        case .idle:
            startSway()
        case .searching:
            startSway()
            startPulses(color: .controlAccentColor)
        case .live:
            baseline = nil
            celebrate(fromSearching: previous != .live)
        }
    }

    /// Mirrors the wearer's head. Angles in degrees, relative to when tracking began.
    func apply(_ live: LiveReadout, animated: Bool = true) {
        guard state == .live, live.hasData else { return }
        if baseline == nil { baseline = (live.yaw, live.pitch) }
        guard var base = baseline else { return }
        // Drift back to center over ~10 s so posture changes never leave the model askew.
        base.yaw += Self.wrap(live.yaw - base.yaw) * 0.01
        base.pitch += (live.pitch - base.pitch) * 0.01
        baseline = base

        let yaw = Self.clamp(Self.wrap(live.yaw - base.yaw), 70)
        let pitch = Self.clamp(live.pitch - base.pitch, 45)
        let roll = Self.clamp(live.relativeRoll, 40)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.12 : 0
        // Mirror view: you face the earbuds like a mirror.
        pairNode.eulerAngles = SCNVector3(
            CGFloat(0.12 - Self.rad(pitch)),
            CGFloat(Self.rad(yaw)),
            CGFloat(-Self.rad(roll))
        )
        SCNTransaction.commit()
    }

    func recenter() { baseline = nil }

    // MARK: Animations

    private func startSway() {
        let left = SCNAction.rotateTo(x: 0, y: 0.35, z: 0, duration: 2.6, usesShortestUnitArc: true)
        let right = SCNAction.rotateTo(x: 0, y: -0.35, z: 0, duration: 2.6, usesShortestUnitArc: true)
        left.timingMode = .easeInEaseOut
        right.timingMode = .easeInEaseOut
        swayNode.runAction(.repeatForever(.sequence([left, right])), forKey: "sway")
    }

    private func celebrate(fromSearching: Bool) {
        swayNode.runAction(.rotateTo(x: 0, y: 0, z: 0, duration: 0.4, usesShortestUnitArc: true))
        guard fromSearching else { return }

        // Spin into place with a small bounce, plus a single green "connected" ring.
        let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.9)
        spin.timingMode = .easeOut
        swayNode.runAction(spin)

        let grow = SCNAction.scale(to: 1.12, duration: 0.18)
        grow.timingMode = .easeOut
        let settle = SCNAction.scale(to: 1.0, duration: 0.35)
        settle.timingMode = .easeInEaseOut
        floatNode.runAction(.sequence([grow, settle]))

        let ring = makeRing(color: .systemGreen)
        pulseRoot.addChildNode(ring)
        ring.scale = SCNVector3(0.6, 0.6, 0.6)
        ring.opacity = 0.9
        let expand = SCNAction.group([.scale(to: 2.0, duration: 0.9), .fadeOut(duration: 0.9)])
        expand.timingMode = .easeOut
        ring.runAction(.sequence([expand, .removeFromParentNode()]))
    }

    private func startPulses(color: NSColor) {
        for i in 0..<3 {
            let ring = makeRing(color: color)
            ring.opacity = 0
            pulseRoot.addChildNode(ring)
            let reset = SCNAction.run { node in
                node.scale = SCNVector3(0.55, 0.55, 0.55)
                node.opacity = 0.8
            }
            let expand = SCNAction.group([.scale(to: 1.9, duration: 2.1), .fadeOut(duration: 2.1)])
            expand.timingMode = .easeOut
            ring.runAction(.sequence([
                .wait(duration: Double(i) * 0.7),
                .repeatForever(.sequence([reset, expand])),
            ]))
        }
    }

    private func makeRing(color: NSColor) -> SCNNode {
        let torus = SCNTorus(ringRadius: 1.5, pipeRadius: 0.012)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.writesToDepthBuffer = false
        torus.materials = [m]
        let node = SCNNode(geometry: torus)
        node.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        node.position = SCNVector3(0, -0.25, -0.3)
        return node
    }

    // MARK: Geometry

    /// One earbud, positioned as worn. `side` is +1 for right, -1 for left.
    private func makeEarbud(side: CGFloat) -> SCNNode {
        let bud = SCNNode()
        bud.position = SCNVector3(0.95 * side, 0.25, 0)
        // Angle toward the camera so both shells and stems are visible.
        bud.eulerAngles = SCNVector3(0, -0.55 * side, 0.08 * side)

        // Shell
        let shell = SCNNode(geometry: SCNSphere(radius: 0.42))
        shell.geometry?.firstMaterial = Materials.gloss
        (shell.geometry as? SCNSphere)?.segmentCount = 96
        shell.scale = SCNVector3(0.88, 0.96, 1.06)
        bud.addChildNode(shell)

        // Silicone tip, pointing inward toward the ear canal
        let tipShape = SCNCapsule(capRadius: 0.2, height: 0.42)
        tipShape.firstMaterial = Materials.silicone
        let tip = SCNNode(geometry: tipShape)
        tip.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        tip.position = SCNVector3(-0.36 * side, 0.02, 0.04)
        tip.scale = SCNVector3(1, 0.75, 1)
        bud.addChildNode(tip)

        // Mesh grille on the outer face
        let grilleShape = SCNCylinder(radius: 0.085, height: 0.02)
        grilleShape.firstMaterial = Materials.mesh
        let grille = SCNNode(geometry: grilleShape)
        grille.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        grille.position = SCNVector3(0.36 * side, 0.12, 0.16)
        bud.addChildNode(grille)

        // Stem
        let stemShape = SCNCapsule(capRadius: 0.105, height: 1.0)
        stemShape.firstMaterial = Materials.gloss
        stemShape.radialSegmentCount = 64
        let stem = SCNNode(geometry: stemShape)
        stem.position = SCNVector3(0.06 * side, -0.62, 0.16)
        stem.eulerAngles = SCNVector3(0.18, 0, -0.1 * side)
        bud.addChildNode(stem)

        // Metallic stem tip (the microphone)
        let capShape = SCNCylinder(radius: 0.098, height: 0.06)
        capShape.firstMaterial = Materials.metal
        let cap = SCNNode(geometry: capShape)
        cap.position = SCNVector3(0, -0.47, 0)
        stem.addChildNode(cap)

        // Force-sensor groove on the stem
        let grooveShape = SCNBox(width: 0.02, height: 0.22, length: 0.012, chamferRadius: 0.006)
        grooveShape.firstMaterial = Materials.groove
        let groove = SCNNode(geometry: grooveShape)
        groove.position = SCNVector3(0.07 * side, 0.08, 0.075)
        stem.addChildNode(groove)

        return bud
    }

    // MARK: Lighting & camera

    private func buildLighting() {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.6

        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        key.castsShadow = false
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.7, 0.5, 0)
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 500
        rim.color = NSColor(calibratedRed: 0.75, green: 0.8, blue: 1, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(0.3, .pi * 0.9, 0)
        scene.rootNode.addChildNode(rimNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 120
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    private func buildCamera() {
        let camera = SCNCamera()
        // Fit by width so the pair is fully visible in tall, narrow panels.
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 33
        camera.wantsHDR = true
        camera.bloomIntensity = 0.25
        camera.bloomThreshold = 0.9
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, -0.15, 6.3)
        scene.rootNode.addChildNode(node)
    }

    /// Procedural studio reflection map: bright softbox above, dark floor below.
    private static func studioEnvironment() -> NSImage {
        let size = NSSize(width: 512, height: 256)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colorsAndLocations:
                (NSColor(white: 0.18, alpha: 1), 0.0),
                (NSColor(white: 0.45, alpha: 1), 0.45),
                (NSColor(white: 1.0, alpha: 1), 0.62),
                (NSColor(white: 0.85, alpha: 1), 1.0)
            )?.draw(in: rect, angle: 90)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 150, y: 190, width: 210, height: 40), xRadius: 20, yRadius: 20).fill()
            return true
        }
    }

    private enum Materials {
        static let gloss = make(white: 0.97, roughness: 0.18, clearCoat: 0.8)
        static let silicone = make(white: 0.9, roughness: 0.75, clearCoat: 0)
        static let mesh = make(white: 0.08, roughness: 0.6, clearCoat: 0)
        static let groove = make(white: 0.82, roughness: 0.35, clearCoat: 0)
        static let metal: SCNMaterial = {
            let m = make(white: 0.78, roughness: 0.28, clearCoat: 0)
            m.metalness.contents = 1.0
            return m
        }()

        static func make(white: CGFloat, roughness: CGFloat, clearCoat: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(white: white, alpha: 1)
            m.roughness.contents = roughness
            m.metalness.contents = 0.0
            m.clearCoat.contents = clearCoat
            m.clearCoatRoughness.contents = 0.08
            return m
        }
    }

    private static func rad(_ deg: Double) -> Double { deg * .pi / 180 }
    private static func clamp(_ v: Double, _ limit: Double) -> Double { min(max(v, -limit), limit) }
    private static func wrap(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}

struct Earbuds3DView: NSViewRepresentable {
    var state: EarbudsState
    var live: LiveReadout

    func makeCoordinator() -> EarbudsScene { EarbudsScene() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.allowsCameraControl = false
        context.coordinator.setState(state)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.setState(state)
        context.coordinator.apply(live)
    }
}
