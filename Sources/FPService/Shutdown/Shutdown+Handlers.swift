/// Runs `operation` with `handler` registered on `shutdown`, and removes the
/// handler when the operation ends, so finished work is never called back.
///
/// Use it when the work has its own graceful-stop API: the handler calls it,
/// and the operation is left to finish in-flight work and return by itself.
/// (To simply cancel the work instead, use ``withCancellation(on:_:)``.)
///
/// ```swift
/// await withShutdownHandler(on: shutdown, server.beginGracefulShutdown) {
///     await server.run()     // returns once its own graceful shutdown completes
/// }
/// ```
///
/// The handler runs once, synchronously, on the thread that requested the
/// shutdown — for a signal, the task that reads signals — so keep it short.
/// If shutdown was already requested, it runs at once, before `operation`.
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
