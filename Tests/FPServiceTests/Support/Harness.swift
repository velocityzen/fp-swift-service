#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import FPBracket
@testable import FPService
import ServiceTestSupport

/// Fake signals for one run: the test sends them as values, and stage 3 is
/// recorded instead of ending the process.
final class Harness: Sendable {
    let log = Recorder()
    let signals: AsyncStream<Int32>
    private let input: AsyncStream<Int32>.Continuation

    init() {
        (signals, input) = AsyncStream<Int32>.makeStream()
        input.onTermination = { [log] _ in log.append("signals ended") }
    }

    func send(_ signal: Int32) {
        input.yield(signal)
    }
}

/// Runs a service under a deadline. Once every entry in `waitingFor` has been
/// recorded, runs `act` next to it (typically sending a signal).
///
/// The service is built inside the run: it is `~Copyable`, so the action runs
/// in a sibling task instead. Signals in `unavailable` are not subscribed to.
func run<Resource>(
    _ harness: Harness,
    shutdownSignals: [Int32] = [SIGTERM],
    unavailable: [Int32] = [],
    shutdownTimeout: Duration? = nil,
    clock: ServiceClock = .continuous,
    observe: Bool = true,
    serve mode: ServeMode? = .untilShutdown,
    waitingFor entries: [String] = [],
    then act: @escaping @Sendable () async -> Void = {},
    service: @escaping @Sendable () -> BracketAsync<Resource, TestError>
) async throws -> Result<ServiceOutcome, ServiceError<TestError>> {
    try await withDeadline {
        await withTaskGroup(of: Void.self) { group in
            let log = harness.log
            let signals = harness.signals
            group.addTask {
                for entry in entries { await log.wait(for: entry) }
                guard !Task.isCancelled else { return }
                await act()
            }

            var observer: ((ServiceEvents<TestError>) async -> Void)?
            if observe {
                observer = { events in
                    for await event in events { log.append("event: \(describe(event))") }
                    log.append("observer done")
                }
            }
            let withService = Service(
                service(),
                shutdownSignals: shutdownSignals,
                shutdownTimeout: shutdownTimeout,
                clock: clock,
                signalStream: { requested in
                    let subscribed = requested.filter { !unavailable.contains($0) }
                    log.append("signals subscribed: \(subscribed)")
                    return (signals, subscribed, requested.filter(unavailable.contains))
                },
                terminate: { log.append("terminate: \($0)") },
                observe: observer
            )

            let result: Result<ServiceOutcome, ServiceError<TestError>>
            if let mode {
                result = await withService(serving(mode, log))
            } else {
                result = await withService()
            }
            log.append("returned")
            group.cancelAll()
            return result
        }
    }
}

/// A short, stable name for an event, for comparing sequences.
func describe(_ event: Result<ServiceEvent, ServiceError<TestError>>) -> String {
    switch event {
        case .success(let event): describe(event)
        case .failure(let error): describe(error)
    }
}

private func describe(_ event: ServiceEvent) -> String {
    switch event {
        case .started: "started"
        case .ready: "ready"
        case .signal(let signal): "signal \(signal)"
        case .shuttingDown(.serveReturned): "shutting down: serve returned"
        case .shuttingDown(.signal(let signal)): "shutting down: signal \(signal)"
        case .cancelling(.signal(let signal)): "cancelling: signal \(signal)"
        case .cancelling(.shutdownTimeout): "cancelling: shutdown timeout"
        case .cancelling(.caller): "cancelling: caller"
        case .stopped: "stopped"
    }
}

private func describe(_ error: ServiceError<TestError>) -> String {
    switch error {
        case .signalsUnavailable(let signals): "failed: signals unavailable \(signals)"
        case .startFailed: "failed: start"
        case .serveFailed: "failed: serve"
        case .stopFailed: "failed: stop"
        case .serveAndStopFailed: "failed: serve and stop"
        case .shutdownTimeout: "failed: shutdown timeout"
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
