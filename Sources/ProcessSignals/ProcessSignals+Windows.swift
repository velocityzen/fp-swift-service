#if os(Windows)
    import CRT
    import Synchronization
    import WinSDK

    // Windows has no signals to catch. Ctrl-C, Ctrl-Break, and the console
    // closing, the user logging off or the system shutting down reach a
    // console process as control events: the handler routine installed with
    // `SetConsoleCtrlHandler` receives each on a thread the system starts for
    // it, and delivers it as SIGINT, SIGBREAK or SIGTERM.
    //
    // The handler routine is installed on first use and never removed. For
    // an event no stream is subscribed to, it reports the event unhandled, so
    // the next handler, and in the end Windows's default (ending the
    // process), takes it, just as if it were not installed.

    /// Subscribes to each signal, routing it to `continuation`.
    func subscribe(
        _ signals: [Int32],
        delivering continuation: AsyncStream<Int32>.Continuation
    ) async -> Subscription {
        // Route first, so an event that arrives right after the signal is
        // caught already has somewhere to go.
        let route = routes.withLock { routes in
            routes.lastID += 1
            routes.byID[routes.lastID] = Route(signals: signals, continuation: continuation)
            return routes.lastID
        }
        signals.forEach(addSubscriber(to:))
        return Subscription(signals: signals, route: route)
    }

    /// What one stream subscribed to, released when it ends.
    struct Subscription: Sendable {
        let signals: [Int32]
        fileprivate let route: UInt64

        func release() {
            signals.forEach(removeSubscriber(from:))
            _ = routes.withLock { $0.byID.removeValue(forKey: route) }
        }
    }

    /// Whether `signal` can be subscribed to: only the three that console
    /// control events are delivered as.
    func canRegisterSignal(_ signal: Int32) -> Bool {
        [SIGINT, SIGBREAK, SIGTERM].contains(signal)
    }

    /// A signal's disposition from before its first subscriber. Windows keeps
    /// none per signal: subscribing makes the handler routine catch the
    /// signal's event, and restoring lets the event pass on again.
    struct Disposition: Sendable {
        let signal: Int32

        static func create(_ signal: Int32) -> Disposition {
            _ = installHandlerRoutine
            caught.withLock { _ = $0.insert(signal) }
            return Disposition(signal: signal)
        }

        func restore() {
            caught.withLock { _ = $0.remove(signal) }
        }
    }

    /// Whether some stream is subscribed to `signal`, so its event is caught.
    /// For tests, as `currentHandler(_:)` is elsewhere.
    package func catches(_ signal: Int32) -> Bool {
        caught.withLock { $0.contains(signal) }
    }

    /// Delivers a console control event as its signal to every stream
    /// subscribed to it, and returns whether there was one: whether the event
    /// is handled. `package` so tests can hand it events without a console.
    ///
    /// Windows ends the process once a close, logoff or shutdown event has
    /// been handled, so for those this returns only once no stream is
    /// subscribed to SIGTERM any more: once the run holding it has stopped.
    /// Any SIGTERM stream holds it, so one that never ends holds the event
    /// until Windows ends the process anyway (seconds later).
    package func receiveConsoleEvent(_ event: UInt32) -> Bool {
        guard let signal = signal(for: event), catches(signal) else {
            return false
        }

        routes.withLock { routes in
            for route in routes.byID.values where route.signals.contains(signal) {
                route.continuation.yield(signal)
            }
        }
        if signal == SIGTERM {
            while catches(SIGTERM) { Sleep(10) }
        }
        return true
    }

    /// The signal a console control event is delivered as.
    private func signal(for event: UInt32) -> Int32? {
        switch event {
            case UInt32(CTRL_C_EVENT): SIGINT
            case UInt32(CTRL_BREAK_EVENT): SIGBREAK
            case UInt32(CTRL_CLOSE_EVENT), UInt32(CTRL_LOGOFF_EVENT), UInt32(CTRL_SHUTDOWN_EVENT):
                SIGTERM
            default: nil
        }
    }

    /// Ends the process the way Ctrl-C ends it: with exit code
    /// STATUS_CONTROL_C_EXIT, whatever the signal. `TerminateProcess` runs no
    /// exit handlers, so output is flushed first, for half a second at most:
    /// a stream stuck on a reader that stopped reading would hold the flush,
    /// and the end, forever.
    package func endProcess(as _: Int32) {
        flushOutput(within: .milliseconds(500))
        TerminateProcess(GetCurrentProcess(), statusControlCExit)
    }

    /// The exit code of a process Ctrl-C ended.
    private let statusControlCExit: UInt32 = 0xC000_013A

    /// Installs the handler routine, once, on the first subscription: Windows
    /// calls it for each console control event. (`true` and `false`, so it
    /// is the C `BOOL` whichever Swift type that is imported as.)
    private let installHandlerRoutine: Void = {
        _ = SetConsoleCtrlHandler({ event in receiveConsoleEvent(event) ? true : false }, true)
    }()

    /// The signals some stream is subscribed to.
    private let caught = Mutex<Set<Int32>>([])

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
#endif
