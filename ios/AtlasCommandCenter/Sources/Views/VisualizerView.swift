import SwiftUI
import SceneKit

/// Minimalist audio visualizer: a single ring of thin monochrome bars on
/// black, breathing with the music. No floor, no core, no color cycling —
/// just clean white light with a whisper of accent on the bass.
struct VisualizerView: UIViewRepresentable {
    var buffer: BandBuffer
    var bandCount: Int

    func makeCoordinator() -> Coordinator { Coordinator(buffer: buffer) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.scene = context.coordinator.build()
        view.delegate = context.coordinator
        view.rendersContinuously = true
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private static let bars = 72          // thin spokes, visually one ring
        private let buffer: BandBuffer
        private var nodes: [SCNNode] = []
        private var smooth = [Float](repeating: 0, count: bars)
        private var level: Float = 0
        private var rig = SCNNode()

        init(buffer: BandBuffer) { self.buffer = buffer }

        func build() -> SCNScene {
            let scene = SCNScene()

            let cam = SCNCamera()
            cam.wantsHDR = true
            cam.bloomIntensity = 0.45          // just a whisper of glow
            cam.bloomThreshold = 0.6
            cam.bloomBlurRadius = 8
            cam.wantsExposureAdaptation = false
            let camera = SCNNode()
            camera.camera = cam
            camera.position = SCNVector3(0, 0, 16)
            scene.rootNode.addChildNode(camera)

            scene.rootNode.addChildNode(rig)
            let radius: Float = 5.6
            for i in 0..<Self.bars {
                let angle = Float(i) / Float(Self.bars) * 2 * .pi
                let bar = SCNBox(width: 0.05, height: 0.6, length: 0.05, chamferRadius: 0.02)
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.emission.contents = UIColor(white: 0.85, alpha: 1)
                m.diffuse.contents = UIColor.black
                bar.materials = [m]
                let node = SCNNode(geometry: bar)
                // bars sit ON the ring, growing outward from it
                node.position = SCNVector3(cosf(angle) * radius, sinf(angle) * radius, 0)
                node.eulerAngles.z = angle - .pi / 2
                node.pivot = SCNMatrix4MakeTranslation(0, -0.3, 0)
                rig.addChildNode(node)
                nodes.append(node)
            }
            return scene
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let bands = buffer.bands()
            let target = buffer.level()
            level += (target - level) * (target > level ? 0.4 : 0.08)
            guard !nodes.isEmpty, !bands.isEmpty else { return }

            for (i, node) in nodes.enumerated() {
                // map the few FFT bands smoothly around the ring, mirrored so
                // lows sit at the bottom and the ring stays symmetric
                let f = Float(i) / Float(Self.bars)
                let pos = (f <= 0.5 ? f * 2 : (1 - f) * 2) * Float(bands.count - 1)
                let lo = Int(pos)
                let hi = min(lo + 1, bands.count - 1)
                let t = pos - Float(lo)
                let v = bands[lo] * (1 - t) + bands[hi] * t
                smooth[i] += (v - smooth[i]) * (v > smooth[i] ? 0.5 : 0.10)

                node.scale = SCNVector3(1, 1 + smooth[i] * 9, 1)
                // white, tinted faintly toward the accent on strong hits
                let w = CGFloat(0.55 + smooth[i] * 0.45)
                node.geometry?.firstMaterial?.emission.contents = UIColor(
                    red: w * (0.75 + 0.25 * CGFloat(1 - smooth[i])),
                    green: w * (0.85 + 0.15 * CGFloat(1 - smooth[i])),
                    blue: w,
                    alpha: 1
                )
            }

            // the whole ring breathes very slightly with the level
            let s = 1 + CGFloat(level) * 0.06
            rig.scale = SCNVector3(s, s, s)
            rig.eulerAngles.z = Float(time * 0.05)   // barely-there rotation
        }
    }
}
