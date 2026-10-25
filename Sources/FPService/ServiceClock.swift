/// The clock deadlines and stop durations are measured with.
///
/// Production code uses ``continuous`` (a `ContinuousClock`). Tests build one
/// from a manual `Clock` so deadlines elapse when the test advances time and
/// no test ever sleeps. Only `Duration` crosses this boundary.
public struct ServiceClock: Sendable {
    /// Time elapsed since the clock was created.
    let now: @Sendable () -> Duration
    /// Suspends for `duration`; returns early if the task is cancelled.
    let sleep: @Sendable (Duration) async -> Void

    /// Wraps any clock measured in `Duration`.
    public init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { duration in
            try? await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
        }
    }

    /// The default: `ContinuousClock`.
    public static var continuous: ServiceClock { ServiceClock(ContinuousClock()) }
}
