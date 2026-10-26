import ProcessSignals

extension ServiceEvent: CustomStringConvertible {
    /// A short line for logs, e.g. `shutting down (SIGTERM)`.
    public var description: String {
        switch self {
            case .started: "started"
            case .ready: "ready"
            case .signal(let signal): signalName(signal)
            case .shuttingDown(let reason): "shutting down (\(reason))"
            case .cancelling(let reason): "cancelling (\(reason))"
            case .stopped(let outcome): "stopped (\(outcome))"
        }
    }
}

extension ShutdownReason: CustomStringConvertible {
    /// A short phrase for logs, e.g. `SIGTERM`.
    public var description: String {
        switch self {
            case .serveReturned: "serve returned"
            case .signal(let signal): signalName(signal)
        }
    }
}

extension CancellationReason: CustomStringConvertible {
    /// A short phrase for logs, e.g. `shutdown took longer than 10 s`.
    public var description: String {
        switch self {
            case .signal(let signal): signalName(signal)
            case .shutdownTimeout(let after): "shutdown took longer than \(format(after))"
            case .caller: "caller cancelled"
        }
    }
}

extension ServiceOutcome: CustomStringConvertible {
    /// A short line for logs, e.g. `SIGTERM, shut down in 1.2 s, stopped in
    /// 0.5 ms` or `SIGTERM, shut down in 0.1 ms, stopped in 0.1 ms, cancelled
    /// (SIGINT)`.
    public var description: String {
        let shutdown = shutdownReason.map { "\($0)" } ?? "no graceful shutdown"
        let shutdownTime = shutdownDuration.map { ", shut down in \(format($0))" } ?? ""
        let stopTime = stopDuration.map { ", stopped in \(format($0))" } ?? ""
        let cancelled = cancellationReason.map { ", cancelled (\($0))" } ?? ""
        return shutdown + shutdownTime + stopTime + cancelled
    }
}

/// A duration for a log line, to three decimals: in seconds from one second
/// up, in milliseconds below it — `10 s`, `1.5 s`, `250 ms`, `0.042 ms`.
/// (`Duration`'s own description switches to exponents: `9.542e-06 seconds`.)
func format(_ duration: Duration) -> String {
    if duration < .zero { return "-" + format(.zero - duration) }
    let (seconds, attoseconds) = duration.components
    let microseconds = (attoseconds + 500_000_000_000) / 1_000_000_000_000
    if seconds == 0, microseconds < 1_000_000 {
        return decimal(microseconds / 1000, thousandths: microseconds % 1000) + " ms"
    }
    let milliseconds = (attoseconds + 500_000_000_000_000) / 1_000_000_000_000_000
    return decimal(seconds + milliseconds / 1000, thousandths: milliseconds % 1000) + " s"
}

/// `whole.thousandths`, without trailing zeros: `2`, `2.5`, `2.042`.
private func decimal(_ whole: Int64, thousandths: Int64) -> String {
    guard thousandths > 0 else { return "\(whole)" }
    var digits = String(thousandths + 1000).dropFirst()
    while digits.last == "0" { digits.removeLast() }
    return "\(whole).\(digits)"
}
