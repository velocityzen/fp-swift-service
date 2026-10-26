#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import FPBracket
@testable import FPService
import Testing

/// R2. Events.
@Suite("Events", .timeLimit(.minutes(1)))
struct EventTests {
    @Test("the spec's example: SIGTERM, then a second SIGTERM while draining")
    func specExample() async throws {
        let harness = Harness()
        let result = try await run(
            harness,
            serve: .ignoreShutdown,
            waitingFor: ["event: ready"],
            then: {
                harness.send(SIGTERM)
                await harness.log.wait(for: "event: shutting down: signal 15")
                harness.send(SIGTERM)
            },
            service: { probe("a", harness.log) }
        )

        #expect(
            harness.log.events == [
                "started", "ready",
                "signal 15", "shutting down: signal 15",
                "signal 15", "cancelling: signal 15",
                "stopped",
            ]
        )
        let outcome = try result.get()
        #expect(
            outcome
                == ServiceOutcome(
                    shutdownReason: .signal(SIGTERM),
                    cancellationReason: .signal(SIGTERM),
                    stopDuration: outcome.stopDuration
                )
        )
    }

    @Test("the stream finishes by itself, before the call returns")
    func streamFinishes() async throws {
        let harness = Harness()
        _ = try await run(harness, serve: .finish) { probe("a", harness.log) }
        let all = harness.log.all
        #expect(all.firstIndex(of: "observer done")! < all.firstIndex(of: "returned")!)
        #expect(harness.log.events.last == "stopped")
    }

    @Test("a serve failure appears where it happens, before the stop")
    func failureEvent() async throws {
        let harness = Harness()
        _ = try await run(harness, serve: .fail) { probe("a", harness.log) }
        #expect(
            harness.log.events == [
                "started", "ready", "failed: serve", "shutting down: serve returned", "stopped",
            ]
        )
    }

    @Test("without an observer the service runs the same")
    func noObserver() async throws {
        let harness = Harness()
        let result = try await run(harness, observe: false, serve: .finish) {
            probe("a", harness.log)
        }
        #expect(try result.get().shutdownReason == .serveReturned)
        #expect(harness.log.events.isEmpty)
    }

    @Test("an observer that returns early does not affect the service")
    func earlyObserver() async throws {
        let log = Recorder()
        let result = try await withDeadline {
            let withService = Service(probe("a", log)) { events in
                for await event in events {
                    log.append("event: \(describe(event))")
                    break
                }
            }
            return await withService { _, _ in .success(()) }
        }
        #expect(try result.get().shutdownReason == .serveReturned)
        #expect(log.events == ["started"])
        #expect(log.with(prefix: "stopped:") == ["stopped:a"])
    }
}
