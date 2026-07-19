import SwiftUI
import SceneKit

/// A 3D, audio-reactive club scene: a neon ring of bars around a pulsing core,
/// driven every frame by the live FFT bands from ShowAudio.
struct VisualizerView: UIViewRepresentable {
    var buffer: BandBuffer
    var bandCount: Int

    func makeCoordinator() -> Coordinator { Coordinator(buffer: buffer) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        view.isUserInteractionEnabled = true
        view.allowsCameraControl = false
        let scene = context.coordinator.build(bandCount: bandCount)
        view.scene = scene
        view.delegate = context.coordinator
        view.rendersContinuously = true
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private let buffer: BandBuffer
        private var bars: [SCNNode] = []
        private var smooth: [Float] = []
        private var core = SCNNode()
        private var rig = SCNNode()
        private var camera = SCNNode()
        private var hue: CGFloat = 0.58

        init(buffer: BandBuffer) { self.buffer = buffer }

        func build(bandCount: Int) -> SCNScene {
            let scene = SCNScene()
            smooth = [Float](repeating: 0, count: bandCount)

            // camera with HDR bloom for the neon glow
            let cam = SCNCamera()
            cam.wantsHDR = true
            cam.bloomIntensity = 1.5
            cam.bloomThreshold = 0.4
            cam.bloomBlurRadius = 16
            cam.wantsExposureAdaptation = false
            camera.camera = cam
            camera.position = SCNVector3(0, 6.5, 15)
            camera.eulerAngles.x = -0.32
            scene.rootNode.addChildNode(camera)

            // faint fill light
            let amb = SCNNode()
            amb.light = SCNLight()
            amb.light?.type = .ambient
            amb.light?.intensity = 120
            amb.light?.color = UIColor(white: 0.25, alpha: 1)
            scene.rootNode.addChildNode(amb)

            // reflective floor
            let floor = SCNNode()
            let fg = SCNFloor()
            fg.reflectivity = 0.22
            let fm = SCNMaterial()
            fm.diffuse.contents = UIColor(white: 0.02, alpha: 1)
            fg.materials = [fm]
            floor.geometry = fg
            scene.rootNode.addChildNode(floor)

            // ring of bars
            scene.rootNode.addChildNode(rig)
            let radius: Float = 6.5
            for i in 0..<bandCount {
                let angle = Float(i) / Float(bandCount) * 2 * .pi
                let box = SCNBox(width: 0.7, height: 1, length: 0.7, chamferRadius: 0.08)
                let m = SCNMaterial()
                m.lightingModel = .physicallyBased
                m.emission.contents = UIColor(hue: hue, saturation: 0.9, brightness: 1, alpha: 1)
                m.diffuse.contents = UIColor.black
                box.materials = [m]
                let node = SCNNode(geometry: box)
                node.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0) // grow upward
                node.position = SCNVector3(cosf(angle) * radius, 0, sinf(angle) * radius)
                rig.addChildNode(node)
                bars.append(node)
            }

            // glowing core
            let sphere = SCNSphere(radius: 1.6)
            let cm = SCNMaterial()
            cm.emission.contents = UIColor(hue: hue, saturation: 0.7, brightness: 1, alpha: 1)
            cm.diffuse.contents = UIColor.black
            sphere.materials = [cm]
            core.geometry = sphere
            core.position = SCNVector3(0, 1.6, 0)
            scene.rootNode.addChildNode(core)

            return scene
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let bands = buffer.bands()
            let level = buffer.level()
            guard !bars.isEmpty else { return }

            hue += 0.0009
            if hue > 1 { hue -= 1 }

            for (i, node) in bars.enumerated() {
                let target = i < bands.count ? bands[i] : 0
                // smooth attack/decay
                smooth[i] += (target - smooth[i]) * (target > smooth[i] ? 0.5 : 0.12)
                let h = 0.2 + smooth[i] * 7
                node.scale = SCNVector3(1, h, 1)
                let barHue = (hue + CGFloat(i) / CGFloat(bars.count) * 0.4).truncatingRemainder(dividingBy: 1)
                node.geometry?.firstMaterial?.emission.contents =
                    UIColor(hue: barHue, saturation: 0.9, brightness: CGFloat(0.35 + smooth[i]), alpha: 1)
            }

            let s = CGFloat(1 + level * 1.4)
            core.scale = SCNVector3(s, s, s)
            core.geometry?.firstMaterial?.emission.contents =
                UIColor(hue: hue, saturation: 0.6, brightness: CGFloat(0.5 + level), alpha: 1)

            rig.eulerAngles.y = Float(time * 0.25)
            core.eulerAngles.y = Float(time * 0.6)
        }
    }
}
