import Synchronization

/// A one-shot flag: closed until ``open()``, then open for good. It can be
/// awaited, and runs callbacks when it opens.
///
/// The building block for ``Shutdown``: its handlers are the callbacks, and
/// `serve` awaits it.
final class Gate: Sendable {
    typealias Callback = @Sendable () -> Void

    private struct State {
        /// The callbacks waiting for the gate to open, in registration
        /// order; `nil` once it has.
        var callbacks: [(id: UInt64, callback: Callback)]? = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.callbacks == nil } }

    /// Opens the gate: runs every callback once, in registration order,
    /// outside the lock. Returns whether this call opened it.
    @discardableResult
    func open() -> Bool {
        let callbacks = state.withLock { state -> [Callback]? in
            defer { state.callbacks = nil }
            return state.callbacks?.map(\.callback)
        }
        guard let callbacks else {
            return false
        }

        callbacks.forEach { $0() }
        return true
    }

    /// Waits for the gate to open without suspending: runs `callback` when
    /// it opens, or at once if it already is. Returns an id for
    /// ``remove(_:)``, or `nil` if it already ran.
    @discardableResult
    func wait(_ callback: @escaping Callback) -> UInt64? {
        let id: UInt64? = state.withLock { state in
            guard state.callbacks != nil else { return nil }
            state.nextID += 1
            state.callbacks?.append((state.nextID, callback))
            return state.nextID
        }
        if id == nil { callback() }
        return id
    }

    /// Unregisters a callback that has not run yet; returns it, if found.
    @discardableResult
    func remove(_ id: UInt64) -> Callback? {
        state.withLock { state in
            guard let index = state.callbacks?.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.callbacks?.remove(at: index).callback
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
                    guard !Task.isCancelled else {
                        return waiter.resume()
                    }

                    let id = wait { waiter.resume() }
                    registered.withLock { $0 = id }
                    if Task.isCancelled, let id, let waiter = remove(id) {
                        waiter()
                    }
                }
            } onCancel: {
                if let id = registered.withLock({ $0 }), let waiter = remove(id) {
                    waiter()
                }
            }
        }
    }
}
