// MM-59 debugging, on its branch only. Hegel runs on macOS and Linux only.
#if os(macOS) || os(Linux)

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif
    import HegelTesting
    @testable import ProcessSignals
    import Synchronization
    import Testing

    /// MM-59: `concurrentSubscriptionsKeepCount` crashes in libdispatch on Linux aarch64 (an item
    /// enqueued twice), alone and with either pair of fp-swift and hegel-swift versions. These take
    /// one layer away at a time: ProcessSignals (plain `AsyncStream`s instead), hegel (a plain task
    /// group instead), or both. They run only with `MM59_ROUNDS` set, the loop's round count.
    @Suite(.serialized, .enabled(if: mm59Rounds > 0))
    struct MM59Probes {
        /// B: hegel's concurrent machine, as in the property, with plain streams.
        @Test(.hegel(testCases: 200))
        func hegelPlainStreams() async throws {
            try await property { tc in
                let streams = ProbeStreams(real: false)
                do {
                    try await probeMachine.run(
                        tc,
                        from: ProbeShared(streams: streams, ids: try tc.pool())
                    )
                } catch {
                    await streams.endAll()
                    throw error
                }
                await streams.endAll()
            }
        }

        /// C: no hegel, no ProcessSignals: 2–4 tasks subscribing and ending plain streams at once.
        @Test func loopPlainStreams() async {
            await loop(real: false)
        }

        /// D: no hegel: the same loop with `registerSignals`. No signal is sent.
        @Test func loopRealSignals() async {
            await loop(real: true)
        }

        private func loop(real: Bool) async {
            for _ in 0..<mm59Rounds {
                let streams = ProbeStreams(real: real)
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<Int.random(in: 2...4) {
                        group.addTask {
                            for _ in 0..<Int.random(in: 1...8) {
                                if Bool.random(), let id = streams.anyID() {
                                    await streams.end(id)
                                } else {
                                    _ = await streams.subscribe(ours.filter { _ in Bool.random() })
                                }
                            }
                        }
                    }
                }
                await streams.endAll()
            }
        }
    }

    /// How many rounds the loops run; 0 (unset) turns the probes off.
    let mm59Rounds = getenv("MM59_ROUNDS").flatMap { Int(String(cString: $0)) } ?? 0

    /// Streams, each read by a task of its own, as `Streams` in SubscriptionProperties: from
    /// `registerSignals`, or plain ones whose termination takes a lock, as a release does.
    final class ProbeStreams: Sendable {
        let real: Bool
        private let readers = Mutex<[Int: Task<Void, Never>]>([:])
        private let nextID = Atomic(0)

        init(real: Bool) { self.real = real }

        func subscribe(_ requested: [Int32]) async -> Int {
            let stream: AsyncStream<Int32>
            if real {
                stream = await registerSignals(requested).stream
            } else {
                let (plain, continuation) = AsyncStream<Int32>.makeStream()
                continuation.onTermination = { _ in probeReleases.withLock { $0 += 1 } }
                stream = plain
            }
            let task = Task { for await _ in stream {} }
            let id = nextID.add(1, ordering: .relaxed).newValue
            readers.withLock { $0[id] = task }
            return id
        }

        func end(_ id: Int) async {
            guard let task = readers.withLock({ $0.removeValue(forKey: id) }) else { return }
            task.cancel()
            await task.value
        }

        func anyID() -> Int? { readers.withLock { $0.keys.randomElement() } }

        func endAll() async {
            for id in readers.withLock({ Array($0.keys) }) { await end(id) }
        }
    }

    let probeReleases = Mutex(0)

    final class ProbeShared: Sendable {
        let streams: ProbeStreams
        let ids: Pool<Int>

        init(streams: ProbeStreams, ids: Pool<Int>) {
            self.streams = streams
            self.ids = ids
        }
    }

    let probeMachine = ConcurrentStateMachine<ProbeShared>(concurrency: 2...4)
        .rule("subscribe") { s, tc in
            let requested = try tc.draw(SignalGen.requested, named: "requested")
            let id = await s.streams.subscribe(requested)
            try s.ids.add(id, using: tc)
        }
        .rule("end a stream") { s, tc in
            let id = try tc.draw(s.ids.consumed, named: "stream")
            await s.streams.end(id)
        }

#endif
