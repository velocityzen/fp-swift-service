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
///   stream is already finished. On Linux and Android, so is a stream that
///   can't subscribe at all (no file descriptor left); a later call retries.
/// - While the stream lives, the signals' default actions are suspended.
///   They are caught, not ignored, so child processes start with the
///   defaults.
/// - Cancelling the iterating task, or releasing the stream, ends it; the
///   last stream on a signal restores its previous disposition. Breaking
///   out of the loop doesn't end it.
/// - Several streams can share a signal; each gets every delivery. Signals
///   sent at the same instant may merge, except on Darwin.
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
    let requested = signals.reduce(into: [Int32]()) { requested, signal in
        if !requested.contains(signal) {
            requested.append(signal)
        }
    }
    let available = requested.filter(canRegisterSignal)

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
    /// Whether `signal` can be subscribed to. `sigaction` is asked rather than
    /// a range checked: it rejects the numbers this platform doesn't have, and
    /// with glibc and musl the ones the C library keeps for itself. (Given one
    /// of those, Darwin's Dispatch would end the process.) SIGKILL and SIGSTOP
    /// it accepts for reading, but they can never be caught or ignored.
    func canRegisterSignal(_ signal: Int32) -> Bool {
        guard signal != SIGKILL, signal != SIGSTOP else {
            return false
        }
        #if canImport(Android)
            // Bionic's `sigaction` doesn't reject the real-time signals it
            // keeps for itself (timers, debuggerd, profilers): the first
            // ones, below SIGRTMIN.
            guard !(__SIGRTMIN..<__libc_current_sigrtmin()).contains(signal) else {
                return false
            }
        #endif

        var current = sigaction()
        return sigaction(signal, nil, &current) == 0
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
        if state.count > 1 {
            subscribers[signal]?.count -= 1
        } else {
            subscribers[signal] = nil
            state.previous.restore()
        }
    }
}
