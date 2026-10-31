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
@testable import FPService
import Testing

@Suite("Simulation", .timeLimit(.minutes(1)))
struct SimulationTests {
    @Test("a seed is one interleaving: the same seed repeats it, others differ")
    func interleavings() async throws {
        let first = try #require(await interleave(seed: 1))
        #expect(await interleave(seed: 1) == first)
        var orders: Set<[String]> = []
        for seed in 0..<20 { orders.insert(try #require(await interleave(seed: UInt64(seed)))) }
        #expect(orders.count > 1)
    }

    @Test("the clock moves only when nothing can run, to the next deadline")
    func clock() async throws {
        let simulation = Simulation(seed: 7)
        let woken = await simulation.run {
            await withTaskGroup(of: String.self) { group in
                for (name, delay) in [("b", 2), ("a", 1), ("c", 3)] {
                    group.addTask {
                        try? await simulation.clock.sleep(for: .seconds(delay))
                        return "\(name) at \(simulation.now)"
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        #expect(woken == ["a at 1.0 seconds", "b at 2.0 seconds", "c at 3.0 seconds"])
    }

    @Test("a run that waits for what never happens is reported, not hung")
    func hang() async {
        let simulation = Simulation(seed: 3)
        let never: Void? = await simulation.run { await Shutdown().requested }
        #expect(never == nil)
    }

    @Test("a service under simulation: each seed repeats exactly, and seeds explore")
    func service() async throws {
        var traces: Set<[String]> = []
        for seed in seeds {
            let trace = try #require(await simulateService(seed: seed), "seed \(seed) hung")
            #expect(await simulateService(seed: seed) == trace, "seed \(seed) did not repeat")
            traces.insert(trace)
        }
        #expect(traces.count > 1)
    }

    @Test("the outcome doesn't depend on the interleaving")
    func outcome() async throws {
        for seed in seeds {
            let trace = try #require(await simulateService(seed: seed), "seed \(seed) hung")
            #expect(
                trace.last
                    == "result: success(SIGTERM, shut down in 500 ms, stopped in 0 ms, cancelled (SIGTERM))",
                "seed \(seed)"
            )
            #expect(
                trace.filter { $0.hasPrefix("stop") } == ["stop:a", "stopped:a"],
                "seed \(seed)"
            )
        }
    }
}

/// The seeds every simulated property runs under.
private let seeds: [UInt64] = Array(0..<200)

/// Three tasks, each recording two steps with a suspension between: the
/// order is the interleaving.
private func interleave(seed: UInt64) async -> [String]? {
    await Simulation(seed: seed).run {
        let log = Recorder()
        await withTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    log.append("\(name)1")
                    await Task.yield()
                    log.append("\(name)2")
                }
            }
        }
        return log.all
    }
}

/// One run of a service under simulation: SIGTERM a simulated second in,
/// a second SIGTERM half a second later. Returns everything recorded.
func simulateService(seed: UInt64) async -> [String]? {
    let simulation = Simulation(seed: seed)
    return await simulation.run {
        let log = Recorder()
        let (signals, input) = AsyncStream<Int32>.makeStream()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await simulation.clock.sleep(for: .seconds(1))
                input.yield(SIGTERM)
                try? await simulation.clock.sleep(for: .milliseconds(500))
                input.yield(SIGTERM)
            }
            let withService = Service(
                probe("a", log),
                shutdownSignals: [SIGTERM],
                shutdownTimeout: .seconds(5),
                clock: ServiceClock(simulation.clock),
                signalStream: { requested in (signals, requested, []) },
                terminate: { log.append("terminate: \($0)") },
                taskExecutor: simulation,
                offload: { await simulation.offload($0) },
                observe: { events in
                    for await event in events { log.append("event: \(describe(event))") }
                }
            )
            let result = await withService(serving(.ignoreShutdown, log))
            log.append("result: \(result)")
        }
        return log.all
    }
}

extension SimulationTests {
    /// Random scenarios, each under a random interleaving, checked against
    /// what any run must do. A failure names its seed: replay it alone with
    /// `SIMULATION_SEED=<seed>`; `SIMULATION_SEEDS=<n>` runs more.
    @Test("random scenarios keep every invariant")
    func scenarios() async {
        for seed in scenarioSeeds {
            let scenario = Scenario(seed: seed)
            guard let run = await scenario.run(in: Simulation(seed: seed)) else {
                Issue.record("seed \(seed) hung\n\(scenario)")
                continue
            }
            let broken = run.violations(of: scenario)
            #expect(
                broken.isEmpty,
                """
                seed \(seed): \(broken.joined(separator: "; "))
                \(scenario)
                result: \(run.result)
                trace:
                \(run.trace.joined(separator: "\n"))
                """
            )
        }
    }
}

/// `SIMULATION_SEED` replays one seed; `SIMULATION_SEEDS` sets how many run.
private let scenarioSeeds: [UInt64] = {
    func variable(_ name: String) -> UInt64? {
        getenv(name).flatMap { UInt64(String(cString: $0)) }
    }
    if let seed = variable("SIMULATION_SEED") { return [seed] }
    return Array(0..<(variable("SIMULATION_SEEDS") ?? 1000))
}()

extension SimulationTests {
    @Test("the scenarios reach every way a run can end")
    func coverage() async throws {
        var endings: Set<String> = []
        for seed in UInt64(0)..<300 {
            let scenario = Scenario(seed: seed)
            let run = try #require(
                await scenario.run(in: Simulation(seed: seed)),
                "seed \(seed) hung"
            )
            endings.insert(ending(run))
            if run.trace.contains("handler returned") { endings.insert("handler returned") }
        }
        #expect(
            endings.isSuperset(of: [
                "success", "cancelled", "start failed", "serve failed", "stop failed",
                "serve and stop failed", "shutdown timeout", "handler returned",
            ]),
            "reached only \(endings.sorted())"
        )
    }
}

private func ending(_ run: Run) -> String {
    switch run.result {
        case .success(let outcome): outcome.cancellationReason == nil ? "success" : "cancelled"
        case .failure(.startFailed): "start failed"
        case .failure(.serveFailed): "serve failed"
        case .failure(.stopFailed): "stop failed"
        case .failure(.serveAndStopFailed): "serve and stop failed"
        case .failure(.shutdownTimeout): "shutdown timeout"
        case .failure(.signalsUnavailable): "signals unavailable"
    }
}
