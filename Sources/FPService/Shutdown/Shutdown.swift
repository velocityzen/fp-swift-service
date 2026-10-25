/// How `serve` learns that a graceful shutdown was requested from outside.
///
/// A ``Service`` run creates one and hands it to `serve` — the only place it
/// appears. It is read-only: `serve` stops by returning, not by requesting a
/// shutdown. Once requested it stays requested.
///
/// React to it with ``withCancellation(on:_:)`` (cancel the work) or
/// ``withShutdownHandler(on:_:operation:)`` (call the work's own stop), or
/// read it directly with ``isRequested`` and ``requested``:
///
/// ```swift
/// await withService { resources, shutdown in
///     await withCancellation(on: shutdown, resources.queue.consume)
/// }
/// ```
public final class Shutdown: Sendable {
    let gate = Gate()

    init() {}

    /// Whether graceful shutdown has been requested.
    public var isRequested: Bool { gate.isOpen }

    /// Suspends until graceful shutdown is requested.
    ///
    /// Returns at once if it already was. Also returns when the waiting task
    /// is cancelled — check `Task.isCancelled` if the difference matters.
    public var requested: Void {
        get async { await gate.opened }
    }

    /// Requests graceful shutdown: runs every handler and wakes every waiter,
    /// once. Returns whether this call was the first.
    @discardableResult
    func trigger() -> Bool { gate.open() }
}
