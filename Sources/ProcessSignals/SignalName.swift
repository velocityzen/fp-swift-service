#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
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
    switch signal {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGABRT: "SIGABRT"
        case SIGFPE: "SIGFPE"
        case SIGKILL: "SIGKILL"
        case SIGBUS: "SIGBUS"
        case SIGSEGV: "SIGSEGV"
        case SIGSYS: "SIGSYS"
        case SIGPIPE: "SIGPIPE"
        case SIGALRM: "SIGALRM"
        case SIGTERM: "SIGTERM"
        case SIGURG: "SIGURG"
        case SIGSTOP: "SIGSTOP"
        case SIGTSTP: "SIGTSTP"
        case SIGCONT: "SIGCONT"
        case SIGCHLD: "SIGCHLD"
        case SIGTTIN: "SIGTTIN"
        case SIGTTOU: "SIGTTOU"
        case SIGIO: "SIGIO"
        case SIGXCPU: "SIGXCPU"
        case SIGXFSZ: "SIGXFSZ"
        case SIGVTALRM: "SIGVTALRM"
        case SIGPROF: "SIGPROF"
        case SIGWINCH: "SIGWINCH"
        case SIGUSR1: "SIGUSR1"
        case SIGUSR2: "SIGUSR2"
        default: platformSignalName(signal) ?? "signal \(signal)"
    }
}

/// Signals only one platform has.
private func platformSignalName(_ signal: Int32) -> String? {
    #if canImport(Darwin)
    switch signal {
        case SIGINFO: "SIGINFO"
        case SIGEMT: "SIGEMT"
        default: nil
    }
    #else
    switch signal {
        case SIGPWR: "SIGPWR"
        case SIGSTKFLT: "SIGSTKFLT"
        default: nil
    }
    #endif
}
