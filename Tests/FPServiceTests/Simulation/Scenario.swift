#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#elseif canImport(CRT)
    import CRT
#endif
import FPBracket
@testable import FPService
import Synchronization

/// One randomly generated run: the services, what the body does, and what
/// happens to the run from outside. Times are multiples of 250 ms, so
/// things often coincide, which is where interleavings matter.
struct Scenario: Sendable, CustomStringConvertible {
    struct Phase: Sendable {
        var duration: Duration
        var fails: Bool
        /// Ignores cancellation, as cleanup in `uncancellableDispose` does.
        var ignoresCancellation: Bool
    }

    struct Bracket: Sendable {
        var name: String
        var acquire: Phase
        var dispose: Phase
    }

    enum Body: Sendable {
        /// Waits for shutdown, then takes `drain` to finish.
        case untilShutdown(drain: Duration)
        /// Returns by itself after `after`, which stops the service.
        case finish(after: Duration)
        /// Returns only when cancelled.
        case ignoreShutdown
        /// Work that `withCancellation(on:_:)` cancels on shutdown.
        case cancelOnShutdown(work: Duration)
        /// A shutdown handler that keeps its thread busy for `blocks`, with
        /// work that returns `after` the shutdown request.
        case handler(blocks: Duration, after: Duration)
    }

    var brackets: [Bracket]
    var body: Body
    var bodyFails: Bool
    var signals: [(at: Duration, signal: Int32)]
    var callerCancels: Duration?
    var shutdownTimeout: Duration?
    var observes: Bool

    /// Generous: every phase is finite, so once the caller has cancelled,
    /// every run ends. A run still going at `backstop` is a hang.
    static let backstop: Duration = .seconds(100)

    init(seed: UInt64) {
        var random = SplitMix64(seed: seed ^ 0x5CE7_A210)
        func time(upTo quarters: Int) -> Duration {
            .milliseconds(250 * Int.random(in: 0...quarters, using: &random))
        }
        func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &random) < percent }
        func phase() -> Phase {
            Phase(duration: time(upTo: 4), fails: chance(15), ignoresCancellation: chance(25))
        }

        brackets = (0..<Int.random(in: 1...3, using: &random)).map { index in
            Bracket(name: ["a", "b", "c"][index], acquire: phase(), dispose: phase())
        }
        body =
            switch Int.random(in: 0..<5, using: &random) {
                case 0: .untilShutdown(drain: time(upTo: 4))
                case 1: .finish(after: time(upTo: 12))
                case 2: .ignoreShutdown
                case 3: .cancelOnShutdown(work: time(upTo: 12))
                default: .handler(blocks: time(upTo: 4), after: time(upTo: 2))
            }
        bodyFails = chance(15)
        signals = (0..<Int.random(in: 0...3, using: &random)).map { _ in
            (time(upTo: 16), [SIGTERM, SIGINT][Int.random(in: 0...1, using: &random)])
        }
        .sorted { $0.at < $1.at }
        callerCancels = chance(30) ? time(upTo: 16) : nil
        shutdownTimeout = chance(50) ? time(upTo: 12) : nil
        observes = chance(80)
    }

    var description: String {
        let brackets = brackets.map { bracket in
            "\(bracket.name)(acquire \(summary(of: bracket.acquire)), dispose \(summary(of: bracket.dispose)))"
        }
        return """
            brackets: \(brackets.joined(separator: ", "))
            body: \(body)\(bodyFails ? ", fails" : "")
            signals: \(signals.map { "\($0.signal) at \($0.at)" })
            caller cancels: \(callerCancels.map { "\($0)" } ?? "never")
            shutdown timeout: \(shutdownTimeout.map { "\($0)" } ?? "none")
            observer: \(observes)
            """
    }

    private func summary(of phase: Phase) -> String {
        "\(phase.duration)" + (phase.fails ? ", fails" : "")
            + (phase.ignoresCancellation ? ", ignores cancellation" : "")
    }
}

/// What one simulated run did: everything it recorded, in order, and its
/// result.
struct Run: Sendable {
    let trace: [String]
    let result: Result<ServiceOutcome, ServiceError<TestError>>
}

extension Scenario {
    /// Runs this scenario under `simulation`; `nil` if it never finished.
    func run(in simulation: Simulation) async -> Run? {
        let scenario = self
        return await simulation.run {
            let log = Recorder()
            let (signals, input) = AsyncStream<Int32>.makeStream()
            let service = Task(executorPreference: simulation) {
                let withService = Service(
                    scenario.composed(log, simulation),
                    shutdownSignals: [SIGTERM, SIGINT],
                    shutdownTimeout: scenario.shutdownTimeout,
                    clock: ServiceClock(simulation.clock),
                    signalStream: { requested in (signals, requested, []) },
                    terminate: { log.append("terminate \($0)") },
                    taskExecutor: simulation,
                    offload: { await simulation.offload($0) },
                    observe: scenario.observes
                        ? { events in
                            for await event in events { log.append("event: \(describe(event))") }
                        } : nil
                )
                return await withService(scenario.serve(log, simulation))
            }
            // From outside the run, as a process and its parent would.
            return await withTaskGroup(of: Void.self) { outside in
                outside.addTask {
                    var now: Duration = .zero
                    for (at, signal) in scenario.signals {
                        try? await simulation.clock.sleep(for: at - now)
                        now = at
                        log.append("send \(signal)")
                        input.yield(signal)
                    }
                }
                outside.addTask {
                    try? await simulation.clock.sleep(for: scenario.callerCancels ?? Self.backstop)
                    if scenario.callerCancels == nil { log.append("backstop") }
                    log.append("cancel caller")
                    service.cancel()
                }
                let result = await service.value
                log.append("returned")
                outside.cancelAll()
                return Run(trace: log.all, result: result)
            }
        }
    }

    /// The brackets composed in order, each recording its phases.
    private func composed(
        _ log: Recorder,
        _ simulation: Simulation
    ) -> BracketAsync<[String], TestError> {
        let brackets = brackets.map { bracket in
            BracketAsync<String, TestError>(
                acquire: {
                    log.append("acquire \(bracket.name)")
                    await bracket.acquire.take(simulation)
                    guard !bracket.acquire.fails else {
                        log.append("acquire failed \(bracket.name)")
                        return .failure(.boom("acquire \(bracket.name)"))
                    }
                    log.append("acquired \(bracket.name)")
                    return .success(bracket.name)
                },
                dispose: { _ in
                    log.append("dispose \(bracket.name)\(Task.isCancelled ? " cancelled" : "")")
                    await bracket.dispose.take(simulation)
                    guard !bracket.dispose.fails else {
                        log.append("dispose failed \(bracket.name)")
                        return .failure(.boom("dispose \(bracket.name)"))
                    }
                    log.append("disposed \(bracket.name)")
                    return .success(())
                }
            )
        }
        return brackets.dropFirst().reduce(brackets[0].map { [$0] }) { composed, next in
            composed.flatMap { names in next.map { names + [$0] } }
        }
    }

    /// The body, recording when it starts and how it returns.
    private func serve(
        _ log: Recorder,
        _ simulation: Simulation
    ) -> @concurrent ([String], Shutdown) async -> Result<Void, TestError> {
        let (body, fails, clock) = (body, bodyFails, simulation.clock)
        return { _, shutdown in
            log.append("serve")
            switch body {
                case .untilShutdown(let drain):
                    await shutdown.requested
                    try? await clock.sleep(for: drain)
                case .finish(let after):
                    try? await clock.sleep(for: after)
                case .ignoreShutdown:
                    await Shutdown().requested  // never requested: returns only when cancelled
                case .cancelOnShutdown(let work):
                    _ = await withCancellation(on: shutdown) { () -> Result<Void, TestError> in
                        try? await clock.sleep(for: work)
                        return .success(())
                    }
                case .handler(let blocks, let after):
                    let handler: @Sendable () -> Void = {
                        log.append("handler")
                        simulation.block(for: blocks) { log.append("handler returned") }
                    }
                    await withShutdownHandler(on: shutdown, handler) {
                        await shutdown.requested
                        try? await clock.sleep(for: after)
                    }
            }
            log.append(fails ? "served failed" : "served")
            return fails ? .failure(.boom("serve")) : .success(())
        }
    }
}

extension Scenario.Phase {
    /// Takes the phase's time; stops early if cancelled, unless it ignores
    /// cancellation.
    fileprivate func take(_ simulation: Simulation) async {
        let clock = simulation.clock
        if ignoresCancellation {
            await Task(executorPreference: simulation) { try? await clock.sleep(for: duration) }
                .value
        } else {
            try? await clock.sleep(for: duration)
        }
    }
}
