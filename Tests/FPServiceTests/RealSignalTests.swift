#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FPBracket
import FPService
import Testing

/// End to end through the public API with real signals (`processSignals`).
/// Uses SIGWINCH, whose default action is to ignore, so a failure cannot
/// kill the test run.
@Suite("Real signals", .serialized, .timeLimit(.minutes(1)))
struct RealSignalTests {
    @Test("a real signal stops the service gracefully, and the disposition is restored")
    func realSignal() async throws {
        let before = disposition(SIGWINCH)
        let log = Recorder()
        let result = try await withDeadline {
            let withService = Service(probe("a", log), shutdownSignals: [SIGWINCH])
            return await withService { _, shutdown in
                raise(SIGWINCH)
                await shutdown.requested
                return .success(())
            }
        }
        #expect(try result.get().shutdownReason == .signal(SIGWINCH))
        #expect(disposition(SIGWINCH) == before)
    }
}

private func disposition(_ signal: Int32) -> UInt {
    var current = sigaction()
    sigaction(signal, nil, &current)
    #if canImport(Darwin)
    return unsafeBitCast(current.__sigaction_u.__sa_handler, to: UInt.self)
    #else
    return unsafeBitCast(current.__sigaction_handler.sa_handler, to: UInt.self)
    #endif
}
