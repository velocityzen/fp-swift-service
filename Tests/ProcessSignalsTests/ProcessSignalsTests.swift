#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import ProcessSignals
import ServiceTestSupport
import Testing

/// These send real signals to the test process. They use SIGWINCH, SIGURG
/// and SIGCHLD, whose default action is to ignore, so a failure can never
/// kill the test run. They change process-wide dispositions, so they run one
/// at a time.
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
        // Darwin's kqueue counts every send. Linux reads them from its
        // signal handler, and the kernel keeps only one pending instance of a
        // standard signal, so copies sent in the same instant can merge: this
        // holds on Darwin only.
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
        send(SIGWINCH)  // not subscribed to: default action (ignore), not delivered
        send(SIGURG)
        #expect(await signals.next() == SIGURG)
    }

    @Test("an empty list gives a finished stream")
    func empty() async throws {
        let stream = await processSignals([])
        #expect(try await collect(1, from: stream) == [])
    }

    @Test("signals that can't be subscribed to are left out")
    func cannotSubscribe() async throws {
        let none = await processSignals([0, -1, 1234, SIGKILL, SIGSTOP])
        #expect(try await collect(1, from: none) == [])

        let stream = await processSignals([1234, SIGURG, SIGKILL])
        send(SIGURG)
        #expect(try await collect(1, from: stream) == [SIGURG])
    }

    @Test("ending the stream restores the disposition")
    func restores() async throws {
        let original = disposition(SIGURG)
        // The consumer reports `installed` through a stream: its continuation
        // is Sendable, so the child task captures nothing non-copyable.
        let (installed, report) = AsyncStream<Void>.makeStream()
        let during = try await withDeadline {
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
        #expect(during != original)  // subscribed to while the stream ran
        #expect(during != bits(SIG_IGN))  // caught, so `exec` resets it in a child
        #expect(disposition(SIGURG) == original)
    }

    @Test("SIGCHLD is delivered, and the child can still be waited for")
    func childExited() async throws {
        let stream = await processSignals([SIGCHLD])
        let child = try #require(spawnExitingChild())
        // Another child of this process may end first; any SIGCHLD will do.
        #expect(try await collect(1, from: stream) == [SIGCHLD])
        var status: Int32 = 0
        #expect(waitpid(child, &status, 0) == child)  // not reaped behind our back
    }

    @Test("streams can share a signal: each gets it, and the last to end restores it")
    func shared() async throws {
        let original = disposition(SIGURG)
        let (reports, report) = AsyncStream<String>.makeStream()
        try await withDeadline {
            var reports = reports.makeAsyncIterator()
            let first = Task { await listen("first", report) }
            #expect(await reports.next() == "first ready")
            let second = Task { await listen("second", report) }
            #expect(await reports.next() == "second ready")

            send(SIGURG)
            let both = [await reports.next(), await reports.next()].compactMap { $0 }
            #expect(both.sorted() == ["first got", "second got"])

            first.cancel()
            await first.value
            #expect(disposition(SIGURG) != original)  // the second still holds it
            send(SIGURG)
            #expect(await reports.next() == "second got")

            second.cancel()
            await second.value
        }
        #expect(disposition(SIGURG) == original)
    }
}

/// Subscribes to SIGURG and reports `"<name> ready"`, then `"<name> got"` for
/// each delivery, until cancelled.
private func listen(_ name: String, _ report: AsyncStream<String>.Continuation) async {
    let stream = await processSignals([SIGURG])
    report.yield("\(name) ready")
    for await _ in stream { report.yield("\(name) got") }
}

/// Starts a child process that exits at once; returns its pid.
private func spawnExitingChild() -> pid_t? {
    let arguments = ["/bin/sh", "-c", "exit 0"]
    let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    guard posix_spawn(&pid, "/bin/sh", nil, nil, argv, environment) == 0 else { return nil }
    return pid
}

/// Sends `signal` to this process.
func send(_ signal: Int32) {
    kill(getpid(), signal)
}

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
