// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif
    import FPBracket
    @testable import FPService
    import HegelTesting
    import ServiceTestSupport
    import Synchronization

    /// One generated run: the services, what the body does, and what happens to
    /// the run from outside. Times are multiples of one grid step, so things
    /// often coincide, which is where interleavings matter.
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
        /// When each line of the trace was recorded, on the simulated clock.
        let times: [Duration]
        let result: Result<ServiceOutcome, ServiceError<TestError>>
    }

    extension Scenario {
        /// Runs this scenario under `simulation`; `nil` if it never finished.
        func run(in simulation: Simulation) async -> Run? {
            let scenario = self
            return await simulation.run {
                let log = Log(now: { simulation.now })
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
                                for await event in events {
                                    log.append("event: \(describe(event))")
                                }
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
                        try? await simulation.clock.sleep(
                            for: scenario.callerCancels ?? Self.backstop
                        )
                        if scenario.callerCancels == nil { log.append("backstop") }
                        log.append("cancel caller")
                        service.cancel()
                    }
                    let result = await service.value
                    log.append("returned")
                    outside.cancelAll()
                    return Run(trace: log.all, times: log.times, result: result)
                }
            }
        }

        /// The brackets composed in order, each recording its phases.
        private func composed(
            _ log: Log,
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
            _ log: Log,
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

    /// Scenarios, each drawn under a policy of its own: how often phases fail
    /// and ignore cancellation, how many signals come, how far apart things
    /// happen. Simplest first, so a failing scenario shrinks toward one bracket,
    /// a body that waits for shutdown, nothing from outside, no observer.
    enum ScenarioGen {
        /// Some failures first, so a failure shrinks toward the mix; then none,
        /// and often.
        static let rate: Gen<Double> = .element(of: [0.15, 0.0, 0.5])
        /// The grid: everything at once, or things a quarter or a whole second
        /// apart.
        static let grid: Gen<Duration> = .element(of: [.milliseconds(250), .zero, .seconds(1)])

        static let scenario: Gen<Scenario> = Gen { tc in
            // Acquire fails less often: one failure skips serve, which is where
            // most of what can go wrong is.
            let acquireFails = try tc.draw(.element(of: [0.05, 0.0, 0.3]))
            let fails = try tc.draw(rate)
            let ignores = try tc.draw(.element(of: [0.25, 0.0, 1.0]))
            let grid = try tc.draw(grid)
            // How many grid steps what comes from outside spreads over: the whole
            // run, or (tight) the few steps a stop takes, so a second signal or
            // the timeout lands while a handler or a dispose still runs.
            let spread = try tc.draw(.element(of: [16, 4]))
            func time(upTo steps: Int) throws -> Duration {
                grid * (try tc.draw(.int(in: 0...steps)))
            }
            func phase(failing rate: Double) throws -> Scenario.Phase {
                Scenario.Phase(
                    duration: try time(upTo: 4),
                    fails: try tc.draw(.bool(probability: rate)),
                    ignoresCancellation: try tc.draw(.bool(probability: ignores))
                )
            }
            let count = try tc.draw(.int(in: 1...3))
            let brackets = try (0..<count).map { index in
                Scenario.Bracket(
                    name: ["a", "b", "c"][index],
                    acquire: try phase(failing: acquireFails),
                    dispose: try phase(failing: fails)
                )
            }
            let body: Scenario.Body =
                // Any body, or (as often) one with a shutdown handler: where serve
                // returns while the handler still runs, and dispose waits.
                switch try tc.draw(.oneOf(.int(in: 0...4), .just(4))) {
                    case 0: .untilShutdown(drain: try time(upTo: 4))
                    case 1: .finish(after: try time(upTo: 12))
                    case 2: .ignoreShutdown
                    case 3: .cancelOnShutdown(work: try time(upTo: 12))
                    default: .handler(blocks: try time(upTo: 8), after: try time(upTo: 2))
                }
            let signalCount = try tc.draw(.oneOf(.int(in: 0...3), .int(in: 0...8)))
            let signals = try (0..<signalCount).map { _ in
                (at: try time(upTo: spread), signal: try tc.draw(.element(of: [SIGTERM, SIGINT])))
            }
            return Scenario(
                brackets: brackets,
                body: body,
                bodyFails: try tc.draw(.bool(probability: fails)),
                signals: signals.sorted { $0.at < $1.at },
                callerCancels: try tc.draw(.optional(.int(in: 0...spread))).map { grid * $0 },
                shutdownTimeout: try tc.draw(.optional(.int(in: 0...min(12, spread)))).map {
                    grid * $0
                },
                observes: try tc.draw(.bool(probability: 0.8))
            )
        }

        /// A run whose `serve` returns in stage 1 while its shutdown handler
        /// still runs, so dispose waits for the handler; then stage 2 begins
        /// before the handler returns, by a second signal, the timeout or the
        /// caller. Nothing fails, and the observer is on, so the trace shows
        /// when stage 2 began.
        static let cancelledWhileHandlerRuns: Gen<Scenario> = Gen { tc in
            let grid: Duration = .milliseconds(250)
            let returnsAfter = try tc.draw(.int(in: 0...2))
            let blocks = returnsAfter + (try tc.draw(.int(in: 2...6)))
            let first = grid * (try tc.draw(.int(in: 0...2)))
            // Strictly inside the window, after serve returned.
            let into = grid * (try tc.draw(.int(in: (returnsAfter + 1)...(blocks - 1))))
            let calm = Scenario.Phase(duration: .zero, fails: false, ignoresCancellation: false)
            var scenario = Scenario(
                brackets: try (0..<(try tc.draw(.int(in: 1...3)))).map { index in
                    Scenario.Bracket(name: ["a", "b", "c"][index], acquire: calm, dispose: calm)
                },
                body: .handler(blocks: grid * blocks, after: grid * returnsAfter),
                bodyFails: false,
                signals: [(at: first, signal: SIGTERM)],
                callerCancels: nil,
                shutdownTimeout: nil,
                observes: true
            )
            switch try tc.draw(.int(in: 0...2)) {
                case 0: scenario.signals.append((at: first + into, signal: SIGINT))
                case 1: scenario.shutdownTimeout = into
                default: scenario.callerCancels = first + into
            }
            return scenario
        }

        /// The order the simulation runs ready jobs in: small choices usually,
        /// any sometimes. The empty schedule runs them in the order they became
        /// ready, and failures shrink toward it.
        static let schedule: Gen<[Int]> = .oneOf(
            .array(of: .int(in: 0...3)),
            .array(of: .int(in: 0...Int.max), count: 20...400)
        )
    }

#endif
