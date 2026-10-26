#if canImport(Darwin)
    import Darwin
    import Dispatch

    /// Darwin: each signal is set to `SIG_IGN`, so its default action never
    /// runs, while kqueue — under a Dispatch signal source — still records it.
    func takeOver(
        _ signals: [Int32],
        delivering continuation: AsyncStream<Int32>.Continuation
    ) async -> Takeover {
        var sources: [any DispatchSourceSignal] = []
        var previous: [Disposition] = []

        for signal in signals {
            previous.append(Disposition.ignore(signal))
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
            sources.append(source)
        }

        return Takeover(sources: sources, previous: previous)
    }

    /// What one stream took over, released when it ends.
    struct Takeover: Sendable {
        let sources: [any DispatchSourceSignal]
        let previous: [Disposition]

        func release() {
            sources.forEach { $0.cancel() }
            previous.forEach { $0.restore() }
        }
    }

    /// One serial queue for every signal handler; handlers only yield.
    private let signalQueue = DispatchQueue(label: "ProcessSignals")

    /// A signal's disposition from before the stream took it over.
    struct Disposition: @unchecked Sendable {  // `sigaction` holds a C function pointer
        let signal: Int32
        let action: sigaction

        /// Sets `SIG_IGN`, returning the previous disposition.
        static func ignore(_ signal: Int32) -> Disposition {
            var ignore = sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
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
