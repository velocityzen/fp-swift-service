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
        var sources: [any DispatchSourceSignal] = []
        var deliveries: [Deliveries] = []

        for signal in signals {
            let source = DispatchSource.makeSignalSource(signal: signal, queue: signalQueue)
            let recorded = Deliveries(of: signal)
            // Dispatch coalesces deliveries that arrive before the handler
            // runs; `data` is how many there were, so a quick double Ctrl-C
            // stays two.
            source.setEventHandler {
                let count = max(Int(source.data), 1)
                recorded.record(count)
                for _ in 0..<count { continuation.yield(signal) }
            }
            // Registration is asynchronous; wait for it, so a signal sent
            // right after `processSignals` returns is not missed.
            await withCheckedContinuation { (registered: CheckedContinuation<Void, Never>) in
                source.setRegistrationHandler { registered.resume() }
                source.resume()
            }
            // Caught only once kqueue records it: a signal sent in between
            // has its previous effect and is delivered too, rather than
            // being caught and lost.
            addSubscriber(to: signal)
            sources.append(source)
            deliveries.append(recorded)
        }

        return Subscription(signals: signals, sources: sources, deliveries: deliveries)
    }

    /// What one stream subscribed to, released when it ends.
    struct Subscription: Sendable {
        let signals: [Int32]
        let sources: [any DispatchSourceSignal]
        let deliveries: [Deliveries]

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
            while deliveries.contains(where: \.inFlight), ContinuousClock.now < deadline {
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

    /// The deliveries of one signal a stream's source has recorded, against
    /// the catches since it subscribed.
    final class Deliveries: Sendable {
        private let signal: Int32
        private let caughtBefore: Int
        private let recorded = Atomic<Int>(0)

        init(of signal: Int32) {
            self.signal = signal
            caughtBefore = caught[Int(signal)].load(ordering: .relaxed)
        }

        func record(_ count: Int) { recorded.add(count, ordering: .relaxed) }

        /// Whether a recorded delivery has not been caught yet.
        var inFlight: Bool {
            caught[Int(signal)].load(ordering: .relaxed) - caughtBefore
                < recorded.load(ordering: .relaxed)
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
