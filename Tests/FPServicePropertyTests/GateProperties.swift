// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import Dispatch
    @testable import FPService
    import HegelTesting
    import ServiceTestSupport
    import Synchronization
    import Testing

    /// `Gate`, the one-shot flag under `Shutdown` and `withCancellation`:
    /// callbacks and suspended tasks wait for it to open.
    @Suite(.hegel)
    struct GateProperties {
        /// One operation at a time, against a model: a callback runs once, at
        /// the open, in registration order, unless removed first, or at once
        /// if the gate is already open; `open` reports the first open only;
        /// `openUnlessCallbacks` opens unless a callback waits; a waiting task
        /// resumes once, when the gate opens or its wait is ended. Ids of
        /// callbacks and tasks are drawn from one pool, so each kind is also
        /// removed and ended by the other's ids.
        @Test(.hegel(testCases: 500))
        func gateMatchesItsModel() async throws {
            try await property(reaching: GateReach.sequential) { tc in
                let model = try await gateMachine.run(tc, from: GateModel(ids: try tc.pool()))
                model.gate.open()  // releases the tasks still waiting
            }
        }

        /// Operations from several workers at once: no callback runs twice or
        /// runs once removed; after an open every callback still registered
        /// has run, in registration order, and every waiting task has
        /// resumed; only one call opens it.
        @Test(.hegel(testCases: 300))
        func gateHoldsUnderConcurrentUse() async throws {
            try await property(reaching: GateReach.concurrent) { tc in
                let shared = SharedGate(ids: try tc.pool())
                try await concurrentGateMachine.run(tc, from: shared)
                shared.gate.open()  // releases the tasks still waiting
            }
        }
    }

    extension GateProperties {
        /// Calls that open the gate at the same instant, on threads of their
        /// own: exactly one call opens it, if any can, and once open, each
        /// callback has run exactly once. `openUnlessCallbacks()` opens it
        /// only with no callback waiting, and reports it open once it is.
        @Test(.hegel(testCases: 1_000))
        func racingOpensReleaseOnce() throws {
            try property(reaching: ["opens raced", "openUnlessCallbacks opened it"]) { tc in
                let callbacks = try tc.draw(.oneOf(.int(in: 1...4), .just(0)), named: "callbacks")
                let openers = try tc.draw(
                    .array(of: .bool(probability: 0.8), count: 2...6),
                    named: "open (else openUnlessCallbacks)"
                )
                let gate = Gate()
                let runs = Runs()
                for key in 0..<callbacks { gate.wait { runs.append(key) } }
                // What each call returned, checked here: an issue recorded on
                // a thread of `race` would reach no test case.
                let returned = race(openers.count) { worker in
                    openers[worker] ? gate.open() : gate.openUnlessCallbacks()
                }
                let opens = zip(openers, returned).count { $0 && $1 }
                let unlessOpen = zip(openers, returned).filter { !$0.0 }.map(\.1)
                if callbacks > 0 {
                    #expect(gate.isOpen == openers.contains(true), "open: \(gate.isOpen)")
                    #expect(opens == (openers.contains(true) ? 1 : 0), "\(opens) opens")
                    // It reports the gate open once an `open()` has opened it.
                    #expect(
                        !unlessOpen.contains(true) || opens == 1,
                        "openUnlessCallbacks opened past a callback"
                    )
                } else {
                    #expect(gate.isOpen, "no callback waits, and the gate stayed closed")
                    #expect(opens <= 1, "\(opens) opens")
                    #expect(!unlessOpen.contains(false), "openUnlessCallbacks kept it closed")
                    if opens == 0 { try tc.event("openUnlessCallbacks opened it") }
                }
                let ran = runs.all
                #expect(Set(ran).count == ran.count, "a callback ran twice: \(ran)")
                if gate.isOpen {
                    #expect(ran.sorted() == Array(0..<callbacks), "ran \(ran)")
                } else {
                    #expect(ran.isEmpty, "ran \(ran) on a closed gate")
                }
                if openers.count(where: \.self) > 1 { try tc.event("opens raced") }
            }
        }
    }

    /// Runs `body` on `count` threads of their own, started together as
    /// near as the threads allow, and returns their results in order. Off
    /// the concurrency pool, which may have one thread: the start waits a
    /// millisecond at most for the others, so it never hangs.
    func race<T: Sendable>(_ count: Int, _ body: @escaping @Sendable (Int) -> T) -> [T] {
        let ready = Atomic(0)
        let results = Mutex([T?](repeating: nil, count: count))
        let done = DispatchGroup()
        for worker in 0..<count {
            DispatchQueue.global().async(group: done) {
                ready.add(1, ordering: .acquiringAndReleasing)
                let deadline = ContinuousClock.now + .milliseconds(1)
                while ready.load(ordering: .acquiring) < count, ContinuousClock.now < deadline {}
                let result = body(worker)
                results.withLock { $0[worker] = result }
            }
        }
        done.wait()
        return results.withLock { $0.map { $0! } }
    }

    enum GateReach {
        static let ranAtOnce = "a callback registered after the open ran at once"
        static let removed = "a waiting callback was removed"
        static let ranAtOpen = "callbacks ran at the open"
        static let keptClosed = "openUnlessCallbacks left the gate closed"
        static let ended = "a task's wait was ended"
        static let resumedAtOpen = "a task resumed at the open"
        static let wrongKind = "an id of the other kind did nothing"

        static let sequential = [
            ranAtOnce, removed, ranAtOpen, keptClosed, ended, resumedAtOpen, wrongKind,
        ]
        static let concurrent = [removed, ranAtOpen, ended, resumedAtOpen]
    }

    /// How long a task the gate should have resumed may take to return: far
    /// above what resuming takes on a loaded machine.
    private let resumeLimit = Duration.seconds(10)

    /// Callback numbers, in the order the callbacks ran.
    final class Runs: Sendable {
        private let runs = Mutex<[Int]>([])
        func append(_ key: Int) { runs.withLock { $0.append(key) } }
        var all: [Int] { runs.withLock { $0 } }
    }

    /// A task suspended in `openedOrEnded`, and whether it has returned.
    struct Waiter: Sendable {
        let task: Task<Void, Never>

        /// Whether the task returns within `resumeLimit`.
        func resumes() async -> Bool {
            (try? await withDeadline(resumeLimit) { await task.value }) != nil
        }
    }

    /// Suspends a task on `gate`; returns its wait's id once registered, or
    /// nil if it returned at once. `endAtOnce` ends the wait from inside the
    /// registration, as `withCancellation` does when its result is already in.
    func suspend(on gate: Gate, endAtOnce: Bool) async -> (UInt64?, Waiter) {
        let (registered, report) = AsyncStream<UInt64?>.makeStream()
        let task = Task {
            await gate.openedOrEnded { id in
                report.yield(id)
                return endAtOnce
            }
            report.yield(nil)
        }
        var first: UInt64?
        for await id in registered {
            first = id
            break
        }
        return (first, Waiter(task: task))
    }

    // MARK: - One at a time

    struct GateModel: Sendable {
        let gate = Gate()
        let runs = Runs()
        var ids: Pool<UInt64>
        var open = false
        var nextKey = 0
        /// Callbacks waiting, by id, in registration order.
        var callbacks: [(id: UInt64, key: Int)] = []
        var expectedRuns: [Int] = []
        var waiters: [UInt64: Waiter] = [:]

        /// Opens the model; the tasks waiting must all resume.
        mutating func opened(_ tc: TestCase) async throws {
            open = true
            expectedRuns += callbacks.map(\.key)
            if !callbacks.isEmpty { try tc.event(GateReach.ranAtOpen) }
            callbacks = []
            for (id, waiter) in waiters {
                #expect(await waiter.resumes(), "task \(id) not resumed by the open")
                try tc.event(GateReach.resumedAtOpen)
            }
            waiters = [:]
        }
    }

    let gateMachine = StateMachine<GateModel>()
        .rule("wait") { m, tc in
            let key = m.nextKey
            m.nextKey += 1
            let runs = m.runs
            let id = m.gate.wait { runs.append(key) }
            if m.open {
                #expect(id == nil, "an id from an open gate")
                m.expectedRuns.append(key)
                try tc.event(GateReach.ranAtOnce)
            } else {
                let id = try #require(id, "no id from a closed gate")
                m.callbacks.append((id, key))
                try m.ids.add(id)
            }
        }
        .rule("remove") { m, tc in
            let id = try tc.draw(m.ids.reusable, named: "id")
            let removed = m.gate.remove(id) != nil
            let index = m.callbacks.firstIndex { $0.id == id }
            #expect(removed == (index != nil), "remove(\(id)) returned \(removed)")
            if let index {
                m.callbacks.remove(at: index)
                try tc.event(GateReach.removed)
            } else if m.waiters[id] != nil {
                try tc.event(GateReach.wrongKind)
            }
        }
        .rule("suspend a task") { m, tc in
            let endAtOnce = try tc.draw(.bool(probability: 0.2), named: "endAtOnce")
            let (id, waiter) = await suspend(on: m.gate, endAtOnce: endAtOnce)
            if m.open {
                #expect(id == nil, "a task registered on an open gate")
            } else {
                let id = try #require(id, "a task not registered on a closed gate")
                try m.ids.add(id)
                if !endAtOnce { m.waiters[id] = waiter }
            }
            if m.open || endAtOnce {
                #expect(await waiter.resumes(), "a task not resumed at once")
            }
        }
        .rule("end a wait") { m, tc in
            let id = try tc.draw(m.ids.reusable, named: "id")
            m.gate.endWait(id)
            if let waiter = m.waiters.removeValue(forKey: id) {
                #expect(await waiter.resumes(), "task \(id) not resumed by endWait")
                try tc.event(GateReach.ended)
            } else if m.callbacks.contains(where: { $0.id == id }) {
                try tc.event(GateReach.wrongKind)
            }
        }
        .rule("open") { m, tc in
            let opened = m.gate.open()
            #expect(opened == !m.open, "open() returned \(opened)")
            try await m.opened(tc)
        }
        .rule("openUnlessCallbacks") { m, tc in
            let wasOpen = m.open
            let opened = m.gate.openUnlessCallbacks()
            let expected = wasOpen || m.callbacks.isEmpty
            #expect(opened == expected, "openUnlessCallbacks() returned \(opened)")
            if expected, !wasOpen {
                try await m.opened(tc)
            } else if !expected {
                try tc.event(GateReach.keptClosed)
            }
        }
        .invariant("open as the model", everyStep: true) { m, _ in
            #expect(m.gate.isOpen == m.open)
        }
        .invariant("callbacks ran as the model", everyStep: true) { m, _ in
            #expect(m.runs.all == m.expectedRuns)
        }

    // MARK: - Concurrently

    /// One gate the workers share, and what they did to it.
    final class SharedGate: Sendable {
        struct Callback {
            let key: Int
            var removed = false
        }

        struct State {
            var nextKey = 0
            var callbacks: [UInt64: Callback] = [:]
            /// Callbacks registered on an open gate: they ran at once.
            var ranAtOnce: Set<Int> = []
            var waiters: [UInt64: Waiter] = [:]
            var ended: Set<UInt64> = []
            var opens = 0
        }

        let gate = Gate()
        let runs = Runs()
        let ids: Pool<UInt64>
        let state = Mutex(State())

        init(ids: Pool<UInt64>) { self.ids = ids }

        func nextKey() -> Int {
            state.withLock { state in
                defer { state.nextKey += 1 }
                return state.nextKey
            }
        }
    }

    let concurrentGateMachine = ConcurrentStateMachine<SharedGate>(concurrency: 2...4)
        .rule("wait") { g, tc in
            let key = g.nextKey()
            let runs = g.runs
            if let id = g.gate.wait({ runs.append(key) }) {
                g.state.withLock { $0.callbacks[id] = .init(key: key) }
                try g.ids.add(id, using: tc)
            } else {
                g.state.withLock { _ = $0.ranAtOnce.insert(key) }
            }
        }
        .rule("remove") { g, tc in
            let id = try tc.draw(g.ids.reusable, named: "id")
            if g.gate.remove(id) != nil {
                let known = g.state.withLock { state in
                    defer { state.callbacks[id]?.removed = true }
                    return state.callbacks[id].map { !$0.removed } ?? false
                }
                #expect(known, "removed \(id), not a waiting callback")
                try tc.event(GateReach.removed)
            }
        }
        .rule("suspend a task") { g, tc in
            let (id, waiter) = await suspend(on: g.gate, endAtOnce: false)
            if let id {
                g.state.withLock { $0.waiters[id] = waiter }
                try g.ids.add(id, using: tc)
            } else {
                #expect(await waiter.resumes(), "a task not resumed at once")
            }
        }
        .rule("end a wait") { g, tc in
            let id = try tc.draw(g.ids.reusable, named: "id")
            g.gate.endWait(id)
            let isWaiter = g.state.withLock { state in
                state.ended.insert(id)
                return state.waiters[id] != nil
            }
            if isWaiter { try tc.event(GateReach.ended) }
        }
        .rule("open", weight: 0.3) { g, _ in
            if g.gate.open() { g.state.withLock { $0.opens += 1 } }
        }
        .rule("openUnlessCallbacks", weight: 0.3) { g, _ in
            _ = g.gate.openUnlessCallbacks()
        }
        .invariant("one open") { g, _ in
            #expect(g.state.withLock { $0.opens } <= 1)
        }
        .invariant("callbacks ran once, in order, unless removed", everyStep: true) { g, tc in
            let state = g.state.withLock { $0 }
            let runs = g.runs.all
            #expect(Set(runs).count == runs.count, "a callback ran twice: \(runs)")
            let removed = Set(state.callbacks.values.filter(\.removed).map(\.key))
            #expect(removed.isDisjoint(with: runs), "a removed callback ran: \(runs)")
            let atOpen = runs.filter { !state.ranAtOnce.contains($0) }
            if g.gate.isOpen {
                let registered = state.callbacks.sorted { $0.key < $1.key }
                    .filter { !$0.value.removed }.map(\.value.key)
                #expect(Set(atOpen) == Set(registered), "ran \(runs), registered \(registered)")
                let byID = Dictionary(
                    uniqueKeysWithValues: state.callbacks.map { ($0.value.key, $0.key) }
                )
                let ids = atOpen.compactMap { byID[$0] }
                #expect(ids == ids.sorted(), "callbacks ran out of registration order: \(atOpen)")
                if !atOpen.isEmpty { try tc.event(GateReach.ranAtOpen) }
            } else {
                #expect(atOpen.isEmpty, "a callback ran before the open: \(runs)")
            }
        }
        .invariant("waiting tasks resumed by the open or their end", everyStep: true) { g, tc in
            let (waiters, ended) = g.state.withLock { ($0.waiters, $0.ended) }
            let open = g.gate.isOpen
            for (id, waiter) in waiters where open || ended.contains(id) {
                #expect(await waiter.resumes(), "task \(id) not resumed")
                if open, !ended.contains(id) { try tc.event(GateReach.resumedAtOpen) }
            }
        }

#endif
