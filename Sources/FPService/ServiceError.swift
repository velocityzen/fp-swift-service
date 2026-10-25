/// Why a service run failed, by phase.
///
/// `Failure` is the service bracket's own error type, passed through
/// untouched so a host can switch on it:
///
/// ```swift
/// if case .startFailed(.portInUse(let port)) = error { … }
/// ```
///
/// The core does not import Foundation, so this is not a `LocalizedError`;
/// `errorDescription` has the same meaning, and a host that uses Foundation
/// can add the conformance in one line.
public indirect enum ServiceError<Failure: Error>: Error, CustomStringConvertible {
    /// Acquire failed; `serve` and dispose were skipped.
    case startFailed(Failure)
    /// `serve` failed; dispose then ran cleanly.
    case serveFailed(Failure)
    /// Dispose failed.
    case stopFailed(Failure)
    /// `serve` failed, and so did the dispose that followed.
    case serveAndStopFailed(serve: Failure, stop: Failure)
    /// The graceful shutdown outlasted `shutdownTimeout`, so the service was cancelled.
    case shutdownTimeout(after: Duration)

    /// The phase the failure happened in.
    public var phase: ServicePhase {
        switch self {
            case .startFailed: .start
            case .serveFailed, .serveAndStopFailed: .serve
            case .stopFailed, .shutdownTimeout: .stop
        }
    }

    /// The service's own error, if the failure came from it (the `serve`
    /// error, for ``serveAndStopFailed(serve:stop:)``).
    public var failure: Failure? {
        switch self {
            case .startFailed(let error), .serveFailed(let error), .stopFailed(let error):
                error
            case .serveAndStopFailed(let error, _):
                error
            case .shutdownTimeout:
                nil
        }
    }

    public var errorDescription: String? {
        switch self {
            case .startFailed(let error): "Service failed to start: \(error)"
            case .serveFailed(let error): "Service failed while serving: \(error)"
            case .stopFailed(let error): "Service failed to stop: \(error)"
            case .serveAndStopFailed(let serve, let stop):
                "Service failed while serving: \(serve); then failed to stop: \(stop)"
            case .shutdownTimeout(let after): "Service did not shut down within \(after) and was cancelled."
        }
    }

    public var description: String { errorDescription ?? "ServiceError" }
}

/// The three phases of a service.
public enum ServicePhase: String, Sendable, Equatable {
    case start
    case serve
    case stop
}
