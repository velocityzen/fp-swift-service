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

    // Linux and Android: a `sigaction` handler of our own writes each signal to a pipe, and one
    // Dispatch read source drains the pipe into every stream that is subscribed to the signal. A
    // signal no stream takes, since each one holding it has ended, is sent again: to a stream
    // still subscribed, or to the disposition the last one restored.
    //
    // Dispatch *signal* sources are not used here: libdispatch installs a handler of its own for
    // them and never removes it, so the previous disposition could not be restored
    // (swift-corelibs-libdispatch, src/event/event_epoll.c).

    /// Subscribes to each signal with ``handleSignal(_:)``, routing it to `continuation`. If no
    /// pipe could be made (the process is out of file descriptors), nothing is subscribed to and
    /// the stream ends at once.
    func subscribe(
        _ signals: [Int32],
        delivering continuation: AsyncStream<Int32>.Continuation
    ) async -> Subscription {
        guard SignalPipe.open() else {
            continuation.finish()
            return Subscription(signals: [], route: nil)
        }
        // Route first, so a signal that arrives right after the handler is installed already
        // has somewhere to go.
        let route = routes.route(signals, to: continuation)
        signals.forEach(addSubscriber(to:))
        return Subscription(signals: signals, route: route)
    }

    /// What one stream subscribed to, released when it ends.
    struct Subscription: Sendable {
        let signals: [Int32]
        /// `nil` if nothing was subscribed to.
        fileprivate let route: UInt64?

        func release() {
            signals.forEach(removeSubscriber(from:))
            if let route { routes.unroute(route) }
        }
    }

    /// The write end of the pipe, read by the signal handler. An atomic, so reading it is
    /// async-signal-safe.
    private let pipeWriteEnd = Atomic<Int32>(-1)

    /// The signal handler: writes the signal number to the pipe as one byte. Only
    /// async-signal-safe calls, and `errno` is preserved for the code it interrupted.
    private func handleSignal(_ signal: Int32) {
        let saved = errno
        var byte = UInt8(truncatingIfNeeded: signal)
        _ = write(pipeWriteEnd.load(ordering: .relaxed), &byte, 1)
        errno = saved
    }

    /// The process's one signal pipe and its reader, created on first use.
    ///
    /// `@unchecked Sendable`: the read source is only touched in `init`. Linux's Dispatch module
    /// does not mark source types `Sendable`.
    private final class SignalPipe: @unchecked Sendable {
        /// Opens the pipe if it isn't yet; returns whether it is. It can't be while the process
        /// is out of file descriptors, so a later stream tries again.
        static func open() -> Bool {
            current.withLock { pipe in
                if pipe == nil { pipe = SignalPipe() }
                return pipe != nil
            }
        }

        private static let current = Mutex<SignalPipe?>(nil)

        private let reader: any DispatchSourceRead

        private init?() {
            guard let (readEnd, writeEnd) = makePipe() else { return nil }
            pipeWriteEnd.store(writeEnd, ordering: .releasing)

            reader = DispatchSource.makeReadSource(
                fileDescriptor: readEnd,
                queue: DispatchQueue(label: "ProcessSignals")
            )
            // A byte written before the source is registered waits in the pipe, and the source
            // fires once it is: no registration wait.
            reader.setEventHandler { drain(readEnd) }
            reader.resume()
        }
    }

    /// Reads every pending signal byte and delivers it.
    ///
    /// A signal no stream takes is sent to the process again: the streams holding it have ended,
    /// but not yet released it. It comes back here until a stream subscribed since takes it, or
    /// the last release restores the previous disposition, which then has it. Releases run as
    /// streams end, so it comes back a few times at most. With `kill`, to the whole process: the
    /// Dispatch threads this runs on block it.
    private func drain(_ readEnd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let count = read(readEnd, &buffer, buffer.count)
            guard count > 0 else { return }
            for byte in buffer.prefix(count) where !routes.deliver(Int32(byte)) {
                kill(getpid(), Int32(byte))
            }
        }
    }

    /// A pipe whose ends are both close-on-exec and non-blocking: the handler must never block on
    /// a full pipe, and the reader drains until it is empty. (`pipe` plus `fcntl`, because glibc
    /// only declares `pipe2` under `_GNU_SOURCE`, which Swift's Glibc module does not define.)
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
            previous.dropInvalidRestorer()
            return Disposition(signal: signal, action: previous)
        }

        func restore() {
            var action = action
            sigaction(signal, &action, nil)
        }
    }

    extension sigaction {
        /// Clears `sa_restorer` if it holds a value no pointer can have. Where the C library
        /// doesn't use the field (glibc on aarch64), the action `sigaction` returns can hold
        /// whatever was on the library's stack there. Swift keeps an optional's nil in the values
        /// below 4096 that no pointer has, so a `sigaction` holding one there, or any value
        /// containing it, can read as nil inside an optional: the subscriber table lost entries
        /// (MM-50). Where the field is used, it holds the C library's own function, which this
        /// keeps.
        package mutating func dropInvalidRestorer() {
            guard let offset = MemoryLayout<sigaction>.offset(of: \.sa_restorer) else { return }
            withUnsafeMutableBytes(of: &self) { bytes in
                // Read as an integer: as a function pointer, the value would already be invalid.
                if bytes.load(fromByteOffset: offset, as: UInt.self) < 4096 {
                    bytes.storeBytes(of: 0, toByteOffset: offset, as: UInt.self)
                }
            }
        }
    }
#endif
