// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif
    import HegelTesting
    @testable import ProcessSignals
    import ServiceTestSupport
    import Synchronization
    import Testing

    /// Streams subscribing to and releasing real signals, and signals sent to
    /// the process. Dispositions are process-wide, and a target's tests share
    /// a process, so these use signals no other test does: SIGUSR2, SIGXFSZ
    /// and SIGVTALRM. Their default action ends the process, so for the
    /// suite's run each first gets a handler of the suite's own, which only
    /// counts: the disposition a subscription must restore, and harmless if
    /// a signal reaches it.
    @Suite(.hegel, .serialized)
    struct SubscriptionProperties {
        /// A stream subscribes to each requested signal it can, once, and
        /// reports the rest unavailable, once each, in the order requested.
        @Test(.hegel(testCases: 300))
        func requestedSignalsArePartitioned() async throws {
            try await withCountingHandlers {
                try await property { tc in
                    let requested = try tc.draw(SignalGen.requested, named: "requested")
                    let (stream, subscribed, unavailable) = await registerSignals(requested)
                    let reader = Task { for await _ in stream {} }
                    reader.cancel()
                    await reader.value

                    let unique = requested.withoutRepeats()
                    #expect(
                        subscribed == unique.filter(ours.contains),
                        "subscribed to \(subscribed)"
                    )
                    #expect(
                        unavailable == unique.filter { !ours.contains($0) },
                        "unavailable \(unavailable)"
                    )
                    for signal in ours {
                        #expect(
                            subscriberCount(of: signal) == 0,
                            "\(signalName(signal)) left subscribed"
                        )
                    }
                }
            }
        }

        /// One operation at a time: streams subscribe, signals are sent,
        /// streams end. After every step each signal has as many subscribers
        /// as the model has streams on it, and its disposition is the one
        /// from before exactly when it has none. Each send reaches every
        /// stream subscribed to it, once, and never the handler from before.
        @Test(.hegel(testCases: 200))
        func subscriptionsMatchTheModel() async throws {
            try await withCountingHandlers {
                try await property(reaching: SignalReach.sequential) { tc in
                    let streams = Streams()
                    do {
                        _ = try await subscriptionMachine.run(
                            tc,
                            from: SubscriptionModel(streams: streams, ids: try tc.pool())
                        )
                    } catch {
                        await streams.endAll()
                        throw error
                    }
                    await streams.endAll()
                    for signal in ours {
                        #expect(
                            disposition(signal) == countingHandler,
                            "\(signalName(signal)) not restored"
                        )
                    }
                    #expect(
                        previousEffects.load(ordering: .relaxed) == 0,
                        "a delivered signal also ran its previous handler"
                    )
                }
            }
        }

        /// Streams subscribing and ending from several tasks at once: between
        /// rounds, each signal's subscriber count is the number of live
        /// streams on it, and a signal with none has its disposition back.
        @Test(.hegel(testCases: 200))
        func concurrentSubscriptionsKeepCount() async throws {
            try await withCountingHandlers {
                try await property(reaching: [SignalReach.restored, SignalReach.shared]) { tc in
                    let streams = Streams()
                    do {
                        try await concurrentSubscriptionMachine.run(
                            tc,
                            from: SharedStreams(streams: streams, ids: try tc.pool())
                        )
                    } catch {
                        await streams.endAll()
                        throw error
                    }
                    await streams.endAll()
                    for signal in ours {
                        #expect(subscriberCount(of: signal) == 0)
                        #expect(disposition(signal) == countingHandler)
                    }
                }
            }
        }
    }

    enum SignalReach {
        static let delivered = "a signal reached several streams"
        static let restored = "the last stream on a signal ended"
        static let shared = "streams shared a signal"
        static let mixed = "a stream subscribed to several signals"

        static let sequential = [delivered, restored, shared, mixed]
    }

    /// The signals these properties subscribe to and send.
    let ours: [Int32] = [SIGUSR2, SIGXFSZ, SIGVTALRM]

    /// How many times the suite's own handler ran: a signal that had its
    /// previous effect besides being delivered.
    let previousEffects = Atomic<Int>(0)

    /// The suite's own handler, as `disposition` shows it.
    nonisolated(unsafe) var countingHandler: UInt = 0

    /// Runs `body` with the suite's counting handler on each of `ours`,
    /// then puts back what was there.
    func withCountingHandlers(_ body: () async throws -> Void) async throws {
        var counting = sigaction()
        counting.handler = { _ in previousEffects.add(1, ordering: .relaxed) }
        sigemptyset(&counting.sa_mask)
        var originals: [sigaction] = []
        for signal in ours {
            var original = sigaction()
            sigaction(signal, &counting, &original)
            originals.append(original)
        }
        countingHandler = disposition(ours[0])
        previousEffects.store(0, ordering: .relaxed)
        defer {
            for (signal, var original) in zip(ours, originals) { sigaction(signal, &original, nil) }
        }
        try await body()
    }

    enum SignalGen {
        /// Mostly ours, with repeats; sometimes ones no stream can have.
        static let requested: Gen<[Int32]> = .array(
            of: .oneOf(
                .element(of: ours),
                .element(of: ours),
                .element(of: [SIGKILL, SIGSTOP, 0, -1, 1234])
            ),
            count: 0...6
        )
    }

    // MARK: - Streams

    /// The streams of one test case, each read by a task of its own that
    /// counts what it gets.
    final class Streams: Sendable {
        struct Reader: Sendable {
            let signals: [Int32]
            let task: Task<Void, Never>
            let received: Received
        }

        final class Received: Sendable {
            let counts = Mutex<[Int32: Int]>([:])
            func count(of signal: Int32) -> Int { counts.withLock { $0[signal] ?? 0 } }
        }

        private let readers = Mutex<[Int: Reader]>([:])
        private let nextID = Atomic(0)

        /// Subscribes a stream to `requested`; returns its id and the signals
        /// it subscribed to.
        func subscribe(_ requested: [Int32]) async -> (id: Int, signals: [Int32]) {
            let (stream, subscribed, _) = await registerSignals(requested)
            let received = Received()
            let task = Task {
                for await signal in stream {
                    received.counts.withLock { $0[signal, default: 0] += 1 }
                }
            }
            let id = nextID.add(1, ordering: .relaxed).newValue
            readers.withLock {
                $0[id] = Reader(signals: subscribed, task: task, received: received)
            }
            return (id, subscribed)
        }

        /// Ends stream `id` by cancelling its reader, and waits for it;
        /// returns the signals it had.
        @discardableResult
        func end(_ id: Int) async -> [Int32] {
            guard let reader = readers.withLock({ $0.removeValue(forKey: id) }) else { return [] }
            reader.task.cancel()
            await reader.task.value
            return reader.signals
        }

        func endAll() async {
            for id in readers.withLock({ Array($0.keys) }) { await end(id) }
        }

        var live: [Int: Reader] { readers.withLock { $0 } }
    }

    // MARK: - One at a time

    struct SubscriptionModel: Sendable {
        let streams: Streams
        var ids: Pool<Int>
        /// The live streams' signals, by id.
        var subscribed: [Int: [Int32]] = [:]
        /// How many times each stream has been sent each signal.
        var sent: [Int: [Int32: Int]] = [:]

        func count(of signal: Int32) -> Int { subscribed.values.count { $0.contains(signal) } }
    }

    let subscriptionMachine = StateMachine<SubscriptionModel>()
        .rule("subscribe") { m, tc in
            let requested = try tc.draw(SignalGen.requested, named: "requested")
            let (id, signals) = await m.streams.subscribe(requested)
            #expect(
                Set(signals) == Set(requested.filter(ours.contains)),
                "subscribed to \(signals)"
            )
            m.subscribed[id] = signals
            m.sent[id] = [:]
            try m.ids.add(id)
            if signals.count > 1 { try tc.event(SignalReach.mixed) }
            if signals.contains(where: { m.count(of: $0) > 1 }) { try tc.event(SignalReach.shared) }
        }
        .rule("end a stream") { m, tc in
            let id = try tc.draw(m.ids.consumed, named: "stream")
            await m.streams.end(id)
            let signals = m.subscribed.removeValue(forKey: id) ?? []
            m.sent[id] = nil
            if signals.contains(where: { m.count(of: $0) == 0 }) {
                try tc.event(SignalReach.restored)
            }
        }
        .rule("send") { m, tc in
            let held = ours.filter { m.count(of: $0) > 0 }
            try tc.assume(!held.isEmpty)
            let signal = try tc.draw(.element(of: held), named: "signal")
            let receivers = m.subscribed.filter { $0.value.contains(signal) }.map(\.key)
            for id in receivers { m.sent[id, default: [:]][signal, default: 0] += 1 }
            kill(getpid(), signal)
            // Every stream on it gets it before anything else happens, so no
            // stream ends while the signal is on its way.
            let live = m.streams.live
            let sent = m.sent
            let waiting: @Sendable () -> Bool = {
                receivers.contains { id in
                    (live[id]?.received.count(of: signal) ?? 0) < (sent[id]?[signal] ?? 0)
                }
            }
            let arrived =
                (try? await withDeadline(.seconds(10)) { () async -> Bool in
                    while waiting() { try? await Task.sleep(for: .milliseconds(1)) }
                    return true
                }) ?? false
            #expect(arrived, "\(signalName(signal)) didn't reach every stream on it")
            if receivers.count > 1 { try tc.event(SignalReach.delivered) }
        }
        .invariant("subscribers as the model", everyStep: true) { m, _ in
            for signal in ours {
                #expect(subscriberCount(of: signal) == m.count(of: signal), "\(signalName(signal))")
            }
        }
        .invariant("caught while subscribed, restored once not", everyStep: true) { m, _ in
            for signal in ours {
                let restored = disposition(signal) == countingHandler
                #expect(restored == (m.count(of: signal) == 0), "\(signalName(signal))")
            }
        }
        .invariant("each send arrived once", everyStep: true) { m, _ in
            let live = m.streams.live
            for (id, sent) in m.sent {
                for signal in ours {
                    let got = live[id]?.received.count(of: signal) ?? 0
                    #expect(
                        got == sent[signal] ?? 0,
                        "stream \(id) got \(signalName(signal)) \(got) times"
                    )
                }
            }
        }

    // MARK: - Concurrently

    /// The streams the workers share.
    final class SharedStreams: Sendable {
        let streams: Streams
        let ids: Pool<Int>

        init(streams: Streams, ids: Pool<Int>) {
            self.streams = streams
            self.ids = ids
        }
    }

    let concurrentSubscriptionMachine = ConcurrentStateMachine<SharedStreams>(concurrency: 2...4)
        .rule("subscribe") { s, tc in
            let requested = try tc.draw(SignalGen.requested, named: "requested")
            let (id, _) = await s.streams.subscribe(requested)
            try s.ids.add(id, using: tc)
        }
        .rule("end a stream") { s, tc in
            let id = try tc.draw(s.ids.consumed, named: "stream")
            let signals = await s.streams.end(id)
            let live = s.streams.live.values
            if signals.contains(where: { signal in !live.contains { $0.signals.contains(signal) } })
            {
                try tc.event(SignalReach.restored)
            }
        }
        .invariant("subscribers are the live streams", everyStep: true) { s, tc in
            let live = s.streams.live.values
            for signal in ours {
                let streams = live.count { $0.signals.contains(signal) }
                #expect(subscriberCount(of: signal) == streams, "\(signalName(signal))")
                let restored = disposition(signal) == countingHandler
                #expect(restored == (streams == 0), "\(signalName(signal)) restored: \(restored)")
                if streams > 1 { try tc.event(SignalReach.shared) }
            }
        }

#endif
