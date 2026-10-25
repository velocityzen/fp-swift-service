@testable import FPService
import Synchronization
import Testing

@Suite("Gate", .timeLimit(.minutes(1)))
struct GateTests {
    @Test("opening runs callbacks once, in order, and wakes waiters")
    func opens() async throws {
        let gate = Gate()
        let order = Mutex<[Int]>([])
        gate.onOpen { order.withLock { $0.append(1) } }
        gate.onOpen { order.withLock { $0.append(2) } }
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await gate.opened }
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
        let id = gate.onOpen { ran.withLock { $0.append("removed") } }
        #expect(gate.remove(try #require(id)) != nil)
        gate.open()
        #expect(gate.onOpen { ran.withLock { $0.append("late") } } == nil)
        #expect(ran.withLock { $0 } == ["late"])
    }

    @Test("a cancelled waiter returns without the gate opening")
    func cancelledWaiter() async throws {
        let gate = Gate()
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await gate.opened }
                group.cancelAll()
            }
        }
        #expect(!gate.isOpen)
    }

    @Test("opening and cancelling race without losing or doubling a wake-up")
    func race() async throws {
        try await withDeadline(.seconds(20)) {
            for _ in 0..<500 {
                let gate = Gate()
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<4 { group.addTask { await gate.opened } }
                    group.addTask { gate.open() }
                    group.cancelAll()
                }
            }
        }
    }
}
