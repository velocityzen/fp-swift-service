@testable import FPService
import Synchronization
import Testing

@Suite("Shutdown", .timeLimit(.minutes(1)))
struct ShutdownTests {
    @Test("triggering runs handlers once, in registration order")
    func handlers() {
        let shutdown = Shutdown()
        let order = Mutex<[Int]>([])
        for index in 0..<3 {
            shutdown.onShutdown { order.withLock { $0.append(index) } }
        }
        #expect(shutdown.trigger())
        #expect(!shutdown.trigger())
        #expect(shutdown.isRequested)
        #expect(order.withLock { $0 } == [0, 1, 2])
    }

    @Test("late registration fires immediately")
    func lateRegistration() {
        let shutdown = Shutdown()
        shutdown.trigger()
        let fired = Mutex(false)
        shutdown.onShutdown { fired.withLock { $0 = true } }
        #expect(fired.withLock { $0 })
    }

    @Test("a scoped handler is removed when its operation ends")
    func handlerScope() async {
        let shutdown = Shutdown()
        let fired = Mutex(false)
        let value = await withShutdownHandler(on: shutdown, { fired.withLock { $0 = true } }) { 42 }
        shutdown.trigger()
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
        shutdown.trigger()
        #expect(!fired.withLock { $0 })
    }

    @Test("awaiting requested returns once triggered, and at once afterwards")
    func awaitRequested() async throws {
        let shutdown = Shutdown()
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await shutdown.requested }
                group.addTask { shutdown.trigger() }
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
        let value = try await withDeadline {
            await withShutdownHandler(on: shutdown, { fired.withLock { $0 = true } }) {
                shutdown.trigger()
                return fired.withLock { $0 } ? "drained after the handler" : "handler did not fire"
            }
        }
        #expect(value == "drained after the handler")
    }

    @Test("a scoped handler fires at once if shutdown was already requested")
    func handlerAlreadyRequested() async {
        let shutdown = Shutdown()
        shutdown.trigger()
        let order = Mutex<[String]>([])
        await withShutdownHandler(on: shutdown, { order.withLock { $0.append("handler") } }) {
            order.withLock { $0.append("operation") }
        }
        #expect(order.withLock { $0 } == ["handler", "operation"])
    }
}
