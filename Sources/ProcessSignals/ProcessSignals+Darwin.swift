#if canImport(Darwin)
    import Darwin
    import Dispatch

    /// Darwin: each signal is caught by ``catchSignal(_:)``, which does
    /// nothing, so its default action never runs, while kqueue — under a
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

        for signal in signals {
            let source = DispatchSource.makeSignalSource(signal: signal, queue: signalQueue)
            // Dispatch coalesces deliveries that arrive before the handler
            // runs; `data` is how many there were, so a quick double Ctrl-C
            // stays two.
            source.setEventHandler {
                for _ in 0..<max(source.data, 1) { continuation.yield(signal) }
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
        }

        return Subscription(signals: signals, sources: sources)
    }

    /// What one stream subscribed to, released when it ends.
    struct Subscription: Sendable {
        let signals: [Int32]
        let sources: [any DispatchSourceSignal]

        /// Dispositions first: a signal sent in between has its previous
        /// effect, rather than being caught with no source to record it.
        func release() {
            signals.forEach(removeSubscriber(from:))
            sources.forEach { $0.cancel() }
        }
    }

    /// One serial queue for every signal handler; handlers only yield.
    private let signalQueue = DispatchQueue(label: "ProcessSignals")

    /// The signal handler: nothing to do, kqueue has recorded the signal.
    private func catchSignal(_: Int32) {}

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
