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
import ServiceTestSupport
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

    @Test("a schedule is one interleaving: the empty one runs jobs in the order they were ready")
    func schedules() async throws {
        let fifo = try #require(await interleave(Simulation(schedule: [])))
        #expect(await interleave(Simulation(schedule: [])) == fifo)
        #expect(await interleave(Simulation(schedule: [0, 0, 0])) == fifo)
        let picked = try #require(await interleave(Simulation(schedule: [2, 1])))
        #expect(await interleave(Simulation(schedule: [2, 1])) == picked)
        #expect(picked != fifo)
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
    await interleave(Simulation(seed: seed))
}

/// The same three tasks under `simulation`.
private func interleave(_ simulation: Simulation) async -> [String]? {
    await simulation.run {
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
