#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(CRT)
    import CRT
#endif

/// The conventional name of a signal, e.g. `"SIGTERM"`; `"signal N"` for a
/// number it doesn't know.
///
/// ```swift
/// signalName(SIGTERM)   // "SIGTERM"
/// signalName(1234)      // "signal 1234"
/// ```
///
/// Matched against the platform's own constants, because the numbers differ
/// between platforms (`SIGUSR1` is 30 on Darwin and 10 on Linux). What each
/// signal means is in <doc:SignalReference>.
public func signalName(_ signal: Int32) -> String {
    signalNames.first { $0.signal == signal }?.name ?? "signal \(signal)"
}

#if os(Windows)
    /// Every signal ``signalName(_:)`` knows: the ones Windows's C library has.
    private let signalNames: [(signal: Int32, name: String)] = [
        (SIGINT, "SIGINT"),
        (SIGILL, "SIGILL"),
        (SIGFPE, "SIGFPE"),
        (SIGSEGV, "SIGSEGV"),
        (SIGTERM, "SIGTERM"),
        (SIGBREAK, "SIGBREAK"),
        (SIGABRT, "SIGABRT"),
    ]
#else
    /// Every signal ``signalName(_:)`` knows, against this platform's constants.
    private let signalNames: [(signal: Int32, name: String)] =
        [
            (SIGHUP, "SIGHUP"),
            (SIGINT, "SIGINT"),
            (SIGQUIT, "SIGQUIT"),
            (SIGILL, "SIGILL"),
            (SIGTRAP, "SIGTRAP"),
            (SIGABRT, "SIGABRT"),
            (SIGFPE, "SIGFPE"),
            (SIGKILL, "SIGKILL"),
            (SIGBUS, "SIGBUS"),
            (SIGSEGV, "SIGSEGV"),
            (SIGSYS, "SIGSYS"),
            (SIGPIPE, "SIGPIPE"),
            (SIGALRM, "SIGALRM"),
            (SIGTERM, "SIGTERM"),
            (SIGURG, "SIGURG"),
            (SIGSTOP, "SIGSTOP"),
            (SIGTSTP, "SIGTSTP"),
            (SIGCONT, "SIGCONT"),
            (SIGCHLD, "SIGCHLD"),
            (SIGTTIN, "SIGTTIN"),
            (SIGTTOU, "SIGTTOU"),
            (SIGIO, "SIGIO"),
            (SIGXCPU, "SIGXCPU"),
            (SIGXFSZ, "SIGXFSZ"),
            (SIGVTALRM, "SIGVTALRM"),
            (SIGPROF, "SIGPROF"),
            (SIGWINCH, "SIGWINCH"),
            (SIGUSR1, "SIGUSR1"),
            (SIGUSR2, "SIGUSR2"),
        ] + platformSignalNames

    #if canImport(Darwin)
        /// Signals only Darwin has.
        private let platformSignalNames: [(signal: Int32, name: String)] = [
            (SIGINFO, "SIGINFO"), (SIGEMT, "SIGEMT"),
        ]
    #else
        /// Signals only Linux has.
        private let platformSignalNames: [(signal: Int32, name: String)] = [
            (SIGPWR, "SIGPWR"), (SIGSTKFLT, "SIGSTKFLT"),
        ]
    #endif
#endif
