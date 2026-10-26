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
        setvbuf(stdout, nil, _IOLBF, 0)
        guard CommandLine.arguments.count == 2, let signal = Int32(CommandLine.arguments[1]) else {
            print("usage: ServiceFixture <signal number>")
            exit(2)
        }
        await runUntilEnded(signal)
        print("returned")  // never: stage 3 ends the process first
    }
}

/// Top-level, so not on the main actor: `Service` takes its closures as
/// `sending`.
func runUntilEnded(_ signal: Int32) async {
    let withService = Service(stuck(), shutdownSignals: [signal]) { events in
        for await case .success(let event) in events { print(event) }
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
            print("disposing")
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return .success(())
        }
    )
}
