#if canImport(Darwin)
    import Darwin
    import Dispatch
    import Synchronization

    /// Darwin: each signal is caught by ``catchSignal(_:)``, which only
    /// counts it, so its default action never runs, while kqueue — under a
    /// Dispatch signal source — still records it.
    ///
    /// Caught rather than set to `SIG_IGN`: an ignored signal stays ignored
    /// across `exec`, in every child process, where a caught one is reset to
    /// its default action; and an ignored SIGCHLD is never sent at all, while
    /// exited children are reaped at once, so `waitpid` fails.
    func subscribe(
        _ signals: [Int32],
        delivering continuation: AsyncStream<Int32>.Continuation
    ) async -> Subscription {
        // No source would register, so nothing would end the wait below.
        guard !signals.isEmpty else {
            return Subscription(signals: [], sources: [])
        }

        let sources = signals.map { SignalSource(of: $0, delivering: continuation) }
        // Registration is asynchronous; wait for every source's, so a signal
        // sent right after `processSignals` returns is not missed. The
        // sources register together, so the wait is one, not one each.
        await withUnsafeContinuation { (registered: UnsafeContinuation<Void, Never>) in
            let registrations = Registrations(sources.count, then: registered)
            sources.forEach { $0.register(registrations) }
        }
        // Caught only once kqueue records it: a signal sent in between has
        // its previous effect and is delivered too, rather than being caught
        // and lost.
        signals.forEach(addSubscriber(to:))
        return Subscription(signals: signals, sources: sources)
    }

    /// What one stream subscribed to, released when it ends.
    struct Subscription: Sendable {
        let signals: [Int32]
        let sources: [SignalSource]

        /// Dispositions first: a signal sent in between has its previous
        /// effect, rather than being caught with no source to record it.
        ///
        /// But not before the process has caught what the stream recorded:
        /// kqueue records a signal when it is sent, and a thread takes it
        /// later, with the disposition it has then. Restored in between, a
        /// recorded signal would have its previous effect too; and as
        /// `SIG_DFL`, even a signal whose default is to ignore ends the
        /// process, since the kernel decided to deliver it when it was
        /// caught. Copies sent while one is pending merge into one catch, so
        /// this waits a moment at most.
        func release() {
            let deadline = ContinuousClock.now + .milliseconds(50)
            while sources.contains(where: { $0.inFlight }), ContinuousClock.now < deadline {
                usleep(100)
            }
            signals.forEach(removeSubscriber(from:))
            sources.forEach { $0.cancel() }
        }
    }

    /// One serial queue for every signal handler; handlers only yield.
    private let signalQueue = DispatchQueue(label: "ProcessSignals")

    /// The signal handler: kqueue has recorded the signal, so it only counts
    /// the catch (see ``Subscription/release()``).
    private func catchSignal(_ signal: Int32) {
        caught[Int(signal)].add(1, ordering: .relaxed)
    }

    /// How many times each signal has been caught, by number (Darwin has
    /// 31).
    private let caught = InlineArray<32, Atomic<Int>> { _ in Atomic(0) }

    /// One signal's Dispatch source for a stream, and the deliveries it has
    /// recorded against the catches since it subscribed.
    ///
    /// The source's handlers capture only this, which holds the rest, so
    /// they need no context of their own. The source and its event handler
    /// hold each other until the source is cancelled.
    final class SignalSource: Sendable {
        private let signal: Int32
        private let source: any DispatchSourceSignal
        private let continuation: AsyncStream<Int32>.Continuation
        private let caughtBefore: Int
        private let recorded = Atomic<Int>(0)

        init(of signal: Int32, delivering continuation: AsyncStream<Int32>.Continuation) {
            self.signal = signal
            self.continuation = continuation
            source = DispatchSource.makeSignalSource(signal: signal, queue: signalQueue)
            caughtBefore = caught[Int(signal)].load(ordering: .relaxed)
            source.setEventHandler { self.deliver() }
        }

        /// Starts the source; `registrations` learns when kqueue has it.
        func register(_ registrations: Registrations) {
            source.setRegistrationHandler { registrations.registered() }
            source.resume()
        }

        func cancel() { source.cancel() }

        /// Dispatch coalesces deliveries that arrive before the handler
        /// runs; `data` is how many there were, so a quick double Ctrl-C
        /// stays two.
        private func deliver() {
            let count = max(Int(source.data), 1)
            recorded.add(count, ordering: .relaxed)
            for _ in 0..<count { continuation.yield(signal) }
        }

        /// Whether a recorded delivery has not been caught yet.
        var inFlight: Bool {
            caught[Int(signal)].load(ordering: .relaxed) - caughtBefore
                < recorded.load(ordering: .relaxed)
        }
    }

    /// Counts sources down as they register, and resumes the subscribing
    /// task once all have.
    final class Registrations: Sendable {
        private let remaining: Atomic<Int>
        private let done: UnsafeContinuation<Void, Never>

        init(_ count: Int, then done: UnsafeContinuation<Void, Never>) {
            remaining = Atomic(count)
            self.done = done
        }

        func registered() {
            if remaining.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
                done.resume()
            }
        }
    }

    /// A signal's disposition from before its first subscriber.
    struct Disposition: @unchecked Sendable {  // `sigaction` holds a C function pointer
        let signal: Int32
        let action: sigaction

        /// Installs ``catchSignal(_:)``, returning the previous disposition.
        static func create(_ signal: Int32) -> Disposition {
            var action = sigaction()
            action.handler = catchSignal
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            var previous = sigaction()
            sigaction(signal, &action, &previous)
            return Disposition(signal: signal, action: previous)
        }

        func restore() {
            var action = action
            sigaction(signal, &action, nil)
        }
    }
#endif
