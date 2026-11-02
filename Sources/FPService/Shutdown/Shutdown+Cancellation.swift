import Synchronization

/// Runs `operation` and returns its result; if shutdown is requested first,
/// the operation is cancelled, and the call waits for it to return.
///
/// The operation decides what being cancelled means and reports it in its
/// own result, so nothing is lost: a success comes back as is, and a failure
/// that happens before shutdown comes back at once.
///
/// ```swift
/// /// Handles requests until shutdown is requested, then stops and returns.
/// func handleRequests(_ resources: (Database, Server), _ shutdown: Shutdown) async -> Result<
///     Void, ExampleError
/// > {
///     await withCancellation(on: shutdown, work)
/// }
///
/// /// Handles a request once a second until cancelled.
/// func work() async -> Result<Void, ExampleError> {
///     var request = 0
///     while !Task.isCancelled {
///         try? await Task.sleep(for: .seconds(1))
///         guard !Task.isCancelled else { break }
///         request += 1
///         print("handled request \(request)")
///     }
///     return .success(())
/// }
/// ```
///
/// `operation` runs in a task of its own (`@concurrent`), off the caller's
/// actor.
@inlinable
public func withCancellation<Success: Sendable, Failure: Error>(
    on shutdown: Shutdown,
    _ operation: @concurrent @Sendable @escaping () async -> Result<Success, Failure>
) async -> Result<Success, Failure> {
    let race = OperationRace(operation, on: shutdown)
    do {
        // A child of the calling task, in its allocator rather than on the
        // heap. Its result ends the wait below, unless shutdown did first.
        async let _ = race.finish(with: await race.operation())
        await shutdown.gate.openedOrEnded { race.wait($0) }
        // Leaving the scope cancels the operation if it still runs, and
        // waits for it. Shutdown (or the caller's cancellation) only cancels
        // it; the result is always its own.
    }
    return race.take()
}

/// An operation racing shutdown: its result, and the caller's wait for it
/// or for shutdown, whichever comes first.
@usableFromInline
final class OperationRace<Success: Sendable, Failure: Error>: Sendable {
    @usableFromInline
    struct State {
        @usableFromInline var result: Result<Success, Failure>?
        /// The caller's wait on the shutdown gate, once registered.
        @usableFromInline var wait: UInt64?

        @inlinable
        init() {}
    }

    @usableFromInline
    let operation: @concurrent @Sendable () async -> Result<Success, Failure>

    @usableFromInline
    let shutdown: Shutdown

    @usableFromInline
    let state = Mutex(State())

    @inlinable
    init(
        _ operation: @concurrent @Sendable @escaping () async -> Result<Success, Failure>,
        on shutdown: Shutdown
    ) {
        self.operation = operation
        self.shutdown = shutdown
    }

    /// Records the caller's wait; returns whether the result is already in,
    /// so the wait ends at once.
    @inlinable
    func wait(_ id: UInt64) -> Bool {
        state.withLock { state in
            state.wait = id
            return state.result != nil
        }
    }

    /// Records the operation's result and ends the caller's wait.
    @inlinable
    func finish(with result: Result<Success, Failure>) {
        let wait = state.withLock { state in
            state.result = result
            return state.wait
        }
        if let wait {
            shutdown.gate.endWait(wait)
        }
    }

    /// The result, once the operation has returned.
    @inlinable
    func take() -> Result<Success, Failure> {
        guard let result = state.withLock({ $0.result.take() }) else {
            // The operation is awaited before this, so its result is in.
            preconditionFailure("withCancellation(on:_:): the operation's result never arrived")
        }
        return result
    }
}
