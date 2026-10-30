#if canImport(Glibc) || canImport(Musl) || canImport(Android)
    #if canImport(Glibc)
        import Glibc
    #elseif canImport(Musl)
        import Musl
    #elseif canImport(Android)
        import Android
    #endif
    import Dispatch
    import Synchronization

    // Linux and Android: a `sigaction` handler of our own writes each signal to a pipe,
    // and one Dispatch read source drains the pipe into every stream that
    // is subscribed to the signal.
    //
    // Dispatch *signal* sources are not used here: libdispatch installs a
    // handler of its own for them and never removes it, so the previous
    // disposition could not be restored (swift-corelibs-libdispatch,
    // src/event/event_epoll.c).

    /// Subscribes to each signal with ``handleSignal(_:)``, routing it to
    /// `continuation`. If no pipe could be made (the process is out of file
    /// descriptors), nothing is subscribed to and the stream ends at once.
    func subscribe(
        _ signals: [Int32],
        delivering continuation: AsyncStream<Int32>.Continuation
    ) async -> Subscription {
        guard let pipe = SignalPipe.shared() else {
            continuation.finish()
            return Subscription(signals: [], pipe: nil, route: 0)
        }
        // Route first, so a signal that arrives right after the handler is
        // installed already has somewhere to go.
        let route = pipe.route(signals, to: continuation)
        signals.forEach(addSubscriber(to:))
        return Subscription(signals: signals, pipe: pipe, route: route)
    }

    /// What one stream subscribed to, released when it ends.
    struct Subscription: Sendable {
        let signals: [Int32]
        /// `nil` if nothing was subscribed to.
        fileprivate let pipe: SignalPipe?
        fileprivate let route: UInt64

        func release() {
            signals.forEach(removeSubscriber(from:))
            pipe?.unroute(route)
        }
    }

    /// The write end of the pipe, read by the signal handler. An atomic, so
    /// reading it is async-signal-safe.
    private let pipeWriteEnd = Atomic<Int32>(-1)

    /// The signal handler: writes the signal number to the pipe as one byte.
    /// Only async-signal-safe calls, and `errno` is preserved for the code it
    /// interrupted.
    private func handleSignal(_ signal: Int32) {
        let saved = errno
        var byte = UInt8(truncatingIfNeeded: signal)
        _ = write(pipeWriteEnd.load(ordering: .relaxed), &byte, 1)
        errno = saved
    }

    /// The process's one signal pipe and its reader, created on first use.
    ///
    /// `@unchecked Sendable`: the read source is only touched in `init`, and
    /// the routes are behind a mutex. Linux's Dispatch module does not mark
    /// source types `Sendable`.
    private final class SignalPipe: @unchecked Sendable {
        /// The pipe; `nil` while it can't be made (the process is out of file
        /// descriptors), so that a later stream tries again.
        static func shared() -> SignalPipe? {
            current.withLock { pipe in
                if pipe == nil { pipe = SignalPipe() }
                return pipe
            }
        }

        private static let current = Mutex<SignalPipe?>(nil)

        /// One stream's signals and where they go.
        private struct Route {
            let signals: [Int32]
            let continuation: AsyncStream<Int32>.Continuation
        }

        private struct Routes {
            var lastID: UInt64 = 0
            var byID: [UInt64: Route] = [:]
        }

        private let routes = Mutex(Routes())
        private let reader: any DispatchSourceRead

        private init?() {
            guard let (readEnd, writeEnd) = makePipe() else { return nil }
            pipeWriteEnd.store(writeEnd, ordering: .releasing)

            reader = DispatchSource.makeReadSource(
                fileDescriptor: readEnd,
                queue: DispatchQueue(label: "ProcessSignals")
            )
            // A byte written before the source is registered waits in the
            // pipe, and the source fires once it is: no registration wait.
            // `self` is the process-wide pipe, never released: no cycle.
            reader.setEventHandler { [self] in drain(readEnd) }
            reader.resume()
        }

        /// Reads every pending signal byte and yields it to each stream that
        /// is subscribed to the signal.
        private func drain(_ readEnd: Int32) {
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                guard count > 0 else { return }
                routes.withLock { routes in
                    for byte in buffer.prefix(count) {
                        let signal = Int32(byte)
                        for route in routes.byID.values where route.signals.contains(signal) {
                            route.continuation.yield(signal)
                        }
                    }
                }
            }
        }

        /// Delivers `signals` to `continuation` until ``unroute(_:)`` is
        /// called with the returned id.
        func route(_ signals: [Int32], to continuation: AsyncStream<Int32>.Continuation) -> UInt64 {
            routes.withLock { routes in
                routes.lastID += 1
                routes.byID[routes.lastID] = Route(signals: signals, continuation: continuation)
                return routes.lastID
            }
        }

        func unroute(_ id: UInt64) {
            _ = routes.withLock { $0.byID.removeValue(forKey: id) }
        }
    }

    /// A pipe whose ends are both close-on-exec and non-blocking: the handler
    /// must never block on a full pipe, and the reader drains until it is
    /// empty. (`pipe` plus `fcntl`, because glibc only declares `pipe2` under
    /// `_GNU_SOURCE`, which Swift's Glibc module does not define.)
    private func makePipe() -> (read: Int32, write: Int32)? {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        for end in ends {
            let flags = fcntl(end, F_GETFL)
            guard fcntl(end, F_SETFD, FD_CLOEXEC) == 0,
                flags >= 0, fcntl(end, F_SETFL, flags | O_NONBLOCK) == 0
            else {
                ends.forEach { close($0) }
                return nil
            }
        }
        return (ends[0], ends[1])
    }

    /// A signal's disposition from before its first subscriber.
    struct Disposition: @unchecked Sendable {  // `sigaction` holds a C function pointer
        let signal: Int32
        let action: sigaction

        /// Installs ``handleSignal(_:)``, returning the previous disposition.
        static func create(_ signal: Int32) -> Disposition {
            var action = sigaction()
            action.handler = handleSignal
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
