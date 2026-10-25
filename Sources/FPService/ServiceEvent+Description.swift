extension ServiceEvent: CustomStringConvertible {
    /// A short line for logs, e.g. `shutting down (signal 15)`.
    public var description: String {
        switch self {
            case .started: "started"
            case .ready: "ready"
            case .signal(let signal): "signal \(signal)"
            case .shuttingDown(let reason): "shutting down (\(reason))"
            case .cancelling(let reason): "cancelling (\(reason))"
            case .stopped(let outcome): "stopped (\(outcome))"
        }
    }
}

extension ShutdownReason: CustomStringConvertible {
    /// A short phrase for logs, e.g. `signal 15`.
    public var description: String {
        switch self {
            case .serveReturned: "serve returned"
            case .signal(let signal): "signal \(signal)"
        }
    }
}

extension CancellationReason: CustomStringConvertible {
    /// A short phrase for logs, e.g. `shutdown took longer than 10.0 seconds`.
    public var description: String {
        switch self {
            case .signal(let signal): "signal \(signal)"
            case .shutdownTimeout(let after): "shutdown took longer than \(after)"
            case .caller: "caller cancelled"
        }
    }
}

extension ServiceOutcome: CustomStringConvertible {
    /// A short line for logs, e.g. `signal 15, stopped in 0.5 seconds` or
    /// `signal 15, stopped in 0.1 seconds, cancelled (signal 15)`.
    public var description: String {
        let shutdown = shutdownReason.map { "\($0)" } ?? "no graceful shutdown"
        let duration = stopDuration.map { ", stopped in \($0)" } ?? ""
        let cancelled = cancellationReason.map { ", cancelled (\($0))" } ?? ""
        return shutdown + duration + cancelled
    }
}
