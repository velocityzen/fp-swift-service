#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#elseif canImport(CRT)
    import CRT
#endif
import Dispatch
import FPBracket
import FPService
import ProcessSignals

#if os(Windows)
    import WinSDK
#endif

/// The process the subprocess tests end: a service only stage 3 can stop.
/// `serve` ignores the graceful request and dispose never returns, so it
/// takes a third signal. Prints each event, and `disposing`, a line at a
/// time for the test to read.
///
/// On macOS, Linux and Android, two more modes. With `stall`, a stdio stream
/// is stuck writing to a pipe nobody reads, as when the process's output
/// stalls: flushing every stream waits on it. With `nofile`, it instead runs
/// a service with no file descriptor left, then another with them back, and
/// prints how each ended: on Linux and Android the signals need a pipe, made
/// once per process, so this takes a process of its own.
///
/// Usage: `ServiceFixture <signal number> [stall]`, or `ServiceFixture nofile`
@main
enum ServiceFixture {
    static func main() async {
        let arguments = CommandLine.arguments
        #if !os(Windows)
            if arguments.dropFirst() == ["nofile"] {
                await runOutOfFileDescriptors()
                return
            }
        #endif
        guard let signal = arguments.dropFirst().first.flatMap({ Int32($0) }),
            arguments.count == 2 || (arguments.count == 3 && arguments[2] == "stall")
        else {
            printLine("usage: ServiceFixture <signal number> [stall] | nofile")
            exit(2)
        }
        #if !os(Windows)
            if arguments.count == 3 { stallOutput() }
        #endif
        await runUntilEnded(signal)
        printLine("returned")  // never: stage 3 ends the process first
    }
}

/// Top-level, so not on the main actor: `Service` takes its closures as
/// `sending`.
func runUntilEnded(_ signal: Int32) async {
    let withService = Service(stuck(), shutdownSignals: [signal]) { events in
        for await case .success(let event) in events { printLine("\(event)") }
    }
    _ = await withService { _, _ in
        try? await Task.sleep(for: .seconds(3600))  // returns when cancelled
        return .success(())
    }
}

/// A service whose dispose never returns, even when cancelled.
func stuck() -> BracketAsync<Void, Never> {
    BracketAsync(
        acquire: { .success(()) },
        dispose: { _ in
            printLine("disposing")
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return .success(())
        }
    )
}

#if !os(Windows)
    /// Runs a service with no file descriptor left, then one with them back.
    /// Prints `first:` and `second:`, each run's result, and `SIGTERM:`, whether
    /// the failed run left the signal's disposition alone.
    func runOutOfFileDescriptors() async {
        // Dispatch makes its event loop's descriptors on first use: let it,
        // while there are some.
        try? await Task.sleep(for: .milliseconds(1))

        let original = useUpFileDescriptors()
        printLine("first: \(await runIdle())")
        printLine("SIGTERM: \(currentHandler(SIGTERM) == nil ? "default" : "changed")")

        var limit = original
        setrlimit(fileDescriptorLimit, &limit)
        printLine("second: \(await runIdle())")
    }

    /// Lowers the soft limit on file descriptors to the lowest free one, so no
    /// new one can be made; returns the limits from before.
    func useUpFileDescriptors() -> rlimit {
        var original = rlimit()
        let lowest = dup(STDOUT_FILENO)  // a copy takes the lowest free descriptor
        guard getrlimit(fileDescriptorLimit, &original) == 0, lowest >= 0 else {
            printLine("nofile: no limit to lower")
            exit(2)
        }
        close(lowest)
        var limit = original
        limit.rlim_cur = rlim_t(lowest)
        guard setrlimit(fileDescriptorLimit, &limit) == 0 else {
            printLine("nofile: the limit can't be lowered")
            exit(2)
        }
        return original
    }

    #if canImport(Glibc)
        /// glibc declares the resources as an enum, and takes them as `Int32`.
        private let fileDescriptorLimit = Int32(RLIMIT_NOFILE.rawValue)
    #else
        private let fileDescriptorLimit = RLIMIT_NOFILE
    #endif

    /// Runs a service that starts and stops at once, shut down by SIGTERM;
    /// returns `ran`, or why it failed.
    func runIdle() async -> String {
        let withService = Service(
            BracketAsync<Void, Never>(acquire: { .success(()) }, dispose: { _ in .success(()) }),
            shutdownSignals: [SIGTERM]
        )
        switch await withService({ _, _ in .success(()) }) {
            case .success: return "ran"
            case .failure(let error): return "\(error)"
        }
    }

    /// Leaves a stdio stream stuck in a flush to a pipe nobody reads, holding
    /// the stream's lock: `fflush(nil)` waits on it forever.
    func stallOutput() {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            printLine("stall: no pipe")
            exit(2)
        }
        // The read end stays open and unread, so the writes block, not fail.
        let writeEnd = ends[1]
        DispatchQueue(label: "ServiceFixture.stall").async {
            guard let stream = fdopen(writeEnd, "w") else { return }
            let chunk = String(repeating: "x", count: 4096)
            while true {
                fputs(chunk, stream)
                fflush(stream)
            }
        }
    }
#endif

/// Writes `line` to standard output at once, past stdio's buffer: the test
/// reading the pipe sees it before the process ends, and a stalled stdio
/// stream never holds it back. (Not `print`, then `fflush`: glibc declares
/// `stdout` a mutable global, which Swift 6 rejects, and `fflush(nil)`
/// would wait on the stalled stream.)
func printLine(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    #if os(Windows)
        var written: DWORD = 0
        _ = bytes.withUnsafeBytes {
            WriteFile(
                GetStdHandle(STD_OUTPUT_HANDLE),
                $0.baseAddress,
                DWORD($0.count),
                &written,
                nil
            )
        }
    #else
        _ = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    #endif
}
