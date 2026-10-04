import Foundation
import os

/// The one download queue for media. Every fetch of a thumbnail, preview,
/// original, face crop or video head goes through here, so the app never
/// downloads the same file twice at once and what is on screen always goes
/// first:
///   • `visible`: on screen now; starts at once, even over the usual limit.
///   • `near`: about to be on screen (the viewer's neighbours, video heads).
///   • `background`: the thumbnail fill and the cache warmer. Never over
///     cellular or Low Data Mode, never more than a few at a time, and not
///     at all while the user scrolls or swipes.
/// Requests for the same file share one job; a job whose every requester
/// cancelled is cancelled too (before it starts, or mid-download).
final class MediaFetch: @unchecked Sendable {
    static let shared = MediaFetch()

    enum Priority: Int, Comparable, Sendable {
        case background, near, visible
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    /// Downloads land in `MediaStore`, so there is no URL cache.
    let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    private static let maxRunning = 8
    /// Visible work may go this far over `maxRunning`.
    private static let maxVisible = 12
    private static let maxBackground = 6

    typealias Done = @Sendable (Error?) -> Void

    private final class Job {
        let key: String
        let seq: Int
        var priority: Priority
        let work: @Sendable (Priority) async throws -> Void
        var waiters: [Int: (priority: Priority, done: Done)] = [:]
        var task: Task<Void, Never>?
        var startedAs: Priority?
        var cancelled = false
        init(key: String, seq: Int, priority: Priority, work: @escaping @Sendable (Priority) async throws -> Void) {
            self.key = key; self.seq = seq; self.priority = priority; self.work = work
        }
    }

    /// One requester's interest in a job.
    final class Ticket: @unchecked Sendable {
        fileprivate let key: String
        fileprivate let token: Int
        fileprivate init(key: String, token: Int) { self.key = key; self.token = token }
        func cancel() { MediaFetch.shared.cancel(self) }
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var running = 0
    private var runningBackground = 0
    private var seq = 0
    private var nextToken = 0
    private var interacting = false
    private var calmSince = Date.distantPast
    let log = Logger(subsystem: "com.lukaloehr.atlas", category: "MediaFetch")

    // MARK: Interaction

    /// The user is scrolling the grid or swiping the viewer: background
    /// work does not start meanwhile (what runs finishes).
    func setInteracting(_ on: Bool) {
        lock.withLock {
            interacting = on
            if !on { calmSince = Date() }
        }
        if !on {
            // a moment of calm before the background work comes back
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) { [self] in pump() }
        }
    }

    /// Seconds since the last scroll or swipe ended (0 while one goes on).
    var calm: TimeInterval {
        lock.withLock { interacting ? 0 : Date().timeIntervalSince(calmSince) }
    }

    // MARK: Jobs

    /// Runs `work` once for everyone who asks for `key` until it finishes.
    /// `done` runs on a background thread (or on the caller's, with a
    /// CancellationError, when the ticket is cancelled first).
    func enqueue(_ key: String, priority: Priority,
                 work: @escaping @Sendable (Priority) async throws -> Void,
                 done: @escaping Done) -> Ticket {
        let ticket: Ticket = lock.withLock {
            nextToken += 1
            let token = nextToken
            if let job = jobs[key], !job.cancelled {
                job.waiters[token] = (priority, done)
                if job.task == nil, priority > job.priority { job.priority = priority }
            } else {
                seq += 1
                let job = Job(key: key, seq: seq, priority: priority, work: work)
                job.waiters[token] = (priority, done)
                jobs[key] = job
            }
            return Ticket(key: key, token: token)
        }
        pump()
        return ticket
    }

    /// `enqueue` for async callers; cancelling the calling task cancels the
    /// request.
    func run(_ key: String, priority: Priority,
             work: @escaping @Sendable (Priority) async throws -> Void) async throws {
        let holder = TicketHolder()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let ticket = enqueue(key, priority: priority, work: work) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
                holder.set(ticket)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private final class TicketHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var ticket: Ticket?
        private var cancelled = false
        func set(_ t: Ticket) {
            let late = lock.withLock { () -> Bool in ticket = t; return cancelled }
            if late { t.cancel() }
        }
        func cancel() {
            let t = lock.withLock { () -> Ticket? in cancelled = true; return ticket }
            t?.cancel()
        }
    }

    private func cancel(_ ticket: Ticket) {
        let done: Done? = lock.withLock {
            guard let job = jobs[ticket.key], let waiter = job.waiters.removeValue(forKey: ticket.token) else { return nil }
            if job.waiters.isEmpty {
                job.cancelled = true
                if let task = job.task {
                    task.cancel()          // `finish` cleans up
                } else {
                    jobs[ticket.key] = nil
                }
            } else if job.task == nil {
                job.priority = job.waiters.values.map(\.priority).max() ?? job.priority
            }
            return waiter.done
        }
        done?(CancellationError())
    }

    /// Starts what may start: highest priority first, oldest first within it.
    private func pump() {
        lock.withLock {
            let queued = jobs.values.filter { $0.task == nil && !$0.cancelled }
                .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.seq < $1.seq }
            for job in queued {
                switch job.priority {
                case .visible:
                    guard running < Self.maxVisible else { return }
                case .near:
                    guard running < Self.maxRunning else { return }
                case .background:
                    guard !interacting, Date().timeIntervalSince(calmSince) > 0.5,
                          running < Self.maxRunning, runningBackground < Self.maxBackground else { return }
                }
                start(job)
            }
        }
    }

    /// Lock held.
    private func start(_ job: Job) {
        running += 1
        if job.priority == .background { runningBackground += 1 }
        job.startedAs = job.priority
        let priority = job.priority
        let work = job.work
        let taskPriority: TaskPriority = switch priority {
        case .visible: .userInitiated
        case .near: .medium
        case .background: .utility
        }
        job.task = Task.detached(priority: taskPriority) { [self] in
            do {
                try Task.checkCancellation()
                try await work(priority)
                finish(job, nil)
            } catch {
                finish(job, error)
            }
        }
    }

    private func finish(_ job: Job, _ error: Error?) {
        let dones: [Done] = lock.withLock {
            running -= 1
            if job.startedAs == .background { runningBackground -= 1 }
            // started as background work (no cellular), wanted on screen by
            // now: try again over any network
            if let error, !job.cancelled, job.startedAs == .background, job.priority > .background || job.waiters.values.contains(where: { $0.priority > .background }),
               (error as? URLError)?.networkUnavailableReason != nil {
                job.task = nil
                job.startedAs = nil
                job.priority = job.waiters.values.map(\.priority).max() ?? .near
                return []
            }
            if jobs[job.key] === job { jobs[job.key] = nil }
            let out = job.waiters.values.map(\.done)
            job.waiters = [:]
            return out
        }
        for done in dones { done(error) }
        pump()
    }

    // MARK: Files

    /// The local file of `key`, downloaded from `url` first if needed.
    /// Off the main thread only (it reads the store's index).
    func file(_ key: MediaStore.Key, from url: URL, priority: Priority) async throws -> URL {
        let store = MediaStore.shared
        if let f = store.file(key) { return f }
        try await run(key.name, priority: priority) { p in
            try await Self.download(url, into: key, priority: p)
        }
        guard let f = store.file(key) else { throw URLError(.cannotCreateFile) }
        return f
    }

    /// Makes sure `key` is on the phone without waiting for it.
    func ensure(_ key: MediaStore.Key, from url: URL, priority: Priority, done: @escaping Done = { _ in }) -> Ticket {
        enqueue(key.name, priority: priority, work: { p in
            guard !MediaStore.shared.contains(key) else { return }
            try await Self.download(url, into: key, priority: p)
        }, done: done)
    }

    /// Downloads to a file and moves it into the store.
    static func download(_ url: URL, into key: MediaStore.Key, priority: Priority) async throws {
        var req = AtlasAuth.request(url, timeoutInterval: key.kind == .original ? 600 : 60)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if priority == .background {
            req.allowsExpensiveNetworkAccess = false
            req.allowsConstrainedNetworkAccess = false
        }
        let (tmp, resp) = try await shared.session.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw URLError(.badServerResponse)
        }
        let ext = (resp.suggestedFilename as NSString?)?.pathExtension ?? ""
        guard MediaStore.shared.adopt(tmp, key, ext: ext) != nil else {
            try? FileManager.default.removeItem(at: tmp)
            throw URLError(.cannotCreateFile)
        }
    }
}
