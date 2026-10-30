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
import ServiceTestSupport
import Testing

/// R1. Lifecycle — and R6. Result.
@Suite("Lifecycle and result", .timeLimit(.minutes(1)))
struct LifecycleTests {
    @Test("acquire, serve, dispose; composed services stop in reverse order")
    func lifecycle() async throws {
        let harness = Harness()
        let result = try await run(harness, serve: .finish) { chain(harness.log) }

        let outcome = try result.get()
        #expect(outcome.shutdownReason == .serveReturned)
        #expect(outcome.cancellationReason == nil)
        #expect(outcome.stopDuration != nil)
        #expect(outcome.shutdownDuration != nil)
        let log = harness.log
        #expect(log.with(prefix: "start:") == ["start:a", "start:b", "start:c"])
        #expect(log.with(prefix: "stop:") == ["stop:c", "stop:b", "stop:a"])
        let all = log.all
        #expect(all.firstIndex(of: "serve")! > all.firstIndex(of: "start:c")!)
        #expect(all.firstIndex(of: "served")! < all.firstIndex(of: "stop:c")!)
    }

    @Test("the shutdown duration runs from stage 1, the stop duration from serve returning")
    func durations() async throws {
        let harness = Harness()
        let clock = ManualClock()
        let drained = Latch()
        let result = try await run(
            harness,
            clock: ServiceClock(clock),
            serve: .drain(drained),
            waitingFor: ["serve"],
            then: {
                harness.send(SIGTERM)
                await harness.log.wait(for: "event: shutting down: signal 15")
                clock.advance(by: .seconds(2))  // serve finishes its work
                drained.open()
            },
            service: { probe("a", harness.log) }
        )

        let outcome = try result.get()
        #expect(outcome.shutdownDuration == .seconds(2))
        #expect(outcome.stopDuration == .zero)
    }

    @Test("a dependent receives its dependency's resource")
    func dependency() async throws {
        let harness = Harness()
        let log = harness.log
        _ = try await run(harness, serve: .finish) {
            probe("database", log).flatMap { db in probe("api(\(db))", log) }
        }
        #expect(log.with(prefix: "start:") == ["start:database", "start:api(database)"])
        #expect(log.with(prefix: "stop:") == ["stop:api(database)", "stop:database"])
    }

    @Test("an acquire failure skips serve and dispose")
    func startFailure() async throws {
        let harness = Harness()
        let log = harness.log
        let result = try await run(harness) {
            chain(log, b: probe("b", log, start: .failure(.boom("b"))))
        }

        guard case .startFailed(.boom("b")) = try #require(result.failure) else {
            Issue.record("expected startFailed(boom(b)), got \(result)")
            return
        }
        #expect(!log.all.contains("serve"))
        // a was acquired, so the bracket released it
        #expect(log.with(prefix: "stop:") == ["stop:a"])
        #expect(harness.log.events == ["started", "failed: start"])
    }

    @Test("shutdown signals that can't be subscribed to fail the run before acquire")
    func signalsUnavailable() async throws {
        let harness = Harness()
        let log = harness.log
        let result = try await run(
            harness,
            shutdownSignals: [SIGTERM, SIGINT],
            unavailable: [SIGINT]
        ) {
            probe("a", log)
        }

        #expect(result.failure == .signalsUnavailable([SIGINT]))
        #expect(log.with(prefix: "start:").isEmpty)
        #expect(log.events == ["failed: signals unavailable [2]"])
        // SIGTERM was subscribed to, and is unsubscribed from before the call returns.
        let all = log.all
        #expect(all.firstIndex(of: "signals ended")! < all.firstIndex(of: "returned")!)
    }

    @Test("the default serve stays up until shutdown")
    func defaultServe() async throws {
        let harness = Harness()
        let result = try await run(
            harness,
            serve: nil,
            waitingFor: ["event: ready"],
            then: { harness.send(SIGTERM) },
            service: { probe("a", harness.log) }
        )
        #expect(try result.get().shutdownReason == .signal(SIGTERM))
    }

    @Test("a serve failure is reported; dispose still runs")
    func serveFailure() async throws {
        let harness = Harness()
        let result = try await run(harness, serve: .fail) { chain(harness.log) }

        guard case .serveFailed(.boom("serve")) = try #require(result.failure) else {
            Issue.record("expected serveFailed, got \(result)")
            return
        }
        #expect(harness.log.with(prefix: "stopped:") == ["stopped:c", "stopped:b", "stopped:a"])
    }

    @Test("a dispose failure is reported, and the other disposes still run")
    func stopFailure() async throws {
        let harness = Harness()
        let log = harness.log
        let result = try await run(harness, serve: .finish) {
            chain(log, b: probe("b", log, stop: .failure(.boom("b-stop"))))
        }

        guard case .stopFailed(.boom("b-stop")) = try #require(result.failure) else {
            Issue.record("expected stopFailed, got \(result)")
            return
        }
        #expect(log.with(prefix: "stopped:") == ["stopped:c", "stopped:b", "stopped:a"])
    }

    @Test("serve and dispose both failing are both kept")
    func serveAndStopFailure() async throws {
        let harness = Harness()
        let log = harness.log
        let result = try await run(harness, serve: .fail) {
            chain(log, b: probe("b", log, stop: .failure(.boom("b-stop"))))
        }

        guard
            case .serveAndStopFailed(.boom("serve"), .boom("b-stop")) = try #require(result.failure)
        else {
            Issue.record("expected serveAndStopFailed, got \(result)")
            return
        }
        #expect(result.failure?.phase == .serve)
    }

    @Test("a throwing bracket keeps the thrown error whole")
    func throwingBracket() async throws {
        let result = try await withDeadline {
            let withService = Service(
                BracketAsync<Int, any Error>.throwing(
                    acquire: { throw TestError.boom("thrown") },
                    dispose: { _ in }
                )
            )
            return await withService()
        }
        guard case .startFailed(let error) = try #require(result.failure) else {
            Issue.record("expected startFailed, got \(result)")
            return
        }
        #expect(error as? TestError == .boom("thrown"))
    }
}
