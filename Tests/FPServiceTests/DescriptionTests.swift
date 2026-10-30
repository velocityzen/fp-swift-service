#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(CRT)
    import CRT
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
            stopDuration: .milliseconds(500),
            shutdownDuration: .milliseconds(1500)
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
                "cancelling (shutdown took longer than 10 s)"
            ),
            (.cancelling(.caller), "cancelling (caller cancelled)"),
            (
                .stopped(outcome),
                "stopped (SIGTERM, shut down in 1.5 s, stopped in 500 ms, cancelled (SIGINT))"
            ),
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
            stopDuration: nil,
            shutdownDuration: nil
        )
        #expect(outcome.description == "no graceful shutdown, cancelled (caller cancelled)")
    }

    @Test("durations read in seconds from one second up, in milliseconds below")
    func durations() {
        let lines: [(Duration, String)] = [
            (.zero, "0 ms"),
            (.nanoseconds(400), "0 ms"),
            (.nanoseconds(9542), "0.01 ms"),
            (.microseconds(42), "0.042 ms"),
            (.milliseconds(250), "250 ms"),
            (.microseconds(999_999), "999.999 ms"),
            (.nanoseconds(999_999_900), "1 s"),
            (.seconds(1), "1 s"),
            (.milliseconds(1500), "1.5 s"),
            (.milliseconds(2042), "2.042 s"),
            (.seconds(2) + .microseconds(999_600), "3 s"),
            (.seconds(3600), "3600 s"),
            (.milliseconds(-250), "-250 ms"),
        ]
        for (duration, line) in lines {
            #expect(format(duration) == line, "\(duration)")
        }
    }

    @Test("each error names its phase and carries the service's own error")
    func errors() {
        typealias Error = ServiceError<TestError>
        let serve = TestError.boom("serve")
        let stop = TestError.boom("stop")
        let cases: [(Error, ServicePhase, TestError?)] = [
            (.signalsUnavailable([1234]), .start, nil),
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
                .signalsUnavailable([SIGINT, 1234]),
                "Service could not subscribe to SIGINT, signal 1234, so it did not start."
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
                "Service did not shut down within 5 s and was cancelled."
            ),
            (
                .shutdownTimeout(after: .seconds(5), serve: .boom("a"), stop: .boom("b")),
                "Service did not shut down within 5 s and was cancelled."
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
