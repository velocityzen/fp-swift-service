#if canImport(Darwin)
    import Darwin
    import Dispatch

    /// Darwin: each signal is set to `SIG_IGN`, so its default action never
    /// runs, while kqueue — under a Dispatch signal source — still records it.
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
            // Ignored only once kqueue records it: a signal sent in between
            // has its previous effect and is delivered too, rather than
            // being ignored and lost.
            addSubscriber(to: signal)
            sources.append(source)
        }

        return Subscription(signals: signals, sources: sources)
    }

    /// What one stream subscribed to, released when it ends.
    struct Subscription: Sendable {
        let signals: [Int32]
        let sources: [any DispatchSourceSignal]

        func release() {
            sources.forEach { $0.cancel() }
            signals.forEach(removeSubscriber(from:))
        }
    }

    /// One serial queue for every signal handler; handlers only yield.
    private let signalQueue = DispatchQueue(label: "ProcessSignals")

    /// A signal's disposition from before its first subscriber.
    struct Disposition: @unchecked Sendable {  // `sigaction` holds a C function pointer
        let signal: Int32
        let action: sigaction

        /// Sets `SIG_IGN`, returning the previous disposition.
        static func create(_ signal: Int32) -> Disposition {
            var ignore = sigaction()
            ignore.handler = SIG_IGN
            var previous = sigaction()
            sigaction(signal, &ignore, &previous)
            return Disposition(signal: signal, action: previous)
        }

        func restore() {
            var action = action
            sigaction(signal, &action, nil)
        }
    }
#endif
