#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FPBracket
@testable import FPService

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
/// in a sibling task instead.
func run<Resource>(
    _ harness: Harness,
    shutdownSignals: [Int32] = [SIGTERM],
    shutdownTimeout: Duration? = nil,
    clock: ServiceClock = .continuous,
    observe: Bool = true,
    serve mode: ServeMode? = .untilShutdown,
    waitingFor entries: [String] = [],
    then act: @escaping @Sendable () async -> Void = {},
    _ service: @escaping @Sendable () -> BracketAsync<Resource, TestError>
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
                signalStream: { taken in
                    log.append("signals taken: \(taken)")
                    return signals
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
        case .success(.started): "started"
        case .success(.ready): "ready"
        case .success(.signal(let signal)): "signal \(signal)"
        case .success(.shuttingDown(.serveReturned)): "shutting down: serve returned"
        case .success(.shuttingDown(.signal(let signal))): "shutting down: signal \(signal)"
        case .success(.cancelling(.signal(let signal))): "cancelling: signal \(signal)"
        case .success(.cancelling(.shutdownTimeout)): "cancelling: shutdown timeout"
        case .success(.cancelling(.caller)): "cancelling: caller"
        case .success(.stopped): "stopped"
        case .failure(.startFailed): "failed: start"
        case .failure(.serveFailed): "failed: serve"
        case .failure(.stopFailed): "failed: stop"
        case .failure(.serveAndStopFailed): "failed: serve and stop"
        case .failure(.shutdownTimeout): "failed: shutdown timeout"
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
