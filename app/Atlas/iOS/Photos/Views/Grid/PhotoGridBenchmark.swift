import UIKit

#if targetEnvironment(simulator)
/// Drives the grid from the environment, in the simulator only:
/// ATLAS_BENCH=<points per second> flings the grid upwards for 10 s after
/// launch and prints frame statistics (main-thread time per frame);
/// ATLAS_DEMO=open | open-close | open-twice | select drives the grid for
/// screenshots.
@MainActor
final class PhotoGridBenchmark: NSObject {
    private weak var grid: PhotoGridController?
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frames: [Double] = []
    private var speed: CGFloat = 0

    init(grid: PhotoGridController) {
        self.grid = grid
    }

    /// Nil unless the environment asks for a run.
    static func startIfAsked(_ grid: PhotoGridController) -> PhotoGridBenchmark? {
        let env = ProcessInfo.processInfo.environment
        guard env["ATLAS_DEMO"] != nil || env["ATLAS_BENCH"] != nil else { return nil }
        let bench = PhotoGridBenchmark(grid: grid)
        bench.run()
        return bench
    }

    private func run() {
        if let demo = ProcessInfo.processInfo.environment["ATLAS_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let grid = self?.grid, grid.assets.count > 10 else { return }
                switch demo {
                case "select":
                    for (n, cell) in grid.collectionView.visibleCells.enumerated() {
                        (cell as? PhotoCell)?.setSelection(selecting: true, picked: n % 3 == 0, animated: true, entering: true)
                    }
                default:
                    let t0 = CACurrentMediaTime()
                    // ATLAS_OPEN=<asset id> opens that photo (screenshot comparisons)
                    let want = ProcessInfo.processInfo.environment["ATLAS_OPEN"]
                    grid.open(grid.assets.first { $0.id == want } ?? grid.assets[grid.assets.count - 3])
                    print(String(format: "ATLAS_BENCH open: present() returned after %.1f ms", (CACurrentMediaTime() - t0) * 1000))
                    DispatchQueue.main.async {
                        print(String(format: "ATLAS_BENCH open: first runloop turn after %.1f ms", (CACurrentMediaTime() - t0) * 1000))
                    }
                    grid.transitionCoordinator?.animate(alongsideTransition: nil) { _ in
                        print(String(format: "ATLAS_BENCH open: transition finished after %.1f ms", (CACurrentMediaTime() - t0) * 1000))
                    }
                    if demo == "open-close" || demo == "open-twice" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { grid.dismiss(animated: true) }
                    }
                    if demo == "open-twice" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                            let t1 = CACurrentMediaTime()
                            grid.open(grid.assets[grid.assets.count - 40])
                            DispatchQueue.main.async {
                                print(String(format: "ATLAS_BENCH open again: first runloop turn after %.1f ms", (CACurrentMediaTime() - t1) * 1000))
                            }
                        }
                    }
                }
            }
        }
        guard let v = ProcessInfo.processInfo.environment["ATLAS_BENCH"], let speed = Double(v) else { return }
        self.speed = CGFloat(speed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let grid else { link.invalidate(); return }
        let collectionView = grid.collectionView!
        let now = CACurrentMediaTime()
        if start == 0 { start = now; last = now; return }
        frames.append((now - last) * 1000)
        let dt = CGFloat(now - last)
        last = now
        let y = max(collectionView.contentOffset.y - speed * dt, -collectionView.adjustedContentInset.top)
        collectionView.contentOffset.y = y
        if now - start > 10 {
            link.invalidate()
            let sorted = frames.sorted()
            let p = { (q: Double) in sorted[min(Int(Double(sorted.count) * q), sorted.count - 1)] }
            // the simulator's display runs at 60 Hz: a frame over 1.5 × 16.7 ms is a drop
            let budget = 25.0
            print(String(format: "ATLAS_BENCH speed=%.0f frames=%d mean=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f dropped=%d rows=%.0f",
                         Double(speed), sorted.count, sorted.reduce(0, +) / Double(sorted.count),
                         p(0.5), p(0.95), p(0.99), sorted.last ?? 0, sorted.filter { $0 > budget }.count,
                         Double(speed) * 10 / Double(grid.layout.pitch)))
            print("ATLAS_BENCH cells=\(PhotoCell.shown) shownBlank=\(PhotoCell.blank)")
        }
    }
}
#endif
