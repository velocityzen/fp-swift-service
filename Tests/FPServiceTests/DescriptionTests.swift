#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
@testable import FPService
import Testing

/// The log lines hosts print, and what `ServiceError` reports about itself.
@Suite("Descriptions and errors")
struct DescriptionTests {
    @Test("events describe themselves as short log lines")
    func events() {
        let outcome = ServiceOutcome(
            shutdownReason: .signal(SIGTERM),
            cancellationReason: .signal(SIGINT),
            stopDuration: .milliseconds(500)
        )
        let lines: [(ServiceEvent, String)] = [
            (.started, "started"),
            (.ready, "ready"),
            (.signal(SIGTERM), "SIGTERM"),
            (.shuttingDown(.signal(SIGTERM)), "shutting down (SIGTERM)"),
            (.shuttingDown(.serveReturned), "shutting down (serve returned)"),
            (.cancelling(.signal(SIGINT)), "cancelling (SIGINT)"),
            (
                .cancelling(.shutdownTimeout(after: .seconds(10))),
                "cancelling (shutdown took longer than 10.0 seconds)"
            ),
            (.cancelling(.caller), "cancelling (caller cancelled)"),
            (.stopped(outcome), "stopped (SIGTERM, stopped in 0.5 seconds, cancelled (SIGINT))"),
        ]
        for (event, line) in lines {
            #expect(event.description == line)
        }
    }

    @Test("an outcome without a graceful shutdown says so")
    func outcomeWithoutShutdown() {
        let outcome = ServiceOutcome(
            shutdownReason: nil,
            cancellationReason: .caller,
            stopDuration: nil
        )
        #expect(outcome.description == "no graceful shutdown, cancelled (caller cancelled)")
    }

    @Test("each error names its phase and carries the service's own error")
    func errors() {
        typealias Error = ServiceError<TestError>
        let serve = TestError.boom("serve")
        let stop = TestError.boom("stop")
        let cases: [(Error, ServicePhase, TestError?)] = [
            (.signalsUnavailable([SIGKILL]), .start, nil),
            (.startFailed(serve), .start, serve),
            (.serveFailed(serve), .serve, serve),
            (.stopFailed(stop), .stop, stop),
            (.serveAndStopFailed(serve: serve, stop: stop), .serve, serve),
            (.shutdownTimeout(after: .seconds(5)), .stop, nil),
            (.shutdownTimeout(after: .seconds(5), stop: stop), .stop, stop),
            (.shutdownTimeout(after: .seconds(5), serve: serve, stop: stop), .stop, serve),
        ]
        for (error, phase, failure) in cases {
            #expect(error.phase == phase)
            #expect(error.failure == failure)
            #expect(error.description == error.errorDescription)
        }
    }

    @Test("error descriptions include every failure")
    func errorDescriptions() {
        typealias Error = ServiceError<TestError>
        let lines: [(Error, String)] = [
            (
                .signalsUnavailable([SIGKILL, 1234]),
                "Service could not subscribe to SIGKILL, signal 1234, so it did not start."
            ),
            (.startFailed(.boom("a")), #"Service failed to start: boom("a")"#),
            (.serveFailed(.boom("a")), #"Service failed while serving: boom("a")"#),
            (.stopFailed(.boom("a")), #"Service failed to stop: boom("a")"#),
            (
                .serveAndStopFailed(serve: .boom("a"), stop: .boom("b")),
                #"Service failed while serving: boom("a"); then failed to stop: boom("b")"#
            ),
            (
                .shutdownTimeout(after: .seconds(5)),
                "Service did not shut down within 5.0 seconds and was cancelled."
            ),
            (
                .shutdownTimeout(after: .seconds(5), serve: .boom("a"), stop: .boom("b")),
                "Service did not shut down within 5.0 seconds and was cancelled."
                    + #" It had failed while serving: boom("a"). It failed to stop: boom("b")."#
            ),
        ]
        for (error, line) in lines {
            #expect(error.description == line)
        }
    }

    @Test("errors compare equal when their phase and failures do")
    func equatable() {
        typealias Error = ServiceError<TestError>
        #expect(Error.stopFailed(.boom("a")) == .stopFailed(.boom("a")))
        #expect(Error.stopFailed(.boom("a")) != .serveFailed(.boom("a")))
        #expect(
            Error.shutdownTimeout(after: .seconds(5))
                != .shutdownTimeout(after: .seconds(5), stop: .boom("a"))
        )
        #expect(ServiceEvent.shuttingDown(.signal(SIGTERM)) == .shuttingDown(.signal(SIGTERM)))
    }
}
