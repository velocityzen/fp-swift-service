/// Runs `operation` with `handler` registered on `shutdown`, and removes the
/// handler when the operation ends, so finished work is never called back.
///
/// Use it when the work has its own graceful-stop API: the handler calls it,
/// and the operation is left to finish in-flight work and return by itself.
/// (To simply cancel the work instead, use ``withCancellation(on:_:)``.)
///
/// ```swift
/// /// Lets the server finish the request in flight instead of cancelling it.
/// func drainRequests(_ resources: (Database, Server), _ shutdown: Shutdown) async -> Result<
///     Void, ExampleError
/// > {
///     let (_, server) = resources
///     return await withShutdownHandler(on: shutdown, server.beginGracefulShutdown) {
///         await server.run()
///     }
/// }
/// ```
///
/// The handler runs once, synchronously, in the task that requests the
/// shutdown. For a signal that is a task of its own, so a handler that blocks
/// never keeps a later signal from cancelling the service or ending the
/// process. Keep it short all the same: the service's call returns only once
/// it has. If shutdown was already requested, it runs at once, before
/// `operation`.
public func withShutdownHandler<T>(
    on shutdown: Shutdown,
    _ handler: @escaping @Sendable () -> Void,
    operation: () async -> T
) async -> T {
    let registration = shutdown.onShutdown(handler)
    let result = await operation()
    registration.remove()
    return result
}

/// A registered shutdown handler; ``remove()`` unregisters it.
struct ShutdownRegistration: Sendable {
    let shutdown: Shutdown
    let id: UInt64?

    /// Removes the handler. Safe to call more than once, and after it fired.
    func remove() {
        if let id { shutdown.gate.remove(id) }
    }
}

extension Shutdown {
    /// Registers a handler that runs when shutdown is requested; one
    /// registered after the request runs at once. The caller removes it.
    @discardableResult
    func onShutdown(_ handler: @escaping @Sendable () -> Void) -> ShutdownRegistration {
        ShutdownRegistration(shutdown: self, id: gate.onOpen(handler))
    }
}
