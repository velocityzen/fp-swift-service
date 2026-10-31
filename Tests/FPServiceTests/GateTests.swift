@testable import FPService
import ServiceTestSupport
import Synchronization
import Testing

@Suite("Gate", .timeLimit(.minutes(1)))
struct GateTests {
    @Test("opening runs callbacks once, in order, and wakes waiters")
    func opens() async throws {
        let gate = Gate()
        let order = Mutex<[Int]>([])
        gate.wait { order.withLock { $0.append(1) } }
        gate.wait { order.withLock { $0.append(2) } }
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await gate.openedOrCancelled }
                group.addTask { gate.open() }
            }
        }
        #expect(!gate.open())
        #expect(gate.isOpen)
        #expect(order.withLock { $0 } == [1, 2])
    }

    @Test("a callback registered after opening runs at once; a removed one never runs")
    func lateAndRemoved() throws {
        let gate = Gate()
        let ran = Mutex<[String]>([])
        let id = gate.wait { ran.withLock { $0.append("removed") } }
        #expect(gate.remove(try #require(id)) != nil)
        gate.open()
        #expect(gate.wait { ran.withLock { $0.append("late") } } == nil)
        #expect(ran.withLock { $0 } == ["late"])
    }

    @Test("a cancelled waiter returns without the gate opening")
    func cancelledWaiter() async throws {
        let gate = Gate()
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await gate.openedOrCancelled }
                group.cancelAll()
            }
        }
        #expect(!gate.isOpen)
    }

    @Test("a latch's waiter ignores cancellation, and returns only once the latch opens")
    func latchIgnoresCancellation() async throws {
        let latch = Latch()
        let returned = Gate()
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await latch.wait()
                    returned.open()
                }
                group.cancelAll()
                await Task.yield()
                #expect(!returned.isOpen)
                latch.open()
            }
        }
        #expect(returned.isOpen)
    }

    @Test("opening and cancelling race without losing or doubling a wake-up")
    func race() async throws {
        try await withDeadline {
            for _ in 0..<500 {
                let gate = Gate()
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<4 { group.addTask { await gate.openedOrCancelled } }
                    group.addTask { gate.open() }
                    group.cancelAll()
                }
            }
        }
    }
}
