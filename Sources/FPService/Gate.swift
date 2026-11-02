import Synchronization

/// A one-shot flag: closed until ``open()``, then open for good. It can be
/// awaited, and runs callbacks when it opens.
///
/// The building block for ``Shutdown``: its handlers are the callbacks, and
/// `serve` awaits it.
@usableFromInline
final class Gate: Sendable {
    typealias Callback = @Sendable () -> Void

    // Structs rather than tuples, so the arrays store the callback as it is
    // instead of wrapping it in a thunk.
    private struct WaitingCallback {
        let id: UInt64
        let callback: Callback
    }

    private struct WaitingTask {
        let id: UInt64
        let continuation: UnsafeContinuation<Void, Never>
    }

    /// What waits for the gate to open, each in registration order:
    /// callbacks, which may block, and suspended tasks, which only need
    /// resuming.
    private struct Waiting {
        var callbacks: [WaitingCallback] = []
        var tasks: [WaitingTask] = []

        /// Resumes the tasks, which can't block, then runs the callbacks.
        func release() {
            tasks.forEach { $0.continuation.resume() }
            callbacks.forEach { $0.callback() }
        }
    }

    private struct State {
        /// `nil` once the gate is open.
        var waiting: Waiting? = Waiting()
        var nextID: UInt64 = 0

        mutating func register() -> UInt64? {
            guard waiting != nil else { return nil }
            nextID += 1
            return nextID
        }
    }

    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.waiting == nil } }

    /// Opens the gate: resumes every waiting task, then runs every callback
    /// once, in registration order, outside the lock. Returns whether this
    /// call opened it.
    @discardableResult
    func open() -> Bool {
        let waiting = state.withLock { state in
            defer { state.waiting = nil }
            return state.waiting
        }
        guard let waiting else {
            return false
        }

        waiting.release()
        return true
    }

    /// Opens the gate here unless a callback waits for it: resuming waiting
    /// tasks can't block, a callback can. Returns `false`, leaving the gate
    /// closed, if a callback waits; `true` once the gate is open, whoever
    /// opened it.
    func openUnlessCallbacks() -> Bool {
        let waiting: Waiting?? = state.withLock { state in
            guard let waiting = state.waiting else { return .some(nil) }
            guard waiting.callbacks.isEmpty else { return nil }
            state.waiting = nil
            return waiting
        }
        guard let waiting else {
            return false
        }

        waiting?.release()
        return true
    }

    /// Waits for the gate to open without suspending: runs `callback` when
    /// it opens, or at once if it already is. Returns an id for
    /// ``remove(_:)``, or `nil` if it already ran.
    @discardableResult
    func wait(_ callback: @escaping Callback) -> UInt64? {
        let id: UInt64? = state.withLock { state in
            guard let id = state.register() else { return nil }
            state.waiting?.callbacks.append(WaitingCallback(id: id, callback: callback))
            return id
        }
        if id == nil { callback() }
        return id
    }

    /// Unregisters a callback that has not run yet; returns it, if found.
    @discardableResult
    func remove(_ id: UInt64) -> Callback? {
        // The lock hands back the struct: a closure returned through its
        // generic result would be wrapped in a thunk.
        let removed: WaitingCallback? = state.withLock { state in
            guard let index = state.waiting?.callbacks.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.waiting?.callbacks.remove(at: index)
        }
        return removed?.callback
    }

    /// Suspends until the gate opens. Also returns when the waiting task is
    /// cancelled — check `Task.isCancelled` if the difference matters.
    var openedOrCancelled: Void {
        get async {
            // Already open or cancelled: nothing to wait for.
            guard !isOpen, !Task.isCancelled else {
                return
            }

            let registered = Mutex<UInt64?>(nil)
            await withTaskCancellationHandler {
                await openedOrEnded { id in
                    registered.withLock { $0 = id }
                    return Task.isCancelled
                }
            } onCancel: {
                if let id = registered.withLock({ $0 }) {
                    endWait(id)
                }
            }
        }
    }

    /// Suspends until the gate opens or another task ends the wait with
    /// ``endWait(_:)``.
    ///
    /// `registered` gets the wait's id, for whoever may end it, and returns
    /// whether to end it at once. Recording the id before checking closes
    /// the race with the other task: either it ended the wait first, and
    /// `registered` sees that, or it finds the id.
    @usableFromInline
    func openedOrEnded(registering registered: (UInt64) -> Bool) async {
        guard !isOpen else {
            return
        }

        await withUnsafeContinuation { (waiter: UnsafeContinuation<Void, Never>) in
            guard let id = enqueue(waiter) else {
                return waiter.resume()
            }
            if registered(id) {
                endWait(id)
            }
        }
    }

    /// Resumes the task waiting under `id`, unless the gate opened first:
    /// whichever takes it from the gate resumes it, once.
    @usableFromInline
    func endWait(_ id: UInt64) {
        dequeue(id)?.resume()
    }

    /// Registers a suspended task; returns its id, or `nil` if the gate is
    /// open.
    private func enqueue(_ continuation: UnsafeContinuation<Void, Never>) -> UInt64? {
        state.withLock { state in
            guard let id = state.register() else { return nil }
            state.waiting?.tasks.append(WaitingTask(id: id, continuation: continuation))
            return id
        }
    }

    /// Unregisters a suspended task the gate has not resumed; returns it, if
    /// found.
    private func dequeue(_ id: UInt64) -> UnsafeContinuation<Void, Never>? {
        state.withLock { state in
            guard let index = state.waiting?.tasks.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.waiting?.tasks.remove(at: index).continuation
        }
    }
}
