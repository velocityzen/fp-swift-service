#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

// Every place in the package that reads or sets a signal handler goes through
// here, so the C libraries' different names for the field are spelled once.

extension sigaction {
    /// The signal handler: `SIG_DFL`, `SIG_IGN` or a function. Darwin, glibc
    /// and musl each name the field differently.
    package var handler: (@convention(c) (Int32) -> Void)? {
        get {
            #if canImport(Darwin)
                return __sigaction_u.__sa_handler
            #elseif canImport(Musl)
                return __sa_handler.sa_handler
            #else
                return __sigaction_handler.sa_handler
            #endif
        }
        set {
            #if canImport(Darwin)
                __sigaction_u.__sa_handler = newValue
            #elseif canImport(Musl)
                __sa_handler.sa_handler = newValue
            #else
                __sigaction_handler.sa_handler = newValue
            #endif
        }
    }
}

/// The handler `signal` has now: `SIG_DFL`, `SIG_IGN` or a function.
package func currentHandler(_ signal: Int32) -> (@convention(c) (Int32) -> Void)? {
    var current = sigaction()
    sigaction(signal, nil, &current)
    return current.handler
}

/// Ends the process the way `signal` ends it: restores the signal's default
/// action and re-sends it. A signal whose default action leaves the process
/// running (it ignores, stops or continues it) ends it with exit status 128 +
/// the signal instead, the shell's convention.
///
/// Standard output and error are flushed first: neither way of ending runs
/// the process's exit handlers. The signal is sent with `kill`, to the whole
/// process: `raise` targets only the calling thread, and the Dispatch worker
/// threads this runs on block asynchronous signals.
package func endProcess(as signal: Int32) {
    fflush(nil)
    guard !survivableSignals.contains(signal) else { _exit(128 + signal) }
    var action = sigaction()
    action.handler = SIG_DFL
    sigaction(signal, &action, nil)
    kill(getpid(), signal)
}

/// Signals whose default action leaves the process running: ignore, stop or
/// continue (see <doc:SignalReference>).
private let survivableSignals: [Int32] =
    [SIGCHLD, SIGCONT, SIGURG, SIGWINCH, SIGTSTP, SIGTTIN, SIGTTOU] + platformSurvivableSignals

#if canImport(Darwin)
    private let platformSurvivableSignals: [Int32] = [SIGINFO, SIGIO]
#else
    private let platformSurvivableSignals: [Int32] = []
#endif
