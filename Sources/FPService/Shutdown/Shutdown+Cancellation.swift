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
public func withCancellation<Success: Sendable, Failure: Error>(
    on shutdown: Shutdown,
    _ operation: @concurrent @Sendable @escaping () async -> Result<Success, Failure>
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
        while let result = await group.next() {
            group.cancelAll()

            if let result {
                return result
            }
        }

        // The operation is a child, so its result always arrives above.
        preconditionFailure("withCancellation(on:_:): the operation's result never arrived")
    }
}
