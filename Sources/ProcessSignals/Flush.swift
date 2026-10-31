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
    import WinSDK
#endif
import Dispatch
import Synchronization

/// Flushes every output stream (`fflush(nil)`) on a thread of its own, and
/// waits at most `limit` for it: a flush stuck on a stalled stream is left
/// behind. The deadline is on the monotonic clock, so sleeps that overrun
/// on a busy machine don't stretch it. A failed flush is ignored: the
/// process is about to end, and there is nothing to retry and nowhere to
/// report it.
func flushOutput(within limit: Duration) {
    let done = Atomic(false)

    DispatchQueue(label: "ProcessSignals.flush").async {
        fflush(nil)
        done.store(true, ordering: .releasing)
    }

    let deadline = ContinuousClock.now + limit
    while !done.load(ordering: .acquiring), ContinuousClock.now < deadline {
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
