#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Dispatch
import FPBracket
import FPService

/// The process the subprocess tests end: a service only stage 3 can stop.
/// `serve` ignores the graceful request and dispose never returns, so it
/// takes a third signal. Prints each event, and `disposing`, a line at a
/// time for the test to read.
///
/// With `stall`, a stdio stream is stuck writing to a pipe nobody reads, as
/// when the process's output stalls: flushing every stream waits on it.
///
/// Usage: `ServiceFixture <signal number> [stall]`
@main
enum ServiceFixture {
    static func main() async {
        let arguments = CommandLine.arguments
        guard let signal = arguments.dropFirst().first.flatMap({ Int32($0) }),
            arguments.count == 2 || (arguments.count == 3 && arguments[2] == "stall")
        else {
            printLine("usage: ServiceFixture <signal number> [stall]")
            exit(2)
        }
        if arguments.count == 3 { stallOutput() }
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

/// Writes `line` to standard output at once, past stdio's buffer: the test
/// reading the pipe sees it before the process ends, and a stalled stdio
/// stream never holds it back. (Not `print`, then `fflush`: glibc declares
/// `stdout` a mutable global, which Swift 6 rejects, and `fflush(nil)`
/// would wait on the stalled stream.)
func printLine(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
}
