// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import FPService
    import Synchronization

    /// The failure every service in these properties fails with: where it
    /// failed.
    enum TestError: Error, Equatable, CustomStringConvertible {
        case boom(String)

        var description: String {
            switch self {
                case .boom(let place): "boom(\(place))"
            }
        }
    }

    /// An ordered record of what happened, shared by a run's brackets, its
    /// `serve`, its observer and the test.
    final class Log: Sendable {
        private let entries = Mutex<[(entry: String, at: Duration)]>([])
        private let now: @Sendable () -> Duration

        /// A log whose entries are stamped with `now`; by default, with none.
        init(now: @escaping @Sendable () -> Duration = { .zero }) { self.now = now }

        func append(_ entry: String) {
            let at = now()
            entries.withLock { $0.append((entry, at)) }
        }

        var all: [String] { entries.withLock { $0.map(\.entry) } }

        /// When each entry was recorded.
        var times: [Duration] { entries.withLock { $0.map(\.at) } }
    }

    /// A short, stable name for an event, for traces.
    func describe(_ event: Result<ServiceEvent, ServiceError<TestError>>) -> String {
        switch event {
            case .success(.started): "started"
            case .success(.ready): "ready"
            case .success(.signal(let signal)): "signal \(signal)"
            case .success(.shuttingDown(let reason)): "shutting down: \(reason)"
            case .success(.cancelling(let reason)): "cancelling: \(reason)"
            case .success(.stopped): "stopped"
            case .failure(let error): "failed: \(name(of: error))"
        }
    }

    /// The case of `error`, without what it carries.
    func name(of error: ServiceError<TestError>) -> String {
        switch error {
            case .signalsUnavailable: "signalsUnavailable"
            case .startFailed: "startFailed"
            case .serveFailed: "serveFailed"
            case .stopFailed: "stopFailed"
            case .serveAndStopFailed: "serveAndStopFailed"
            case .shutdownTimeout: "shutdownTimeout"
        }
    }

#endif
