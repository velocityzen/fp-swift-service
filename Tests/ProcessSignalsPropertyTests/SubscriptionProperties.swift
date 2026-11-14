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
        /// streams end, sometimes as a signal on them is on its way. After
        /// every step each signal has as many subscribers as the model has
        /// streams on it, and its disposition is the one from before exactly
        /// when it has none. Each send reaches every live stream subscribed
        /// to it, once, and is never lost: one sent as the last stream on it
        /// ends, or to no stream, reaches that stream or the handler from
        /// before, exactly once.
        @Test(.hegel(testCases: 200))
        func subscriptionsMatchTheModel() async throws {
            try await withCountingHandlers {
                try await property(reaching: SignalReach.sequential) { tc in
                    let streams = Streams()
                    do {
                        let model = try await subscriptionMachine.run(
                            tc,
                            from: SubscriptionModel(streams: streams, ids: try tc.pool())
                        )
                        await streams.endAll()
                        for signal in ours {
                            #expect(
                                disposition(signal) == countingHandler,
                                "\(signalName(signal)) not restored"
                            )
                            let (owed, got) = model.account(of: signal)
                            #expect(
                                got == owed,
                                "\(signalName(signal)): \(got) effects for \(owed)"
                            )
                        }
                    } catch {
                        await streams.endAll()
                        throw error
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
        static let racedLast = "a signal was sent as the last stream on it ended"
        static let racedReached = "a signal sent as its stream ended reached that stream"
        static let racedPrevious =
            "a signal sent as the last stream on it ended had its previous effect"
        static let unheld = "a signal was sent with no stream on it"

        static let sequential = [
            delivered, restored, shared, mixed, racedLast, racedReached, racedPrevious, unheld,
        ]
    }

    /// The signals these properties subscribe to and send.
    let ours: [Int32] = [SIGUSR2, SIGXFSZ, SIGVTALRM]

    /// How many times the suite's own handler ran, by signal: how often a
    /// signal had its previous effect.
    let previousEffects = InlineArray<65, Atomic<Int>> { _ in Atomic(0) }

    func previousEffects(of signal: Int32) -> Int {
        previousEffects[Int(signal)].load(ordering: .relaxed)
    }

    /// The suite's own handler, as `disposition` shows it.
    nonisolated(unsafe) var countingHandler: UInt = 0

    /// Runs `body` with the suite's counting handler on each of `ours`,
    /// then puts back what was there.
    func withCountingHandlers(_ body: () async throws -> Void) async throws {
        var counting = sigaction()
        counting.handler = { signal in previousEffects[Int(signal)].add(1, ordering: .relaxed) }
        sigemptyset(&counting.sa_mask)
        var originals: [sigaction] = []
        for signal in ours {
            var original = sigaction()
            sigaction(signal, &counting, &original)
            originals.append(original)
        }
        countingHandler = disposition(ours[0])
        defer {
            for (signal, var original) in zip(ours, originals) { sigaction(signal, &original, nil) }
        }
        try await body()
    }

    enum SignalGen {
        /// Mostly ours, with repeats; sometimes ones no stream can have.
        static let requested: Gen<[Int32]> = .array(
            of: .oneOf(.element(of: ours), .element(of: ours), .element(of: unavailable)),
            count: 0...6
        )

        /// Signals no stream can have: those that can't be caught, and numbers around the
        /// platform's range: none, negative, the first past the last (`NSIG`), the ones glibc keeps
        /// for itself, and far past it.
        static let unavailable: [Int32] = [SIGKILL, SIGSTOP, 0, -1, 1234, .max, .min] + pastTheEnd

        #if canImport(Darwin)
            static let pastTheEnd: [Int32] = [32]
        #else
            static let pastTheEnd: [Int32] = [32, 33, 65]
        #endif
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

        /// Waits, ten seconds at most, until `done` holds; returns whether it did.
        static func arrives(_ done: @escaping @Sendable () -> Bool) async -> Bool {
            (try? await withDeadline(.seconds(10)) { () async -> Bool in
                // Stops once the deadline cancels it: a cancelled sleep returns at once.
                while !done(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
                return done()
            }) ?? false
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
        /// Each signal's previous effects from before this test case.
        let effectsBefore = Dictionary(
            uniqueKeysWithValues: ours.map { ($0, previousEffects(of: $0)) }
        )
        /// Sends to no stream, by signal: each owes the handler from before.
        var unheld: [Int32: Int] = [:]
        /// Sends as a stream on the signal ended.
        var raced: [Race] = []

        /// A signal sent as a stream subscribed to it ended.
        struct Race: Sendable {
            let signal: Int32
            /// What the ending stream had got of it before.
            let before: Int
            let received: Streams.Received
            /// Whether no other stream held the signal: then it owes one
            /// effect, on the ending stream or the handler from before.
            let last: Bool

            /// Whether the ending stream got it.
            var reached: Int { received.count(of: signal) - before }
        }

        func count(of signal: Int32) -> Int { subscribed.values.count { $0.contains(signal) } }

        /// How many effects `signal`'s sends owe, outside the live streams, and how many
        /// happened: the handler from before running, and a stream that ended as the last on
        /// the signal getting it.
        func account(of signal: Int32) -> (owed: Int, got: Int) {
            let last = raced.filter { $0.signal == signal && $0.last }
            let effects = previousEffects(of: signal) - (effectsBefore[signal] ?? 0)
            return (
                (unheld[signal] ?? 0) + last.count,
                effects + last.reduce(0) { $0 + $1.reached }
            )
        }

        /// Waits until `signal`'s owed effects have happened, then a moment more for a second
        /// copy; returns whether they did.
        func settle(_ signal: Int32) async -> Bool {
            let model = self
            let done = await Streams.arrives {
                let (owed, got) = model.account(of: signal)
                return got >= owed
            }
            try? await Task.sleep(for: .milliseconds(2))
            return done
        }
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
            let arrived = await Streams.arrives { !waiting() }
            #expect(arrived, "\(signalName(signal)) didn't reach every stream on it")
            if receivers.count > 1 { try tc.event(SignalReach.delivered) }
        }
        .rule("send as a stream on it ends") { m, tc in
            let subscribed = m.subscribed
            let id = try tc.draw(
                m.ids.consumed { !(subscribed[$0] ?? []).isEmpty },
                named: "stream"
            )
            let signals = m.subscribed.removeValue(forKey: id) ?? []
            let signal = try tc.draw(.element(of: signals), named: "signal")
            guard let received = m.streams.live[id]?.received else {
                Issue.record("stream \(id) is not live")
                return
            }
            let before = received.count(of: signal)
            let receivers = m.subscribed.filter { $0.value.contains(signal) }.map(\.key)
            for other in receivers { m.sent[other, default: [:]][signal, default: 0] += 1 }
            m.sent[id] = nil
            let race = SubscriptionModel.Race(
                signal: signal,
                before: before,
                received: received,
                last: receivers.isEmpty
            )
            m.raced.append(race)

            // How long the signal has before its stream ends: none, or long enough for it to be
            // caught, or delivered.
            let gap = try tc.draw(.element(of: [0, 0, 20, 200, 2_000]), named: "gap (µs)")
            kill(getpid(), signal)
            if gap > 0 { try? await Task.sleep(for: .microseconds(gap)) }
            await m.streams.end(id)

            let live = m.streams.live
            let sent = m.sent
            let arrived = await Streams.arrives {
                receivers.allSatisfy { other in
                    (live[other]?.received.count(of: signal) ?? 0) >= (sent[other]?[signal] ?? 0)
                }
            }
            #expect(arrived, "\(signalName(signal)) didn't reach every other stream on it")
            #expect(await m.settle(signal), "\(signalName(signal)) was lost")
            #expect(
                (0...1).contains(race.reached),
                "the ending stream got it \(race.reached) times"
            )

            if race.reached == 1 { try tc.event(SignalReach.racedReached) }
            if race.last {
                try tc.event(SignalReach.racedLast)
                if race.reached == 0 { try tc.event(SignalReach.racedPrevious) }
                try tc.event(SignalReach.restored)
            }
        }
        .rule("send with no stream on it") { m, tc in
            let unheld = ours.filter { m.count(of: $0) == 0 }
            try tc.assume(!unheld.isEmpty)
            let signal = try tc.draw(.element(of: unheld), named: "signal")
            m.unheld[signal, default: 0] += 1
            kill(getpid(), signal)
            #expect(
                await m.settle(signal),
                "\(signalName(signal)) didn't reach its previous handler"
            )
            try tc.event(SignalReach.unheld)
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
        .invariant("a signal no live stream took had one effect", everyStep: true) { m, _ in
            for signal in ours {
                let (owed, got) = m.account(of: signal)
                #expect(got == owed, "\(signalName(signal)): \(got) effects for \(owed)")
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

#endif
