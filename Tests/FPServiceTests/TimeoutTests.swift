#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FPBracket
@testable import FPService
import Testing

/// R5.4. `shutdownTimeout`, on a manual clock: deadlines elapse when the test
/// advances time, never by sleeping.
@Suite("Shutdown timeout", .timeLimit(.minutes(1)))
struct TimeoutTests {
    @Test("a graceful shutdown that outlasts the timeout is cancelled")
    func timedOut() async throws {
        let harness = Harness()
        let clock = ManualClock()
        let result = try await run(
            harness,
            shutdownTimeout: .seconds(10),
            clock: ServiceClock(clock),
            serve: .ignoreShutdown,
            waitingFor: ["serve"],
            then: {
                harness.send(SIGTERM)
                await clock.waitForSleepers()
                clock.advance(by: .seconds(10))
            }
        ) {
            probe("a", harness.log)
        }

        guard case .shutdownTimeout(after: .seconds(10)) = try #require(result.failure) else {
            Issue.record("expected shutdownTimeout(10s), got \(result)")
            return
        }
        #expect(
            harness.log.events == [
                "started", "ready", "signal 15", "shutting down: signal 15",
                "cancelling: shutdown timeout", "failed: shutdown timeout", "stopped",
            ])
        #expect(harness.log.all.contains("stopped:a"))
    }

    @Test("the timeout also covers dispose, and starts when serve returns")
    func coversDispose() async throws {
        let harness = Harness()
        let clock = ManualClock()
        let gate = Latch()
        let result = try await run(
            harness,
            shutdownTimeout: .seconds(5),
            clock: ServiceClock(clock),
            serve: .finish,
            waitingFor: ["stop:a"],
            then: {
                await clock.waitForSleepers()
                clock.advance(by: .seconds(5))
                await harness.log.wait(for: "event: cancelling: shutdown timeout")
                gate.open()  // the probe's dispose ignores cancellation
            }
        ) {
            probe("a", harness.log, stopGate: gate)
        }

        guard case .shutdownTimeout(after: .seconds(5)) = try #require(result.failure) else {
            Issue.record("expected shutdownTimeout(5s), got \(result)")
            return
        }
    }

    @Test("a shutdown within the timeout is graceful, and its duration is measured")
    func withinTimeout() async throws {
        let harness = Harness()
        let clock = ManualClock()
        let gate = Latch()
        let result = try await run(
            harness,
            shutdownTimeout: .seconds(5),
            clock: ServiceClock(clock),
            serve: .finish,
            waitingFor: ["stop:a"],
            then: {
                await clock.waitForSleepers()
                clock.advance(by: .seconds(3))
                gate.open()
            }
        ) {
            probe("a", harness.log, stopGate: gate)
        }

        #expect(
            try result.get()
                == ServiceOutcome(
                    shutdownReason: .serveReturned, cancellationReason: nil,
                    stopDuration: .seconds(3)))
    }
}
