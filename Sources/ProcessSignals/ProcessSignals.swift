#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#elseif canImport(CRT)
    import CRT
#else
    #error("ProcessSignals supports Darwin, Linux (Glibc and Musl), Android and Windows only")
#endif
import Synchronization

/// Subscribes to `signals` and delivers each one as it arrives.
///
/// ```swift
/// var received = 0
/// for await signal in await processSignals([SIGTERM, SIGINT]) {
///     received += 1
///     print("\(signalName(signal)), \(received) so far")
/// }
/// ```
///
/// - Returns once the signals are subscribed to, so none sent after the
///   call is missed.
/// - Signals that can't be caught (`SIGKILL`, `SIGSTOP`, or numbers the
///   platform lacks or reserves) are left out. If none are left, the
///   stream is already finished. Except on Windows, so is a stream that
///   can't subscribe at all (no file descriptor left); a later call retries.
/// - While the stream lives, the signals' default actions are suspended.
///   They are caught, not ignored, so child processes start with the
///   defaults.
/// - Cancelling the iterating task, or releasing the stream, ends it; the
///   last stream on a signal restores its previous disposition. Breaking
///   out of the loop doesn't end it.
/// - Several streams can share a signal; each gets every delivery. Signals
///   sent at the same instant may merge, except on Darwin.
/// - A signal is never lost: one that arrives as the last stream on it ends
///   is either delivered or has the signal's previous effect. For the
///   latter it is sent again, by this process.
///
/// On Windows, console events arrive as SIGINT (Ctrl-C), SIGBREAK
/// (Ctrl-Break) and SIGTERM (close, logoff, shutdown), the only signals
/// available there. A SIGTERM event is held while any stream subscribes to
/// SIGTERM, since Windows ends the process once it is handled.
public func processSignals(_ signals: [Int32]) async -> AsyncStream<Int32> {
    await registerSignals(signals).stream
}

/// A signal stream, the signals it subscribed to, and the requested ones it
/// could not. Each signal is in one list or the other, once.
package typealias Signals = (stream: AsyncStream<Int32>, signals: [Int32], unavailable: [Int32])

/// ``processSignals(_:)``, also saying which signals it subscribed to and
/// which it could not.
package func registerSignals(_ signals: [Int32]) async -> Signals {
    let (stream, continuation) = AsyncStream<Int32>.makeStream()
    let requested = signals.withoutRepeats()
    let available = requested.keeping(canRegisterSignal)

    // Nothing to wait for: end at once instead of never.
    guard !available.isEmpty else {
        continuation.finish()
        return (stream, [], requested)
    }

    let subscription = await subscribe(available, delivering: continuation)
    continuation.onTermination = { _ in subscription.release() }
    let subscribed = subscription.signals
    return (stream, subscribed, requested.filter { !subscribed.contains($0) })
}

#if !os(Windows)
    /// Whether `signal` can be subscribed to. Except on Darwin, `sigaction` is
    /// asked rather than a range checked: it rejects the numbers this
    /// platform doesn't have, and with glibc and musl the ones the C library
    /// keeps for itself. SIGKILL and SIGSTOP it accepts for reading, but they
    /// can never be caught or ignored.
    func canRegisterSignal(_ signal: Int32) -> Bool {
        guard signal != SIGKILL, signal != SIGSTOP else {
            return false
        }
        #if canImport(Darwin)
            // Darwin has signals 1 to 31 and keeps none for itself, so the
            // range is exact, and spares a system call.
            return (1..<NSIG).contains(signal)
        #else
            #if canImport(Android)
                // Bionic's `sigaction` doesn't reject the real-time signals
                // it keeps for itself (timers, debuggerd, profilers): the
                // first ones, below SIGRTMIN.
                guard !(__SIGRTMIN..<__libc_current_sigrtmin()).contains(signal) else {
                    return false
                }
            #endif

            var current = sigaction()
            return sigaction(signal, nil, &current) == 0
        #endif
    }
#endif

/// How many streams are subscribed to a signal, and its disposition from
/// before the first of them.
private struct SignalState {
    var count: Int
    let previous: Disposition
}

/// Every signal some stream is subscribed to. Dispositions are process-wide,
/// so streams share them: the first subscriber sets a signal's disposition,
/// the last restores it.
private let subscribers = Mutex<[Int32: SignalState]>([:])

/// Adds a subscriber to `signal`; the first one sets its disposition.
func addSubscriber(to signal: Int32) {
    subscribers.withLock { subscribers in
        if subscribers[signal] != nil {
            subscribers[signal]?.count += 1
        } else {
            subscribers[signal] = SignalState(count: 1, previous: Disposition.create(signal))
        }
    }
}

/// Removes a subscriber from `signal`; the last one restores its disposition.
func removeSubscriber(from signal: Int32) {
    subscribers.withLock { subscribers in
        guard let state = subscribers[signal] else { return }
        if state.count == 1 {
            subscribers[signal] = nil
            state.previous.restore()
        } else {
            subscribers[signal]?.count -= 1
        }
    }
}

/// How many streams are subscribed to `signal`. For tests, next to the signal's handler: a stream
/// that outlived its test still counts here, while a disposition that was not restored shows with
/// none.
package func subscriberCount(of signal: Int32) -> Int {
    subscribers.withLock { $0[signal]?.count ?? 0 }
}

/// Where each stream's signals go. Every platform delivers through these.
let routes = SignalRoutes()

final class SignalRoutes: Sendable {
    /// One stream's signals and where they go.
    private struct Route {
        let signals: [Int32]
        let continuation: AsyncStream<Int32>.Continuation
    }

    /// Every stream's continuation once for each signal it is subscribed to, never changed:
    /// a route or unroute replaces it whole.
    private final class Snapshot: Sendable {
        /// Each subscribed signal, and at the same index the continuation it goes to: apart, as
        /// reading any field of an element copies the element, which would retain its
        /// continuation.
        private let signals: [Int32]
        private let continuations: [AsyncStream<Int32>.Continuation]

        init(_ routes: some Sequence<Route>) {
            var signals: [Int32] = []
            var continuations: [AsyncStream<Int32>.Continuation] = []
            for route in routes {
                for signal in route.signals {
                    signals.append(signal)
                    continuations.append(route.continuation)
                }
            }
            self.signals = signals
            self.continuations = continuations
        }

        /// Yields `signal` to each stream subscribed to it, returning whether one took it.
        /// Indexed, so each continuation is borrowed rather than retained.
        func deliver(_ signal: Int32) -> Bool {
            var taken = false
            for index in signals.indices where signals[index] == signal {
                if case .enqueued = continuations[index].yield(signal) { taken = true }
            }
            return taken
        }
    }

    private struct Table {
        var lastID: UInt64 = 0
        var byID: [UInt64: Route] = [:]
        /// `nil` while nothing is routed, so the last unroute makes no snapshot.
        var current: Snapshot?
        /// Deliveries using a snapshot outside the lock.
        var deliveries = 0
        /// Snapshots replaced while a delivery may still use them, kept until none does.
        var retired: [Snapshot] = []

        /// Replaces the snapshot. The old one is kept in `retired` while a delivery may still use
        /// it, and otherwise returned, to be dropped outside the lock: dropping a continuation can
        /// end its stream, whose termination handler takes the lock.
        mutating func replace() -> Snapshot? {
            let old = current
            current = byID.isEmpty ? nil : Snapshot(byID.values)
            guard let old, deliveries > 0 else { return old }
            retired.append(old)
            return nil
        }
    }

    private let table = Mutex(Table())

    /// Delivers `signals` to `continuation` until ``unroute(_:)`` is called with the returned id.
    func route(_ signals: [Int32], to continuation: AsyncStream<Int32>.Continuation) -> UInt64 {
        let (id, _) = table.withLock { table in
            table.lastID += 1
            table.byID[table.lastID] = Route(signals: signals, continuation: continuation)
            return (table.lastID, table.replace())
        }
        return id
    }

    func unroute(_ id: UInt64) {
        _ = table.withLock { table in
            (table.byID.removeValue(forKey: id), table.replace())
        }
    }

    /// Yields `signal` to each stream subscribed to it, and returns whether one took it: a stream
    /// that has ended takes nothing.
    ///
    /// Yielded outside the lock: cancelling a stream's task releases it, which takes the lock,
    /// while the runtime holds a lock of the task that a yield to it waits for. The snapshot is
    /// borrowed, not retained, so a delivery costs no reference counting: one replaced meanwhile
    /// is kept in `retired` until the last delivery that may use it is done.
    func deliver(_ signal: Int32) -> Bool {
        let snapshot = table.withLock { table -> Unmanaged<Snapshot>? in
            guard let current = table.current else { return nil }
            table.deliveries += 1
            return Unmanaged.passUnretained(current)
        }
        guard let snapshot else { return false }
        let taken = snapshot._withUnsafeGuaranteedRef { $0.deliver(signal) }
        // Only a Bool comes out in the usual case: even an absent array would be released.
        let last = table.withLock { table in
            table.deliveries -= 1
            return table.deliveries == 0 && !table.retired.isEmpty
        }
        if last { dropRetired() }
        return taken
    }

    /// Drops the snapshots no delivery uses any more, outside the lock.
    private func dropRetired() {
        let retired = table.withLock { table in
            guard table.deliveries == 0 else { return [Snapshot]() }
            defer { table.retired = [] }
            return table.retired
        }
        _ = consume retired
    }
}

// Both return the array itself when there is nothing to drop, the usual case,
// so a subscription copies no signal list.

extension Array where Element: Equatable {
    /// The elements without repeats, each where it first appears.
    func withoutRepeats() -> [Element] {
        guard indices.contains(where: { self[..<$0].contains(self[$0]) }) else {
            return self
        }
        return reduce(into: []) { kept, element in
            if !kept.contains(element) {
                kept.append(element)
            }
        }
    }
}

extension Array {
    /// The elements that satisfy `isIncluded`, in order.
    func keeping(_ isIncluded: (Element) -> Bool) -> [Element] {
        guard let dropped = firstIndex(where: { !isIncluded($0) }) else {
            return self
        }
        return self[..<dropped] + self[(dropped + 1)...].filter(isIncluded)
    }
}
