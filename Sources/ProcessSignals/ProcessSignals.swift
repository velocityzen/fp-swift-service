import Synchronization

/// Takes over `signals` and delivers each one as it arrives.
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
/// - An empty `signals` list gives a stream that is already finished.
/// - Returns once the signals are taken over, so a signal sent right after
///   this call is not missed.
/// - While the stream lives, the signals' default actions are off, so they
///   can't end the process.
/// - The stream ends when the task iterating it is cancelled, or when the
///   stream and all its iterators are released. Ending it releases the
///   signals. Breaking out of the loop alone does not end the stream while it
///   is still referenced.
/// - Several streams can take over the same signal at once: each gets every
///   delivery, and the signal's previous disposition is restored when the
///   last of them ends.
/// - Waiting costs no thread of its own: Dispatch delivers the signals through
///   the same machinery it uses for every other source.
/// - If the signals cannot be taken over at all (on Linux, when no pipe can be
///   made), the stream is already finished and the dispositions are left
///   alone.
///
/// On Darwin the signals are set to `SIG_IGN` and read from kqueue through
/// Dispatch signal sources. On Linux a handler of its own writes each signal
/// to a pipe that a Dispatch read source drains; Dispatch signal sources are
/// not used there, because libdispatch installs a handler of its own that it
/// never removes.
public func processSignals(_ signals: [Int32]) async -> AsyncStream<Int32> {
    let (stream, continuation) = AsyncStream<Int32>.makeStream()
    let unique = signals.reduce(into: [Int32]()) { unique, signal in
        if !unique.contains(signal) { unique.append(signal) }
    }

    // Nothing to wait for: end at once instead of never.
    guard !unique.isEmpty else {
        continuation.finish()
        return stream
    }

    let takeover = await takeOver(unique, delivering: continuation)
    continuation.onTermination = { _ in takeover.release() }
    return stream
}

/// A signal taken over by one or more streams, and its disposition from
/// before the first of them.
private struct Hold {
    var streams: Int
    let previous: Disposition
}

/// Every signal some stream holds. Dispositions are process-wide, so streams
/// share them: the first to take a signal over sets it, the last to let go
/// restores it.
private let holds = Mutex<[Int32: Hold]>([:])

/// Takes over `signal`'s disposition, unless another stream already did.
func hold(_ signal: Int32) {
    holds.withLock { holds in
        if holds[signal] != nil {
            holds[signal]?.streams += 1
        } else {
            holds[signal] = Hold(streams: 1, previous: Disposition.takeOver(signal))
        }
    }
}

/// Lets go of `signal`; the last stream holding it restores its disposition.
func letGo(_ signal: Int32) {
    holds.withLock { holds in
        guard let hold = holds[signal] else { return }
        if hold.streams > 1 {
            holds[signal]?.streams -= 1
        } else {
            holds[signal] = nil
            hold.previous.restore()
        }
    }
}
