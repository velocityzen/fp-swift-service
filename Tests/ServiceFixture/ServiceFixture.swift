#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import FPBracket
import FPService

/// The process the subprocess tests end: a service only stage 3 can stop.
/// `serve` ignores the graceful request and dispose never returns, so it
/// takes a third signal. Prints each event, and `disposing`, a line at a
/// time for the test to read.
///
/// Usage: `ServiceFixture <signal number>`
@main
enum ServiceFixture {
    static func main() async {
        guard CommandLine.arguments.count == 2, let signal = Int32(CommandLine.arguments[1]) else {
            printFlushed("usage: ServiceFixture <signal number>")
            exit(2)
        }
        await runUntilEnded(signal)
        printFlushed("returned")  // never: stage 3 ends the process first
    }
}

/// Top-level, so not on the main actor: `Service` takes its closures as
/// `sending`.
func runUntilEnded(_ signal: Int32) async {
    let withService = Service(stuck(), shutdownSignals: [signal]) { events in
        for await case .success(let event) in events { printFlushed("\(event)") }
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
            printFlushed("disposing")
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return .success(())
        }
    )
}

/// Prints `line` and flushes it at once, so the test reading the pipe sees it
/// before the process ends. (`fflush(nil)` rather than line-buffering
/// `stdout`: glibc declares `stdout` a mutable global, which Swift 6 rejects.)
func printFlushed(_ line: String) {
    print(line)
    fflush(nil)
}
