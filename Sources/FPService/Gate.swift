import Synchronization

/// A one-shot flag: closed until ``open()``, then open for good. It can be
/// awaited, and runs callbacks when it opens.
///
/// The building block for ``Shutdown`` and for the internal "done" and
/// "cancelling" flags of a run.
final class Gate: Sendable {
    typealias Callback = @Sendable () -> Void

    private struct State {
        var isOpen = false
        var callbacks: [(id: UInt64, callback: Callback)] = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.isOpen } }

    /// Opens the gate: runs every callback once, in registration order,
    /// outside the lock. Returns whether this call opened it.
    @discardableResult
    func open() -> Bool {
        let callbacks = state.withLock { state -> [Callback]? in
            guard !state.isOpen else { return nil }
            state.isOpen = true
            defer { state.callbacks = [] }
            return state.callbacks.map(\.callback)
        }
        guard let callbacks else { return false }
        callbacks.forEach { $0() }
        return true
    }

    /// Runs `callback` when the gate opens, or at once if it already is.
    /// Returns an id for ``remove(_:)``, or `nil` if it already ran.
    @discardableResult
    func onOpen(_ callback: @escaping Callback) -> UInt64? {
        let id: UInt64? = state.withLock { state in
            guard !state.isOpen else { return nil }
            state.nextID += 1
            state.callbacks.append((state.nextID, callback))
            return state.nextID
        }
        if id == nil { callback() }
        return id
    }

    /// Unregisters a callback that has not run yet; returns it, if found.
    @discardableResult
    func remove(_ id: UInt64) -> Callback? {
        state.withLock { state in
            state.callbacks.firstIndex { $0.id == id }.map {
                state.callbacks.remove(at: $0).callback
            }
        }
    }

    /// Suspends until the gate opens. Also returns when the waiting task is
    /// cancelled — check `Task.isCancelled` if the difference matters.
    var openedOrCancelled: Void {
        get async {
            let registered = Mutex<UInt64?>(nil)
            await withTaskCancellationHandler {
                await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                    // Registering under the cancellation check closes the
                    // race with `onCancel`: it either ran first (and the
                    // flag is already set here) or finds the waiter.
                    guard !Task.isCancelled else { return waiter.resume() }
                    let id = onOpen { waiter.resume() }
                    registered.withLock { $0 = id }
                    if Task.isCancelled, let id, let waiter = remove(id) { waiter() }
                }
            } onCancel: {
                if let id = registered.withLock({ $0 }), let waiter = remove(id) { waiter() }
            }
        }
    }

    /// Suspends until the gate opens, even if the waiting task is cancelled.
    var openedIgnoringCancellation: Void {
        get async {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                onOpen { waiter.resume() }
            }
        }
    }
}
