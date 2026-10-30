// POSIX only: Windows has no `sigaction` (see ProcessSignals+Windows.swift).
#if !os(Windows)
    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #elseif canImport(Musl)
        import Musl
    #elseif canImport(Android)
        import Android
    #endif

    // Every place in the package that reads or sets a signal handler goes through
    // here, so the C libraries' different names for the field are spelled once.

    extension sigaction {
        /// The signal handler: `SIG_DFL`, `SIG_IGN` or a function. Darwin, glibc,
        /// musl and Bionic (Android) each name the field differently.
        package var handler: (@convention(c) (Int32) -> Void)? {
            get {
                #if canImport(Darwin)
                    return __sigaction_u.__sa_handler
                #elseif canImport(Musl)
                    return __sa_handler.sa_handler
                #elseif canImport(Android)
                    return sa_handler
                #else
                    return __sigaction_handler.sa_handler
                #endif
            }
            set {
                #if canImport(Darwin)
                    __sigaction_u.__sa_handler = newValue
                #elseif canImport(Musl)
                    __sa_handler.sa_handler = newValue
                #elseif canImport(Android)
                    sa_handler = newValue
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
    /// Neither way runs the process's exit handlers, so output is flushed first,
    /// for half a second at most: a stream stuck on a reader that stopped
    /// reading would hold the flush, and the end, forever. The default action is
    /// restored before that, so another signal meanwhile ends the process at
    /// once.
    ///
    /// The signal is sent with `kill`, to the whole process: `raise` targets
    /// only the calling thread. The Dispatch worker threads this runs on block
    /// asynchronous signals, so it is unblocked here first, and some thread can
    /// always take it. Should the process still run a second later (something
    /// caught the signal again), it exits with 128 + the signal after all.
    package func endProcess(as signal: Int32) {
        let survivable = survivableSignals.contains(signal)
        if !survivable {
            var action = sigaction()
            action.handler = SIG_DFL
            sigaction(signal, &action, nil)
        }
        flushOutput(within: .milliseconds(500))
        guard !survivable else { _exit(128 + signal) }

        var unblock = sigset_t()
        sigemptyset(&unblock)
        sigaddset(&unblock, signal)
        pthread_sigmask(SIG_UNBLOCK, &unblock, nil)
        kill(getpid(), signal)
        sleep(1)
        _exit(128 + signal)
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
#endif
