import ProcessSignals

/// Why a service run failed, by phase.
///
/// `Failure` is the service bracket's own error type, passed through
/// untouched so a host can switch on it:
///
/// ```swift
/// if case .startFailed(.unavailable) = error { … }
/// ```
///
/// The core does not import Foundation, so this is not a `LocalizedError`;
/// `errorDescription` has the same meaning, and a host that uses Foundation
/// can add the conformance in one line.
public enum ServiceError<Failure: Error>: Error, CustomStringConvertible {
    /// These shutdown signals could not be subscribed to, so nothing ran:
    /// without them, the signal would end the process mid-run, skipping
    /// dispose.
    case signalsUnavailable([Int32])
    /// Acquire failed; `serve` and dispose were skipped.
    case startFailed(Failure)
    /// `serve` failed; dispose then ran cleanly.
    case serveFailed(Failure)
    /// Dispose failed.
    case stopFailed(Failure)
    /// `serve` failed, and so did the dispose that followed.
    case serveAndStopFailed(serve: Failure, stop: Failure)
    /// The graceful shutdown outlasted `shutdownTimeout`, so the service was
    /// cancelled. Carries the `serve` and dispose failures, if there were any:
    /// the timeout comes first, as the reason the service was cancelled.
    case shutdownTimeout(after: Duration, serve: Failure? = nil, stop: Failure? = nil)

    /// The phase the failure happened in.
    public var phase: ServicePhase {
        switch self {
            case .signalsUnavailable, .startFailed: .start
            case .serveFailed, .serveAndStopFailed: .serve
            case .stopFailed, .shutdownTimeout: .stop
        }
    }

    /// The service's own error, if the failure came from it (the `serve`
    /// error when there are two, for ``serveAndStopFailed(serve:stop:)`` and
    /// ``shutdownTimeout(after:serve:stop:)``).
    public var failure: Failure? {
        switch self {
            case .signalsUnavailable:
                nil
            case .startFailed(let error), .serveFailed(let error), .stopFailed(let error):
                error
            case .serveAndStopFailed(let error, _):
                error
            case .shutdownTimeout(_, let serve, let stop):
                serve ?? stop
        }
    }

    /// A sentence describing the failure, with the service's own error.
    /// Same meaning as `LocalizedError.errorDescription`.
    public var errorDescription: String? {
        switch self {
            case .signalsUnavailable(let signals):
                "Service could not subscribe to "
                    + signals.map(signalName).joined(separator: ", ")
                    + ", so it did not start."
            case .startFailed(let error): "Service failed to start: \(error)"
            case .serveFailed(let error): "Service failed while serving: \(error)"
            case .stopFailed(let error): "Service failed to stop: \(error)"
            case .serveAndStopFailed(let serve, let stop):
                "Service failed while serving: \(serve); then failed to stop: \(stop)"
            case .shutdownTimeout(let after, let serve, let stop):
                "Service did not shut down within \(format(after)) and was cancelled."
                    + (serve.map { " It had failed while serving: \($0)." } ?? "")
                    + (stop.map { " It failed to stop: \($0)." } ?? "")
        }
    }

    /// The same as ``errorDescription``.
    public var description: String { errorDescription ?? "ServiceError" }
}

extension ServiceError: Equatable where Failure: Equatable {}

/// The three phases of a service.
public enum ServicePhase: String, Sendable, Equatable {
    /// The bracket's acquire.
    case start
    /// The service body, `serve`.
    case serve
    /// The bracket's dispose.
    case stop
}
