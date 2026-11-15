#if canImport(Darwin)
    import Darwin
    import Dispatch
    import Synchronization

    // Darwin: a kqueue of our own records every send of each subscribed signal, and a Dispatch
    // source on it delivers each one to every stream subscribed to the signal. A handler of ours,
    // ``catchSignal(_:)``, catches the signal meanwhile, so its default action never runs, and
    // only counts the catch.
    //
    // kqueue and not the handler decides delivery: the handler may run late, or not at all. Thread
    // Sanitizer holds a handler back until the thread that took the signal runs instrumented code
    // again, which an idle main thread may not do for a long time; and a signal every thread
    // blocks is never caught, while kqueue still records it.
    //
    // The kqueue is read directly, not through Dispatch signal sources, so that a release can
    // collect every send recorded so far before it lets go of the signal (see `Subscription`).
    //
    // Caught rather than set to `SIG_IGN`: an ignored signal stays ignored across `exec`, in
    // every child process, where a caught one is reset to its default action; and an ignored
    // SIGCHLD is never sent at all, while exited children are reaped at once, so `waitpid` fails.

    /// Subscribes to each signal, routing it to `continuation`. If no kqueue could be made (the
    /// process is out of file descriptors), nothing is subscribed to and the stream ends at once.
    func subscribe(
        _ signals: [Int32],
        delivering continuation: AsyncStream<Int32>.Continuation
    ) async -> Subscription {
        guard SignalQueue.open() else {
            continuation.finish()
            return Subscription(signals: [], route: nil)
        }
        // Route first, so a signal that arrives right after it is caught already has somewhere
        // to go.
        let route = routes.route(signals, to: continuation)
        signals.forEach(addSubscriber(to:))
        return Subscription(signals: signals, route: route)
    }

    /// What one stream subscribed to, released when it ends.
    struct Subscription: Sendable {
        let signals: [Int32]
        /// `nil` if nothing was subscribed to.
        fileprivate let route: UInt64?

        /// Waits until the process has caught what kqueue recorded, 50 milliseconds at most, then
        /// lets go of the signals, and delivers what kqueue recorded meanwhile.
        ///
        /// kqueue records a signal when it is sent, and a thread takes it later, with the
        /// disposition it has then. Restored in between, a delivered signal would have its
        /// previous effect too; and as `SIG_DFL`, even a signal whose default is to ignore ends
        /// the process, since the kernel decided to deliver it when it was caught. Copies sent
        /// while one is pending merge into one catch, so this waits the limit at most.
        ///
        /// The last stream on a signal collects what kqueue recorded until the disposition was
        /// restored (see ``Disposition/restore()``); delivered here, after the stream is gone, a
        /// signal no stream takes is sent again, to that disposition.
        func release() {
            guard let route else { return }
            let deadline = ContinuousClock.now + .milliseconds(50)
            SignalQueue.collect()
            while signals.contains(where: isInFlight), ContinuousClock.now < deadline {
                usleep(100)
                SignalQueue.collect()
            }
            signals.forEach(removeSubscriber(from:))
            routes.unroute(route)
            SignalQueue.deliverCollected()
        }
    }

    /// What kqueue and the handler counted of one signal, by signal number (Darwin has 31).
    private struct Counts: ~Copyable {
        /// Catches by ``catchSignal(_:)``.
        let caught = Atomic(0)
        /// Sends kqueue recorded.
        let recorded = Atomic(0)
        /// `recorded - caught` when the signal's first subscriber caught it: whatever the two
        /// counted before.
        let settled = Atomic(0)
    }

    private let counts = InlineArray<32, Counts> { _ in Counts() }

    /// `signal`'s recorded sends less its catches.
    private func unsettled(_ signal: Int32) -> Int {
        counts[Int(signal)].recorded.load(ordering: .relaxed)
            - counts[Int(signal)].caught.load(ordering: .relaxed)
    }

    /// Whether a send of `signal` that kqueue recorded is not yet caught.
    private func isInFlight(_ signal: Int32) -> Bool {
        unsettled(signal) > counts[Int(signal)].settled.load(ordering: .relaxed)
    }

    /// The signal handler: kqueue records the signal, so it only counts the catch.
    private func catchSignal(_ signal: Int32) {
        counts[Int(signal)].caught.add(1, ordering: .relaxed)
    }

    /// The kqueue element type: `kevent` alone names the function.
    private typealias KernelEvent = kevent

    /// The process's one kqueue for signals and its reader, made on first use.
    ///
    /// `@unchecked Sendable`: the read source is only touched in `init`.
    private final class SignalQueue: @unchecked Sendable {
        /// Opens the kqueue if it isn't yet; returns whether it is. It can't be while the process
        /// is out of file descriptors, so a later stream tries again.
        static func open() -> Bool {
            current.withLock { queue in
                if queue == nil { queue = SignalQueue() }
                return queue != nil
            }
        }

        private static let current = Mutex<SignalQueue?>(nil)

        /// The kqueue, once open.
        private static let descriptor = Atomic<Int32>(-1)

        /// Sends read from the kqueue and not yet delivered, in order.
        private static let collected = Mutex<[Int32]>([])

        private let reader: any DispatchSourceRead

        private init?() {
            let descriptor = kqueue()
            guard descriptor >= 0 else { return nil }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            Self.descriptor.store(descriptor, ordering: .releasing)

            reader = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue(label: "ProcessSignals")
            )
            reader.setEventHandler {
                SignalQueue.collect()
                SignalQueue.deliverCollected()
            }
            reader.resume()
        }

        /// Starts or stops kqueue recording `signal`. Registered at once, with no wait: a send
        /// after this returns is recorded.
        static func record(_ signal: Int32, _ on: Bool) {
            var change = KernelEvent(
                ident: UInt(signal),
                filter: Int16(EVFILT_SIGNAL),
                flags: UInt16(on ? EV_ADD : EV_DELETE),
                fflags: 0,
                data: 0,
                udata: nil
            )
            _ = kevent(descriptor.load(ordering: .acquiring), &change, 1, nil, 0, nil)
        }

        /// Reads every send kqueue has recorded, to be delivered.
        static func collect() {
            let descriptor = descriptor.load(ordering: .acquiring)
            guard descriptor >= 0 else { return }
            collected.withLock { collected in
                var events = [KernelEvent](repeating: KernelEvent(), count: 32)
                var now = timespec(tv_sec: 0, tv_nsec: 0)
                while true {
                    let count = kevent(descriptor, nil, 0, &events, Int32(events.count), &now)
                    guard count > 0 else { return }
                    for event in events.prefix(Int(count)) {
                        let signal = Int32(event.ident)
                        counts[Int(signal)].recorded.add(event.data, ordering: .relaxed)
                        collected += repeatElement(signal, count: event.data)
                    }
                }
            }
        }

        /// Delivers what ``collect()`` read, outside its lock (see ``SignalRoutes/deliver(_:)``).
        ///
        /// A signal no stream takes is sent to the process again: the streams holding it have
        /// ended, but not yet released it. It comes back here until a stream subscribed since
        /// takes it, or the last release restores the previous disposition, which then has it.
        /// With `kill`, to the whole process: Dispatch threads block it.
        static func deliverCollected() {
            let signals = collected.withLock { collected in
                defer { collected = [] }
                return collected
            }
            for signal in signals where !routes.deliver(signal) {
                kill(getpid(), signal)
            }
        }
    }

    /// A signal's disposition from before its first subscriber.
    struct Disposition: @unchecked Sendable {  // `sigaction` holds a C function pointer
        let signal: Int32
        let action: sigaction

        /// Has kqueue record `signal`, then installs ``catchSignal(_:)``, returning the previous
        /// disposition. Recorded first: a signal sent in between has its previous effect and is
        /// delivered too, rather than being caught and lost.
        static func create(_ signal: Int32) -> Disposition {
            SignalQueue.record(signal, true)
            counts[Int(signal)].settled.store(unsettled(signal), ordering: .relaxed)

            var action = sigaction()
            action.handler = catchSignal
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            var previous = sigaction()
            sigaction(signal, &action, &previous)
            return Disposition(signal: signal, action: previous)
        }

        /// Restores the previous disposition, then collects what kqueue recorded until then, and
        /// stops it recording `signal`. The last release delivers what was collected.
        func restore() {
            var action = action
            sigaction(signal, &action, nil)
            SignalQueue.collect()
            SignalQueue.record(signal, false)
        }
    }
#endif
