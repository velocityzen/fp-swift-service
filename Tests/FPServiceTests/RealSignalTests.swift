#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import FPBracket
import FPService
import Testing

/// End to end through the public API with real signals (`processSignals`).
/// Uses SIGCONT: its default action only resumes a stopped process, so a
/// failure cannot harm the test run. Signal dispositions are process-wide,
/// and test runners may run both test targets in one process, so no other
/// test uses this signal (ProcessSignalsTests uses SIGWINCH and SIGURG).
@Suite("Real signals", .serialized, .timeLimit(.minutes(1)))
struct RealSignalTests {
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

    @Test("shutdown signals that can't be taken over are left out")
    func cannotTakeOver() async throws {
        let log = Recorder()
        let result = try await withDeadline {
            let withService = Service(probe("a", log), shutdownSignals: [0, 1234, SIGKILL])
            return await withService { _, _ in .success(()) }
        }
        #expect(try result.get().shutdownReason == .serveReturned)
    }
}

private func disposition(_ signal: Int32) -> UInt {
    var current = sigaction()
    sigaction(signal, nil, &current)
    #if canImport(Darwin)
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: UInt.self)
    #elseif canImport(Musl)
        return unsafeBitCast(current.__sa_handler.sa_handler, to: UInt.self)
    #else
        return unsafeBitCast(current.__sigaction_handler.sa_handler, to: UInt.self)
    #endif
}
