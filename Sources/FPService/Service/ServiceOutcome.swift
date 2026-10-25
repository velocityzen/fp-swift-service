/// How a service run ended without failing. Hosts log it; tests assert on it.
///
/// Each reason is what the matching event said: `shutdownReason` that of
/// `.shuttingDown`, `cancellationReason` that of `.cancelling`.
public struct ServiceOutcome: Sendable, Equatable {
    /// Why the graceful shutdown began; `nil` if there was none (the caller
    /// cancelled while the service was running).
    public let shutdownReason: ShutdownReason?
    /// Why the service was cancelled; `nil` if it stopped gracefully.
    public let cancellationReason: CancellationReason?
    /// From the end of `serve` to the end of dispose, on the run's
    /// ``ServiceClock``; `nil` if `serve` never ran.
    public let stopDuration: Duration?

    /// Creates an outcome; ``Service`` builds them, tests compare against them.
    public init(
        shutdownReason: ShutdownReason?,
        cancellationReason: CancellationReason?,
        stopDuration: Duration?
    ) {
        self.shutdownReason = shutdownReason
        self.cancellationReason = cancellationReason
        self.stopDuration = stopDuration
    }
}
