#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import ProcessSignals
import Testing

/// These send real signals to the test process. They use SIGWINCH and
/// SIGURG, whose default action is to ignore, so a failure can never kill the
/// test run. They change process-wide dispositions, so they run one at a time.
///
/// Signals are sent with `kill(getpid(), …)`, to the whole process, like a
/// real `kill` or Ctrl-C. (`raise` targets only the calling thread.)
@Suite("processSignals", .serialized, .timeLimit(.minutes(1)))
struct ProcessSignalsTests {
    @Test("delivers each signal")
    func delivers() async throws {
        let stream = await processSignals([SIGWINCH, SIGURG])
        send(SIGWINCH)
        send(SIGURG)
        #expect(try await collect(2, from: stream).sorted() == [SIGWINCH, SIGURG].sorted())
    }

    #if canImport(Darwin)
        // Darwin's kqueue counts every send. With a signal handler (Linux),
        // the kernel keeps only one pending instance of a standard signal, so
        // copies sent in the same instant can merge: this holds on Darwin only.
        @Test("signals sent back to back stay separate elements")
        func coalesced() async throws {
            let stream = await processSignals([SIGWINCH])
            send(SIGWINCH)
            send(SIGWINCH)
            send(SIGWINCH)
            #expect(try await collect(3, from: stream) == [SIGWINCH, SIGWINCH, SIGWINCH])
        }
    #endif

    @Test("a signal listed twice is delivered once per send")
    func duplicates() async throws {
        let stream = await processSignals([SIGURG, SIGURG])
        var signals = stream.makeAsyncIterator()
        send(SIGURG)
        #expect(await signals.next() == SIGURG)
        send(SIGWINCH)  // not taken over: default action (ignore), not delivered
        send(SIGURG)
        #expect(await signals.next() == SIGURG)
    }

    @Test("an empty list gives a finished stream")
    func empty() async throws {
        let stream = await processSignals([])
        #expect(try await collect(1, from: stream) == [])
    }

    @Test("ending the stream restores the disposition")
    func restores() async throws {
        let original = disposition(SIGURG)
        // The consumer reports `installed` through a stream: its continuation
        // is Sendable, so the child task captures nothing non-copyable.
        let (installed, report) = AsyncStream<Void>.makeStream()
        let during = try await deadline {
            await withTaskGroup(of: UInt?.self) { group in
                group.addTask {
                    let stream = await processSignals([SIGURG])
                    let during = disposition(SIGURG)
                    report.yield()
                    for await _ in stream {}  // ends only when cancelled
                    return during
                }
                // The stream does not end on its own, so cancelling is the test.
                for await _ in installed { break }
                group.cancelAll()
                return await group.next().flatMap { $0 }
            }
        }
        #expect(during != original)  // taken over while the stream ran
        #if canImport(Darwin)
            #expect(during == handlerBits(SIG_IGN))  // kqueue reads it; Linux uses a handler
        #endif
        #expect(disposition(SIGURG) == original)
    }
}

/// Sends `signal` to this process.
func send(_ signal: Int32) {
    kill(getpid(), signal)
}

struct DeadlineExceeded: Error {}

/// The first `count` elements (fewer if the stream ends), or a failure
/// instead of a hang if they never arrive.
func collect(
    _ count: Int,
    from stream: AsyncStream<Int32>,
    within limit: Duration = .seconds(5)
) async throws -> [Int32] {
    try await withThrowingTaskGroup(of: [Int32]?.self) { group in
        group.addTask {
            var collected: [Int32] = []
            for await signal in stream {
                collected.append(signal)
                if collected.count == count { break }
            }
            return collected
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let collected = first else {
            throw DeadlineExceeded()
        }
        return collected
    }
}

/// Fails instead of hanging if `operation` never returns.
func deadline<T: Sendable>(
    _ limit: Duration = .seconds(5),
    _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else {
            throw DeadlineExceeded()
        }
        return value
    }
}

private func disposition(_ signal: Int32) -> UInt {
    var current = sigaction()
    sigaction(signal, nil, &current)
    #if canImport(Darwin)
        return handlerBits(current.__sigaction_u.__sa_handler)
    #else
        return handlerBits(current.__sigaction_handler.sa_handler)
    #endif
}

private func handlerBits(_ handler: (@convention(c) (Int32) -> Void)?) -> UInt {
    unsafeBitCast(handler, to: UInt.self)
}

@Suite("signalName")
struct SignalNameTests {
    @Test("names the common signals by the platform's own constants")
    func names() {
        #expect(signalName(SIGTERM) == "SIGTERM")
        #expect(signalName(SIGINT) == "SIGINT")
        #expect(signalName(SIGHUP) == "SIGHUP")
        #expect(signalName(SIGUSR1) == "SIGUSR1")
        #expect(signalName(SIGWINCH) == "SIGWINCH")
    }

    @Test("falls back to the number for an unknown signal")
    func unknown() {
        #expect(signalName(1234) == "signal 1234")
    }
}
