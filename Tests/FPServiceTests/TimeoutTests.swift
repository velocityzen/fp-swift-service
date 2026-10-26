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
            },
            service: { probe("a", harness.log) }
        )

        guard
            case .shutdownTimeout(after: .seconds(10), nil, nil) = try #require(result.failure)
        else {
            Issue.record("expected shutdownTimeout(10s), got \(result)")
            return
        }
        #expect(
            harness.log.events == [
                "started", "ready", "signal 15", "shutting down: signal 15",
                "cancelling: shutdown timeout", "failed: shutdown timeout", "stopped",
            ]
        )
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
            },
            service: { probe("a", harness.log, stopGate: gate) }
        )

        guard
            case .shutdownTimeout(after: .seconds(5), nil, nil) = try #require(result.failure)
        else {
            Issue.record("expected shutdownTimeout(5s), got \(result)")
            return
        }
    }

    @Test("a dispose failure after the timeout is kept with it")
    func timedOutThenStopFailed() async throws {
        let harness = Harness()
        let result = try await timeOutDuringDispose(
            harness,
            serve: .finish,
            stop: .failure(.boom("stop"))
        )

        guard
            case .shutdownTimeout(after: .seconds(5), nil, .boom("stop")) = try #require(
                result.failure
            )
        else {
            Issue.record("expected shutdownTimeout(5s, stop: boom(stop)), got \(result)")
            return
        }
        #expect(result.failure?.failure == .boom("stop"))
    }

    @Test("a serve failure and a dispose failure are both kept with the timeout")
    func servedFailedThenTimedOutThenStopFailed() async throws {
        let harness = Harness()
        let result = try await timeOutDuringDispose(
            harness,
            serve: .fail,
            stop: .failure(.boom("stop"))
        )

        guard
            case .shutdownTimeout(after: .seconds(5), .boom("serve"), .boom("stop")) = try #require(
                result.failure
            )
        else {
            Issue.record("expected shutdownTimeout(5s, serve:, stop:), got \(result)")
            return
        }
        #expect(result.failure?.failure == .boom("serve"))
        #expect(result.failure?.phase == .stop)
        #expect(
            harness.log.events == [
                "started", "ready", "failed: serve", "shutting down: serve returned",
                "cancelling: shutdown timeout", "failed: shutdown timeout",
                "failed: stop", "stopped",
            ]
        )
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
            },
            service: { probe("a", harness.log, stopGate: gate) }
        )

        #expect(
            try result.get()
                == ServiceOutcome(
                    shutdownReason: .serveReturned,
                    cancellationReason: nil,
                    stopDuration: .seconds(3)
                )
        )
    }
}

/// Runs a service whose dispose is still stuck when the 5-second timeout
/// passes, then lets it finish with `stop`.
private func timeOutDuringDispose(
    _ harness: Harness,
    serve: ServeMode,
    stop: Result<Void, TestError>
) async throws -> Result<ServiceOutcome, ServiceError<TestError>> {
    let clock = ManualClock()
    let gate = Latch()
    return try await run(
        harness,
        shutdownTimeout: .seconds(5),
        clock: ServiceClock(clock),
        serve: serve,
        waitingFor: ["stop:a"],
        then: {
            await clock.waitForSleepers()
            clock.advance(by: .seconds(5))
            await harness.log.wait(for: "event: cancelling: shutdown timeout")
            gate.open()  // the probe's dispose ignores cancellation
        },
        service: { probe("a", harness.log, stop: stop, stopGate: gate) }
    )
}
