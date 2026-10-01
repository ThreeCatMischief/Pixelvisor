// Rate limit for state patches: at most one request in flight, at least `interval` between
// request starts, and changes made meanwhile merged into one pending patch. The last value
// is always sent. Time is injected for tests.

import Foundation

@MainActor
final class PatchThrottler {
    typealias Send = @MainActor (StatePatch) async -> Void

    let interval: Duration
    private let send: Send
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @MainActor (Duration) async -> Void
    private var pending: StatePatch?
    private var lastStart: ContinuousClock.Instant?
    private var drain: Task<Void, Never>?

    init(interval: Duration = .milliseconds(100),
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         send: @escaping Send) {
        self.interval = interval
        self.now = now
        self.sleep = sleep
        self.send = send
    }

    /// True while a patch waits to be sent; the caller should not adopt older responses then.
    var hasPending: Bool { pending != nil }

    func submit(_ patch: StatePatch) {
        if pending == nil { pending = patch } else { pending!.merge(patch) }
        if drain == nil { drain = Task { await run() } }
    }

    /// Waits until everything submitted so far has been sent.
    func idle() async {
        await drain?.value
    }

    private func run() async {
        while pending != nil {
            if let lastStart {
                let wait = interval - (now() - lastStart)
                if wait > .zero { await sleep(wait) }
            }
            guard let patch = pending else { break }
            pending = nil
            lastStart = now()
            await send(patch)
        }
        drain = nil
    }
}
