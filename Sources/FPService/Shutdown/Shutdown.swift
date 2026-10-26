/// How `serve` learns that a graceful shutdown was requested from outside.
///
/// A ``Service`` run creates one and hands it to `serve` — the only place it
/// appears. It is read-only: `serve` stops by returning, not by requesting a
/// shutdown. Once requested it stays requested.
///
/// React to it with ``withCancellation(on:_:)`` (cancel the work) or
/// ``withShutdownHandler(on:_:operation:)`` (call the work's own stop), or
/// read it directly with ``isRequested`` and ``requested``. <doc:Stopping>
/// shows each.
public final class Shutdown: Sendable {
    let gate = Gate()

    init() {}

    /// A `Shutdown` outside a ``Service`` run, and the function that requests
    /// it — for testing a `serve` function on its own:
    ///
    /// ```swift
    /// let (shutdown, request) = Shutdown.makeShutdown()
    /// async let result = handleRequests(resources, shutdown)
    /// request()
    /// if case .failure(let error) = await result { Issue.record("\(error)") }
    /// ```
    ///
    /// `serve` gets only the read-only half, as in a real run. `request` runs
    /// every handler and wakes every waiter, once; later calls do nothing.
    public static func makeShutdown() -> (shutdown: Shutdown, request: @Sendable () -> Void) {
        let shutdown = Shutdown()
        return (shutdown, { shutdown.trigger() })
    }

    /// Whether graceful shutdown has been requested.
    public var isRequested: Bool { gate.isOpen }

    /// Suspends until graceful shutdown is requested.
    ///
    /// Returns at once if it already was. Also returns when the waiting task
    /// is cancelled — check `Task.isCancelled` if the difference matters.
    public var requested: Void {
        get async { await gate.openedOrCancelled }
    }

    /// Requests graceful shutdown: runs every handler and wakes every waiter,
    /// once. Returns whether this call was the first.
    @discardableResult
    func trigger() -> Bool { gate.open() }
}
