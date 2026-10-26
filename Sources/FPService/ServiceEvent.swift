/// A step in a service's life, delivered to the observer as
/// `.success(event)` in ``ServiceEvents``. Failures arrive as `.failure`, each
/// once, where it happens: `signalsUnavailable`, `startFailed`, `serveFailed`,
/// `shutdownTimeout(after:)` and `stopFailed`. The run's result combines them.
///
/// In order: `started`, `ready`, then — as they happen — `signal`,
/// `shuttingDown`, `cancelling`, and finally `stopped`.
public enum ServiceEvent: Sendable, Equatable {
    /// Acquire began.
    case started
    /// Acquire succeeded; `serve` began.
    case ready
    /// A signal from `shutdownSignals` arrived. Comes before the stage change
    /// it causes.
    case signal(Int32)
    /// Stage 1, the graceful shutdown, began.
    case shuttingDown(ShutdownReason)
    /// Stage 2 began: the service is being cancelled.
    case cancelling(CancellationReason)
    /// Dispose finished: the last event of a service that started. An
    /// observer cancelled with the calling task may miss it.
    case stopped(ServiceOutcome)
}

/// Why the graceful shutdown (stage 1) began.
public enum ShutdownReason: Sendable, Equatable {
    /// `serve` returned.
    case serveReturned
    /// A signal arrived.
    case signal(Int32)
}

/// Why the service was cancelled (stage 2).
public enum CancellationReason: Sendable, Equatable {
    /// A signal arrived during the graceful shutdown.
    case signal(Int32)
    /// The graceful shutdown outlasted `shutdownTimeout`.
    case shutdownTimeout(after: Duration)
    /// The task that called the service was cancelled.
    case caller
}

/// Every event of one run, in order. It finishes after the last event.
public typealias ServiceEvents<Failure: Error> = AsyncStream<
    Result<ServiceEvent, ServiceError<Failure>>
>
