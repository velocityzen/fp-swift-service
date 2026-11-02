import FPBracket
@testable import FPService
import ServiceTestSupport
import Testing

/// Where stage 1 requests the shutdown: on a thread of its own when a handler
/// is registered, which may block; in place when only tasks wait for it.
@Suite("Shutdown request", .timeLimit(.minutes(1)))
struct ShutdownRequestTests {
    @Test("with no handler registered, the request runs in place")
    func inPlace() async throws {
        let log = Recorder()
        let result = try await withDeadline {
            await service(log) { _, _ in .success(()) }
        }
        #expect(try result.get().shutdownReason == .serveReturned)
        #expect(!log.all.contains("offloaded"))
    }

    @Test("with a handler registered, the request runs on a thread of its own")
    func offloaded() async throws {
        let log = Recorder()
        let result = try await withDeadline {
            await service(log) { _, shutdown in
                // Still registered when `serve` returns and stage 1 begins.
                shutdown.onShutdown { log.append("handler") }
                return .success(())
            }
        }
        #expect(try result.get().shutdownReason == .serveReturned)
        let all = log.all
        #expect(all.firstIndex(of: "offloaded")! < all.firstIndex(of: "handler")!)
        #expect(all.firstIndex(of: "handler")! < all.firstIndex(of: "stop:a")!)
    }
}

/// Runs a service with no signals that records each request it offloads.
private func service(
    _ log: Recorder,
    _ serve: sending @escaping @concurrent (String, Shutdown) async -> Result<Void, TestError>
) async -> Result<ServiceOutcome, ServiceError<TestError>> {
    let withService = Service(
        probe("a", log),
        shutdownSignals: [],
        shutdownTimeout: nil,
        clock: .continuous,
        signalStream: { requested in
            let (signals, input) = AsyncStream<Int32>.makeStream()
            input.finish()
            return (signals, requested, [])
        },
        terminate: { _ in },
        offload: { work in
            log.append("offloaded")
            await onItsOwnThread(work)
        },
        observe: nil
    )
    return await withService(serve)
}
