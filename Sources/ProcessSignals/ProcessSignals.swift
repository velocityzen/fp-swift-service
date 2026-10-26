#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Dispatch

/// Takes over `signals` and delivers each one as it arrives.
///
/// ```swift
/// var received = 0
/// for await signal in await processSignals([SIGTERM, SIGINT]) {
///     received += 1
///     print("signal \(signal), \(received) so far")
/// }
/// ```
///
/// - Each delivery is one element, even when several arrive at once. (On
///   Linux the kernel itself merges a signal sent again while the first is
///   still pending, as POSIX allows.)
/// - An empty `signals` list gives a stream that is already finished.
/// - Returns once every signal source is registered, so a signal sent right
///   after this call is not missed.
/// - While the stream lives, the signals' default actions are off: on Darwin
///   their disposition is `SIG_IGN` (kqueue still records them), on Linux
///   libdispatch handles them.
/// - The stream ends when the task iterating it is cancelled, or when the
///   stream and all its iterators are released. Ending it cancels the
///   sources and, on Darwin, restores the previous dispositions. Breaking
///   out of the loop alone does not end it while the stream is still
///   referenced.
/// - Waiting costs no thread of its own: Dispatch delivers signals through
///   the same machinery it uses for every other source.
/// - Dispositions are process-wide: take over each signal in one stream at a
///   time.
public func processSignals(_ signals: [Int32]) async -> AsyncStream<Int32> {
    let (stream, continuation) = AsyncStream<Int32>.makeStream()
    var sources: [any DispatchSourceSignal] = []
    var previous: [Disposition] = []

    for signal in signals where !previous.contains(where: { $0.signal == signal }) {
        previous.append(Disposition.ignore(signal))
        let source = DispatchSource.makeSignalSource(signal: signal, queue: signalQueue)
        // Dispatch coalesces deliveries that arrive before the handler runs;
        // `data` is how many there were, so a quick double Ctrl-C stays two.
        source.setEventHandler {
            for _ in 0..<max(source.data, 1) { continuation.yield(signal) }
        }
        await withCheckedContinuation { (registered: CheckedContinuation<Void, Never>) in
            source.setRegistrationHandler { registered.resume() }
            source.resume()
        }
        sources.append(source)
    }

    // Nothing to wait for: end at once instead of never.
    if sources.isEmpty { continuation.finish() }

    let installed = Sources(all: sources)
    continuation.onTermination = { [installed, previous] _ in
        installed.all.forEach { $0.cancel() }
        previous.forEach { $0.restore() }
    }
    return stream
}

/// The stream's signal sources, cancelled when it ends.
///
/// `@unchecked Sendable` because a Dispatch source may be cancelled from any
/// thread, but Linux's Dispatch module does not mark the source types
/// `Sendable` the way Darwin's does.
private struct Sources: @unchecked Sendable {
    let all: [any DispatchSourceSignal]
}

/// One serial queue for every signal handler; handlers only yield.
private let signalQueue = DispatchQueue(label: "ProcessSignals")

/// A signal's disposition from before the stream took it over.
private struct Disposition: @unchecked Sendable {
    let signal: Int32
    #if canImport(Darwin)
        let action: sigaction
    #endif

    /// On Darwin, sets `SIG_IGN` so the default action never runs while
    /// kqueue (under Dispatch) still records the signal. On Linux,
    /// libdispatch manages the signal itself, so nothing changes.
    static func ignore(_ signal: Int32) -> Disposition {
        #if canImport(Darwin)
            var ignore = sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            var previous = sigaction()
            sigaction(signal, &ignore, &previous)
            return Disposition(signal: signal, action: previous)
        #else
            return Disposition(signal: signal)
        #endif
    }

    func restore() {
        #if canImport(Darwin)
            var action = action
            sigaction(signal, &action, nil)
        #endif
    }
}
