/// Runs `operation` and returns its result; if shutdown is requested first,
/// the operation is cancelled, and the call waits for it to return.
///
/// The operation decides what being cancelled means and reports it in its
/// own result, so nothing is lost: a success comes back as is, and a failure
/// that happens before shutdown comes back at once.
///
/// ```swift
/// func handleRequests(_ resources: Resources, _ shutdown: Shutdown) async -> Result<Void, AppError> {
///     await withCancellation(on: shutdown, acceptConnections)
/// }
/// ```
///
/// Like fp-swift's `withTimeout`, but triggered by a shutdown request rather
/// than a duration, and returning the operation's own result instead of a
/// fixed error.
public func withCancellation<Success: Sendable, Failure: Error>(
    on shutdown: Shutdown,
    _ operation: @escaping @Sendable () async -> Result<Success, Failure>
) async -> Result<Success, Failure> {
    await withTaskGroup(of: Result<Success, Failure>?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            await shutdown.requested
            return nil
        }

        // The first child to finish cancels the other. Shutdown (or the
        // caller's cancellation) only cancels the operation; the call keeps
        // waiting for the operation's own result.
        while let next = await group.next() {
            group.cancelAll()
            if let result = next { return result }
        }

        // Unreachable: the operation is a child, so its result always
        // arrives above. Running it again keeps the type inhabited without a
        // force-unwrap.
        return await operation()
    }
}
