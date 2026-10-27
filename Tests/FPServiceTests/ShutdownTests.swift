@testable import FPService
import ServiceTestSupport
import Synchronization
import Testing

@Suite("Shutdown", .timeLimit(.minutes(1)))
struct ShutdownTests {
    @Test("requesting runs handlers once, in registration order")
    func handlers() {
        let shutdown = Shutdown()
        let order = Mutex<[Int]>([])
        for index in 0..<3 {
            shutdown.onShutdown { order.withLock { $0.append(index) } }
        }
        #expect(shutdown.request())
        #expect(!shutdown.request())
        #expect(shutdown.isRequested)
        #expect(order.withLock { $0 } == [0, 1, 2])
    }

    @Test("late registration fires immediately")
    func lateRegistration() {
        let shutdown = Shutdown()
        shutdown.request()
        let fired = Mutex(false)
        shutdown.onShutdown { fired.withLock { $0 = true } }
        #expect(fired.withLock { $0 })
    }

    @Test("a scoped handler is removed when its operation ends")
    func handlerScope() async {
        let shutdown = Shutdown()
        let fired = Mutex(false)
        let handler: @Sendable () -> Void = { fired.withLock { $0 = true } }
        let value = await withShutdownHandler(on: shutdown, handler) { 42 }
        shutdown.request()
        #expect(value == 42)
        #expect(!fired.withLock { $0 })
    }

    @Test("a removed registration never fires")
    func removal() {
        let shutdown = Shutdown()
        let fired = Mutex(false)
        let registration = shutdown.onShutdown { fired.withLock { $0 = true } }
        registration.remove()
        registration.remove()
        shutdown.request()
        #expect(!fired.withLock { $0 })
    }

    @Test("awaiting requested returns once requested, and at once afterwards")
    func awaitRequested() async throws {
        let shutdown = Shutdown()
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await shutdown.requested }
                group.addTask { shutdown.request() }
            }
        }
        await shutdown.requested
        #expect(shutdown.isRequested)
    }

    @Test("a cancelled waiter returns without the shutdown being requested")
    func cancelledWaiter() async throws {
        let shutdown = Shutdown()
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await shutdown.requested }
                group.cancelAll()
            }
        }
        #expect(!shutdown.isRequested)
    }

    @Test("a scoped handler fires while its operation runs, and the operation finishes")
    func handlerFires() async throws {
        let shutdown = Shutdown()
        let fired = Mutex(false)
        let handler: @Sendable () -> Void = { fired.withLock { $0 = true } }
        let value = try await withDeadline {
            await withShutdownHandler(on: shutdown, handler) {
                shutdown.request()
                return fired.withLock { $0 } ? "drained after the handler" : "handler did not fire"
            }
        }
        #expect(value == "drained after the handler")
    }

    @Test("a scoped handler fires at once if shutdown was already requested")
    func handlerAlreadyRequested() async {
        let shutdown = Shutdown()
        shutdown.request()
        let order = Mutex<[String]>([])
        let handler: @Sendable () -> Void = { order.withLock { $0.append("handler") } }
        await withShutdownHandler(on: shutdown, handler) {
            order.withLock { $0.append("operation") }
        }
        #expect(order.withLock { $0 } == ["handler", "operation"])
    }
}
