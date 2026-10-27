/// How `serve` learns that a graceful shutdown was requested.
///
/// A ``Service`` run creates one, hands it to `serve`, and requests it when
/// stage 1 begins. Once requested it stays requested. `serve` stops by
/// returning: requesting the run's shutdown from `serve` runs the handlers
/// and wakes the waiters, but the run moves on only once `serve` returns.
///
/// React to it with ``withCancellation(on:_:)`` (cancel the work) or
/// ``withShutdownHandler(on:_:operation:)`` (call the work's own stop), or
/// read it directly with ``isRequested`` and ``requested``. <doc:Stopping>
/// shows each.
///
/// To test a `serve` function on its own, make one and request it:
///
/// ```swift
/// let shutdown = Shutdown()
/// async let result = handleRequests(resources, shutdown)
/// shutdown.request()
/// if case .failure(let error) = await result { Issue.record("\(error)") }
/// ```
public final class Shutdown: Sendable {
    let gate = Gate()

    /// A shutdown not yet requested.
    public init() {}

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
    /// once; later calls do nothing. Returns whether this call was the first.
    @discardableResult
    public func request() -> Bool { gate.open() }
}
