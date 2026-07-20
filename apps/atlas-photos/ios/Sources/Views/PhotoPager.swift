import SwiftUI
import UIKit

/// UIPageViewController-backed pager for the photo viewer.
///
/// Replaces SwiftUI's `TabView(.page)`, which could settle BETWEEN two pages
/// (half of each visible) when its gesture fought the zoom scroll views.
/// UIPageViewController physically cannot rest between pages and advances
/// EXACTLY one page per swipe — rapid successive swipes each move one page,
/// which is the Apple-/Google-Photos feel.
struct PhotoPager<Content: View>: UIViewControllerRepresentable {
    @Binding var index: Int
    let count: Int
    @ViewBuilder let content: (Int) -> Content

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 10]
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .clear
        pager.setViewControllers([context.coordinator.page(at: index)],
                                 direction: .forward, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // never touch the pager mid-swipe (interactive transition in flight)
        if context.coordinator.transitioning { return }
        // Re-render the visible page on every SwiftUI update — video pages
        // depend on the parent's `chrome` state for their own controls.
        if let cur = pager.viewControllers?.first as? Coordinator.Page,
           cur.pageIndex == index {
            cur.rootView = AnyView(content(index))
        }
        // External jump (e.g. filmstrip tap): animate in the right direction.
        let current = context.coordinator.currentIndex(of: pager)
        if let current, current != index {
            let dir: UIPageViewController.NavigationDirection =
                index > current ? .forward : .reverse
            // external jumps (filmstrip scrub/tap) swap INSTANTLY — any
            // animation here lags behind the wheel; the pager's own swipe
            // gesture still animates natively
            pager.setViewControllers([context.coordinator.page(at: index)],
                                     direction: dir, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PhotoPager
        /// true while an interactive swipe/transition is in flight — external
        /// setViewControllers during that window would crash UIPageViewController
        var transitioning = false

        init(_ parent: PhotoPager) { self.parent = parent }

        /// Hosting controller tagged with its page index.
        final class Page: UIHostingController<AnyView> {
            var pageIndex = 0
        }

        func page(at i: Int) -> Page {
            let p = Page(rootView: AnyView(parent.content(i)))
            p.pageIndex = i
            p.view.backgroundColor = .clear
            // pages must fill the ENTIRE screen: without this the hosting
            // controller insets its SwiftUI content by the safe areas and the
            // photo can never extend behind notch/home bar (black bars even
            // when fully zoomed in)
            p.safeAreaRegions = []
            return p
        }

        func currentIndex(of pager: UIPageViewController) -> Int? {
            (pager.viewControllers?.first as? Page)?.pageIndex
        }

        func pageViewController(_ p: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? Page)?.pageIndex, i > 0 else { return nil }
            return page(at: i - 1)
        }

        func pageViewController(_ p: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? Page)?.pageIndex, i < parent.count - 1 else { return nil }
            return page(at: i + 1)
        }

        /// Fires the moment a swipe STARTS — the filmstrip below follows the
        /// finger immediately instead of waiting for the page animation to end.
        func pageViewController(_ p: UIPageViewController,
                                willTransitionTo pending: [UIViewController]) {
            transitioning = true
            if let i = (pending.first as? Page)?.pageIndex, parent.index != i {
                parent.index = i
            }
        }

        func pageViewController(_ p: UIPageViewController, didFinishAnimating _: Bool,
                                previousViewControllers _: [UIViewController],
                                transitionCompleted completed: Bool) {
            transitioning = false
            // completed OR cancelled: sync to whatever is actually visible
            // (a cancelled swipe reverts the eager index from willTransitionTo)
            guard let i = currentIndex(of: p) else { return }
            if parent.index != i { parent.index = i }
        }
    }
}
