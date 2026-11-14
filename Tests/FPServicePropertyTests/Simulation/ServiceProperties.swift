// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import FPService
    import HegelTesting
    import ServiceTestSupport
    import Testing

    /// A whole `Service` run under simulation: brackets, a body, signals, the
    /// caller and the timeout all generated, and the interleaving drawn too.
    @Suite(.hegel)
    struct ServiceProperties {
        /// Whatever happens to it and in whatever order its tasks run, a run
        /// acquires in order and disposes what it acquired once, in reverse;
        /// serves only on a full start; disposes only once serve and (unless
        /// cancelled) the shutdown handlers have returned; leaves nothing
        /// running; tells the observer what happened; and returns the result
        /// that matches it. It never hangs: every phase is finite, and the
        /// caller cancels at the latest by the backstop.
        @Test(.hegel(testCases: 500))
        func everyRunKeepsTheInvariants() async throws {
            try await property(reaching: ServiceReach.all) { tc in
                let scenario = try tc.draw(ScenarioGen.scenario, named: "scenario")
                let schedule = try tc.draw(ScenarioGen.schedule, named: "schedule")
                let run = try #require(
                    await scenario.run(in: Simulation(schedule: schedule)),
                    "the run hung"
                )
                tc.note("trace:\n" + run.timeline)
                tc.note("result: \(run.result)")
                run.check(against: scenario)
                for ending in ServiceReach.endings(of: run) { try tc.event(ending) }
            }
        }

        /// Stage 2 ends dispose's wait for the shutdown handlers: a run whose
        /// handler still runs when stage 2 begins disposes at once, under
        /// every interleaving, and keeps every other invariant too.
        @Test(.hegel(testCases: 300))
        func stageTwoEndsTheWaitForHandlers() async throws {
            try await property(reaching: [ServiceReach.cancelledWhileHandlerRuns]) { tc in
                let scenario = try tc.draw(ScenarioGen.cancelledWhileHandlerRuns, named: "scenario")
                let schedule = try tc.draw(ScenarioGen.schedule, named: "schedule")
                let run = try #require(
                    await scenario.run(in: Simulation(schedule: schedule)),
                    "the run hung"
                )
                tc.note("trace:\n" + run.timeline)
                run.check(against: scenario)
                if ServiceReach.endings(of: run).contains(ServiceReach.cancelledWhileHandlerRuns) {
                    try tc.event(ServiceReach.cancelledWhileHandlerRuns)
                }
            }
        }

        /// A run is the same run every time: the same scenario under the
        /// same schedule records the same trace, at the same times, and returns
        /// the same result.
        @Test(.hegel(testCases: 100))
        func aScheduleIsOneRun() async throws {
            try await property { tc in
                let scenario = try tc.draw(ScenarioGen.scenario, named: "scenario")
                let schedule = try tc.draw(ScenarioGen.schedule, named: "schedule")
                let first = try #require(await scenario.run(in: Simulation(schedule: schedule)))
                let second = try #require(await scenario.run(in: Simulation(schedule: schedule)))
                #expect(first.trace == second.trace)
                #expect(first.times == second.times)
                #expect("\(first.result)" == "\(second.result)")
            }
        }
    }

    extension Run {
        /// The trace, each line after the simulated time it was recorded at.
        var timeline: String {
            zip(times, trace).map { "\($0): \($1)" }.joined(separator: "\n")
        }
    }

    /// The ways a run ends, each of which the scenarios must reach.
    enum ServiceReach {
        static let all = [
            "success", "cancelled", "start failed", "serve failed", "stop failed",
            "serve and stop failed", "shutdown timeout", "handler returned", "terminated",
        ]

        /// Serve has returned in stage 1 and a handler still runs when stage
        /// 2 begins: dispose must stop waiting for it. Rare in random
        /// scenarios, so `stageTwoEndsTheWaitForHandlers` draws it directly.
        static let cancelledWhileHandlerRuns = "stage 2 while dispose waited for a handler"

        static func endings(of run: Run) -> [String] {
            var endings: [String] = []
            switch run.result {
                case .success(let outcome):
                    endings.append(outcome.cancellationReason == nil ? "success" : "cancelled")
                case .failure(.startFailed): endings.append("start failed")
                case .failure(.serveFailed): endings.append("serve failed")
                case .failure(.stopFailed): endings.append("stop failed")
                case .failure(.serveAndStopFailed): endings.append("serve and stop failed")
                case .failure(.shutdownTimeout): endings.append("shutdown timeout")
                case .failure(.signalsUnavailable): endings.append("signals unavailable")
            }
            if run.trace.contains("handler returned") { endings.append("handler returned") }
            let trace = run.trace
            if let served = trace.firstIndex(where: { $0.hasPrefix("served") }),
                let handler = trace.firstIndex(of: "handler"),
                let cancel = trace.firstIndex(where: { $0.hasPrefix("event: cancelling") }),
                handler < cancel, served < cancel,
                (trace.firstIndex(of: "handler returned") ?? trace.count) > cancel
            {
                endings.append(cancelledWhileHandlerRuns)
            }
            if run.trace.contains(where: { $0.hasPrefix("terminate ") }) {
                endings.append("terminated")
            }
            return endings
        }
    }

#endif
