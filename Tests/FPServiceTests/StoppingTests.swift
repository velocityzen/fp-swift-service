#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import FPBracket
@testable import FPService
import Testing

/// R3. Graceful stop, R4. Signals, R5. Stage 2.
@Suite("Stopping", .timeLimit(.minutes(1)))
struct StoppingTests {
    @Test("serve returning requests shutdown before dispose, so its handlers run first")
    func serveReturning() async throws {
        let harness = Harness()
        let result = try await run(harness, serve: .finishWithHandler) { probe("a", harness.log) }

        #expect(try result.get().shutdownReason == .serveReturned)
        let all = harness.log.all
        #expect(all.firstIndex(of: "handler")! < all.firstIndex(of: "stop:a")!)
        #expect(
            harness.log.events == ["started", "ready", "shutting down: serve returned", "stopped"]
        )
    }

    @Test("the first signal starts the graceful stage")
    func firstSignal() async throws {
        let harness = Harness()
        let result = try await run(
            harness,
            waitingFor: ["serve"],
            then: { harness.send(SIGTERM) },
            service: { probe("a", harness.log) }
        )

        let outcome = try result.get()
        #expect(outcome.shutdownReason == .signal(SIGTERM))
        #expect(outcome.cancellationReason == nil)
        #expect(harness.log.all.contains("shutdown requested: true"))
        #expect(harness.log.all.contains("served"))
    }

    @Test("a signal during the graceful stage cancels; any listed signal counts")
    func secondSignal() async throws {
        let harness = Harness()
        let result = try await run(
            harness,
            shutdownSignals: [SIGTERM, SIGINT],
            serve: .ignoreShutdown,
            waitingFor: ["serve"],
            then: {
                harness.send(SIGTERM)
                await harness.log.wait(for: "event: shutting down: signal 15")
                harness.send(SIGINT)
            },
            service: { probe("a", harness.log) }
        )

        let outcome = try result.get()
        #expect(outcome.shutdownReason == .signal(SIGTERM))
        #expect(outcome.cancellationReason == .signal(SIGINT))
        #expect(harness.log.all.contains("served: cancelled"))
        #expect(harness.log.all.contains("stopped:a"))  // dispose still ran
        #expect(harness.log.events.contains("cancelling: signal 2"))
    }

    @Test("a signal during stage 2 ends the process")
    func thirdSignal() async throws {
        let harness = Harness()
        let gate = Latch()
        let log = harness.log
        _ = try await run(
            harness,
            serve: .ignoreShutdown,
            waitingFor: ["serve"],
            then: {
                harness.send(SIGTERM)
                await log.wait(for: "event: shutting down: signal 15")
                harness.send(SIGTERM)
                await log.wait(for: "stop:a")  // cancelled; dispose is stuck on the gate
                harness.send(SIGTERM)
                await log.wait(for: "terminate: 15")
                gate.open()  // the fake terminate does not end the test process
            },
            service: { probe("a", log, stopGate: gate) }
        )

        #expect(log.with(prefix: "terminate:") == ["terminate: 15"])
        #expect(log.events.filter { $0 == "signal 15" }.count == 3)
    }

    @Test("after serve returned, the first signal cancels and the second ends the process")
    func signalAfterServeReturned() async throws {
        let harness = Harness()
        let gate = Latch()
        let log = harness.log
        let result = try await run(
            harness,
            serve: .finish,
            waitingFor: ["stop:a"],
            then: {
                harness.send(SIGTERM)
                await log.wait(for: "event: cancelling: signal 15")
                harness.send(SIGTERM)
                await log.wait(for: "terminate: 15")
                gate.open()
            },
            service: { probe("a", log, stopGate: gate) }
        )

        let outcome = try result.get()
        #expect(outcome.shutdownReason == .serveReturned)
        #expect(outcome.cancellationReason == .signal(SIGTERM))
        #expect(
            log.events == [
                "started", "ready", "shutting down: serve returned",
                "signal 15", "cancelling: signal 15",
                "signal 15",
                "stopped",
            ]
        )
    }

    @Test("a signal during acquire requests shutdown before serve begins")
    func signalDuringAcquire() async throws {
        let harness = Harness()
        let gate = Latch()
        let log = harness.log
        let result = try await run(
            harness,
            waitingFor: ["start:a"],
            then: {
                harness.send(SIGTERM)
                await log.wait(for: "event: shutting down: signal 15")
                gate.open()
            },
            service: { probe("a", log, startGate: gate) }
        )

        #expect(try result.get().shutdownReason == .signal(SIGTERM))
        #expect(log.all.contains("shutdown requested: true"))
        #expect(
            log.events == [
                "started", "signal 15", "shutting down: signal 15", "ready", "stopped",
            ]
        )
    }

    @Test("signals are taken over before acquire and released after dispose")
    func signalWindow() async throws {
        let harness = Harness()
        _ = try await run(harness, shutdownSignals: [SIGTERM, SIGINT], serve: .finish) {
            probe("a", harness.log)
        }
        let all = harness.log.all
        let taken = try #require(all.firstIndex(of: "signals taken: [15, 2]"))
        let ended = try #require(all.firstIndex(of: "signals ended"))
        #expect(taken < all.firstIndex(of: "start:a")!)
        #expect(ended > all.firstIndex(of: "stopped:a")!)
        #expect(ended < all.firstIndex(of: "returned")!)
    }

    @Test("cancelling the caller cancels at once and never requests shutdown")
    func callerCancelled() async throws {
        let log = Recorder()
        let result = try await withDeadline {
            typealias Run = Result<ServiceOutcome, ServiceError<TestError>>
            return await withTaskGroup(of: Run?.self) { group in
                group.addTask {
                    let withService = Service(probe("a", log)) { events in
                        for await event in events { log.append("event: \(describe(event))") }
                    }
                    return await withService(serving(.ignoreShutdown, log))
                }
                group.addTask {
                    await log.wait(for: "serve")
                    return nil
                }
                _ = await group.next()
                group.cancelAll()
                return await group.next().flatMap { $0 }
            }
        }

        let outcome = try #require(result).get()
        #expect(outcome.shutdownReason == nil)
        #expect(outcome.cancellationReason == .caller)
        #expect(log.all.contains("shutdown requested: false"))
        #expect(log.all.contains("stopped:a"))
        // The observer is cancelled with everything else, so it may miss
        // the remaining events (spec R5.1); the result reports it.
    }

    @Test("a cancelled caller keeps the signals through dispose; a signal then ends the process")
    func callerCancelledHoldsSignals() async throws {
        let harness = Harness()
        let log = harness.log
        let signals = harness.signals
        let gate = Latch()
        let result = try await withDeadline {
            typealias Run = Result<ServiceOutcome, ServiceError<TestError>>
            return await withTaskGroup(of: Run?.self) { group in
                group.addTask {
                    let withService = Service(
                        probe("a", log, stopGate: gate),
                        shutdownSignals: [SIGTERM],
                        shutdownTimeout: nil,
                        clock: .continuous,
                        signalStream: { _ in signals },
                        terminate: { log.append("terminate: \($0)") },
                        observe: nil
                    )
                    return await withService(serving(.ignoreShutdown, log))
                }
                await log.wait(for: "serve")
                group.cancelAll()
                await log.wait(for: "stop:a")  // cancelled; dispose is stuck on the gate
                harness.send(SIGTERM)
                await log.wait(for: "terminate: 15")  // stage 2 began at once: stage 3
                gate.open()  // the fake terminate does not end the test process
                return await group.next().flatMap { $0 }
            }
        }

        let outcome = try #require(result).get()
        #expect(outcome.cancellationReason == .caller)
        let all = log.all
        let ended = try #require(all.firstIndex(of: "signals ended"))
        #expect(ended > all.firstIndex(of: "stopped:a")!)
    }
}
