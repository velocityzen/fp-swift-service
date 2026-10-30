#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(CRT)
    import CRT
#endif
import FPBracket
import FPService
import ServiceTestSupport
import Testing

#if os(Windows)
    import ProcessSignals
    import WinSDK
#endif

/// End to end through the public API with real signals (`processSignals`).
/// Uses SIGCONT: its default action only resumes a stopped process, so a
/// failure cannot harm the test run. On Windows, SIGTERM, from the console
/// closing, handed to the handler routine directly: a real one would reach
/// every process on the console. Signal dispositions are process-wide, and
/// test runners may run both test targets in one process, so no other test
/// uses this signal (ProcessSignalsTests uses SIGWINCH and SIGURG, or on
/// Windows SIGBREAK and SIGINT).
@Suite("Real signals", .serialized, .timeLimit(.minutes(1)))
struct RealSignalTests {
    #if os(Windows)
        @Test("the console closing stops the service gracefully, and is held until it has")
        func consoleClosing() async throws {
            let before = disposition(SIGTERM)
            let log = Recorder()
            let result = try await withDeadline {
                let withService = Service(probe("a", log), shutdownSignals: [SIGTERM])
                let result = await withService { _, shutdown in
                    // On a thread of its own, as Windows calls the handler
                    // routine: it returns once the run has let go of SIGTERM.
                    Task.detached {
                        let handled = receiveConsoleEvent(UInt32(CTRL_CLOSE_EVENT))
                        log.append("close handled: \(handled)")
                    }
                    await shutdown.requested
                    return .success(())
                }
                await log.wait(for: "close handled: true")
                return result
            }
            #expect(try result.get().shutdownReason == .signal(SIGTERM))
            let all = log.all
            #expect(all.firstIndex(of: "stopped:a")! < all.firstIndex(of: "close handled: true")!)
            #expect(disposition(SIGTERM) == before)
        }
    #else
        @Test("a real signal stops the service gracefully, and the disposition is restored")
        func realSignal() async throws {
            let before = disposition(SIGCONT)
            let log = Recorder()
            let result = try await withDeadline {
                let withService = Service(probe("a", log), shutdownSignals: [SIGCONT])
                return await withService { _, shutdown in
                    kill(getpid(), SIGCONT)  // to the whole process, like a real `kill`
                    await shutdown.requested
                    return .success(())
                }
            }
            #expect(try result.get().shutdownReason == .signal(SIGCONT))
            #expect(disposition(SIGCONT) == before)
        }
    #endif

    @Test("shutdown signals that can't be subscribed to fail the run; the rest are unsubscribed")
    func cannotSubscribe() async throws {
        let before = disposition(testSignal)
        let log = Recorder()
        let result = try await withDeadline {
            let withService = Service(
                probe("a", log),
                shutdownSignals: [testSignal, 1234, uncatchable, 1234]
            )
            return await withService { _, _ in .success(()) }
        }
        #expect(result.failure == .signalsUnavailable([1234, uncatchable]))
        #expect(log.all.isEmpty)  // nothing ran
        #expect(disposition(testSignal) == before)
    }
}

#if os(Windows)
    private let testSignal = SIGTERM
    /// A signal of the C library that no console event is delivered as.
    private let uncatchable = SIGSEGV
#else
    private let testSignal = SIGCONT
    private let uncatchable = SIGKILL
#endif
