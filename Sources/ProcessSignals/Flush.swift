#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(CRT)
    import CRT
    import WinSDK
#endif
import Dispatch
import Synchronization

/// Flushes every output stream (`fflush(nil)`) on a thread of its own, and
/// waits at most `limit` for it: a flush stuck on a stalled stream is left
/// behind. The deadline is on the monotonic clock, so sleeps that overrun
/// on a busy machine don't stretch it.
func flushOutput(within limit: Duration) {
    let flush = Flush()
    DispatchQueue(label: "ProcessSignals.flush").async { flush.run() }
    let deadline = ContinuousClock.now + limit
    while !flush.isDone, ContinuousClock.now < deadline {
        sleepAMillisecond()
    }
}

/// Sleeps for about a millisecond.
private func sleepAMillisecond() {
    #if os(Windows)
        Sleep(1)
    #else
        var tick = timespec()
        tick.tv_nsec = 1_000_000
        nanosleep(&tick, nil)
    #endif
}

/// One flush of every output stream, and whether it has returned.
private final class Flush: Sendable {
    private let done = Atomic(false)

    var isDone: Bool { done.load(ordering: .acquiring) }

    func run() {
        fflush(nil)
        done.store(true, ordering: .releasing)
    }
}
