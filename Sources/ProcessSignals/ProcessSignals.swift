#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#else
    #error("ProcessSignals supports Darwin, Glibc (Linux) and Musl (static Linux) only")
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
/// - Each delivery is one element. Signals sent in the same instant can
///   merge: the kernel keeps only one pending instance of a standard signal
///   (Darwin's kqueue still counts every send).
/// - A signal that can't be subscribed to is left out: a number this platform
///   doesn't have (on Linux, also one the C library keeps for itself), or
///   SIGKILL or SIGSTOP, which can't be caught. If no signal is left, or the
///   list is empty, the stream is already finished.
/// - Returns once the signals are subscribed to, so a signal sent right after
///   this call is not missed. One sent during the call is never lost either:
///   it has its previous effect, or is delivered, or both.
/// - While the stream lives, a handler of its own catches the signals, so
///   their default actions can't end the process. Like any handler, it can
///   interrupt a blocking call on a thread that doesn't block the signal;
///   with `SA_RESTART`, most calls resume. `exec` resets a caught signal, so
///   child processes start with the default actions.
/// - The stream ends when the task iterating it is cancelled, or when the
///   stream and all its iterators are deallocated. Ending it unsubscribes
///   from the signals. Breaking out of the loop alone does not end the stream
///   while it is still referenced.
/// - Several streams can subscribe to the same signal at once: each gets every
///   delivery, and the signal's previous disposition is restored when the
///   last of them ends.
/// - Waiting costs no thread of its own: Dispatch delivers the signals through
///   the same machinery it uses for every other source.
/// - If the signals can't be subscribed to at all (on Linux, when no pipe can
///   be made), the stream is already finished and the dispositions are left
///   alone; a later call tries again.
///
/// On Darwin the handler does nothing, and the signals are read from kqueue
/// through Dispatch signal sources. (Not `SIG_IGN`: a child process would
/// inherit it across `exec`, and an ignored SIGCHLD is never sent at all.)
/// On Linux the handler writes each signal to a pipe that a Dispatch read
/// source drains; Dispatch signal sources are not used there, because
/// libdispatch installs a handler of its own that it never removes.
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

/// Whether `signal` can be subscribed to. `sigaction` is asked rather than a
/// range checked: it rejects the numbers this platform doesn't have, and on
/// Linux the ones the C library keeps for itself. (Given one of those,
/// Darwin's Dispatch would end the process.) SIGKILL and SIGSTOP it accepts
/// for reading, but they can never be caught or ignored.
func canRegisterSignal(_ signal: Int32) -> Bool {
    guard signal != SIGKILL, signal != SIGSTOP else {
        return false
    }

    var current = sigaction()
    return sigaction(signal, nil, &current) == 0
}

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
