@testable import FPService
import Testing

/// Waits until cancelled, then reports it as its own result.
@Sendable
private func untilCancelled() async -> Result<String, TestError> {
    await Shutdown().requested   // never requested: returns only when cancelled
    return .success(Task.isCancelled ? "cancelled" : "not cancelled")
}

@Suite("withCancellation(on:_:)", .timeLimit(.minutes(1)))
struct WithCancellationTests {
    @Test("an operation that finishes first returns its result, uncancelled")
    func finishesFirst() async throws {
        let result = try await withDeadline {
            await withCancellation(on: Shutdown()) {
                Result<String, TestError>.success(Task.isCancelled ? "cancelled" : "done")
            }
        }
        #expect(result == .success("done"))
    }

    @Test("a shutdown request cancels the operation, and its own result comes back")
    func shutdownCancels() async throws {
        let shutdown = Shutdown()
        let result = try await withDeadline {
            await withTaskGroup(of: Result<String, TestError>?.self) { group in
                group.addTask { await withCancellation(on: shutdown, untilCancelled) }
                group.addTask {
                    shutdown.trigger()
                    return nil
                }
                var result: Result<String, TestError>?
                for await next in group where next != nil { result = next }
                return result
            }
        }
        #expect(result == .success("cancelled"))
    }

    @Test("a failure before shutdown comes back at once")
    func failureFirst() async throws {
        let result = try await withDeadline {
            await withCancellation(on: Shutdown()) { Result<String, TestError>.failure(.boom("work")) }
        }
        #expect(result == .failure(.boom("work")))
    }

    @Test("an already requested shutdown cancels the operation right away")
    func alreadyRequested() async throws {
        let shutdown = Shutdown()
        shutdown.trigger()
        let result = try await withDeadline { await withCancellation(on: shutdown, untilCancelled) }
        #expect(result == .success("cancelled"))
    }

    @Test("cancelling the caller cancels the operation, and its own result comes back")
    func callerCancelled() async throws {
        let result = try await withDeadline {
            await withTaskGroup(of: Result<String, TestError>.self) { group in
                group.addTask { await withCancellation(on: Shutdown(), untilCancelled) }
                group.cancelAll()
                return await group.next() ?? .failure(.boom("no result"))
            }
        }
        #expect(result == .success("cancelled"))
    }
}
