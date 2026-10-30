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
import ProcessSignals
import ServiceTestSupport
import Testing

#if os(Windows)
    import WinSDK
#endif

/// These send real signals to the test process: `testSignal` and
/// `otherSignal`, and SIGCHLD. On macOS, Linux and Android those are SIGURG,
/// SIGWINCH and SIGCHLD, whose default action is to ignore, so a failure can
/// never kill the test run; on Windows, SIGBREAK and SIGINT (see
/// `send(_:)`). They change process-wide dispositions, so they run one at a
/// time.
@Suite("processSignals", .serialized, .timeLimit(.minutes(1)))
struct ProcessSignalsTests {
    @Test("delivers each signal")
    func delivers() async throws {
        let stream = await processSignals([otherSignal, testSignal])
        send(otherSignal)
        send(testSignal)
        #expect(try await collect(2, from: stream).sorted() == [otherSignal, testSignal].sorted())
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
        let stream = await processSignals([testSignal, testSignal])
        var signals = stream.makeAsyncIterator()
        send(testSignal)
        #expect(await signals.next() == testSignal)
        send(otherSignal)  // not subscribed to: not delivered
        send(testSignal)
        #expect(await signals.next() == testSignal)
    }

    @Test("an empty list gives a finished stream")
    func empty() async throws {
        let stream = await processSignals([])
        #expect(try await collect(1, from: stream) == [])
    }

    @Test("signals that can't be subscribed to are left out")
    func cannotSubscribe() async throws {
        // 32 is past Darwin's last signal, and on Linux and Android the first
        // one the C library keeps for itself.
        let none = await processSignals([0, -1, 32, 1234] + uncatchable)
        #expect(try await collect(1, from: none) == [])

        let stream = await processSignals([1234, testSignal] + uncatchable)
        send(testSignal)
        #expect(try await collect(1, from: stream) == [testSignal])
    }

    @Test("ending the stream restores the disposition")
    func restores() async throws {
        let original = disposition(testSignal)
        // The consumer reports `installed` through a stream: its continuation
        // is Sendable, so the child task captures nothing non-copyable.
        let (installed, report) = AsyncStream<Void>.makeStream()
        let during = try await withDeadline {
            await withTaskGroup(of: UInt?.self) { group in
                group.addTask {
                    let stream = await processSignals([testSignal])
                    let during = disposition(testSignal)
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
        #if !os(Windows)
            #expect(during != bits(SIG_IGN))  // caught, so `exec` resets it in a child
        #endif
        #expect(disposition(testSignal) == original)
    }

    #if os(macOS) || os(Linux) || os(Android)  // the others can't spawn a child
        @Test("SIGCHLD is delivered, and the child can still be waited for")
        func childExited() async throws {
            let stream = await processSignals([SIGCHLD])
            let child = try #require(spawnExitingChild())
            // Another child of this process may end first; any SIGCHLD will do.
            #expect(try await collect(1, from: stream) == [SIGCHLD])
            var status: Int32 = 0
            #expect(waitpid(child, &status, 0) == child)  // not reaped behind our back
        }
    #endif

    @Test("streams can share a signal: each gets it, and the last to end restores it")
    func shared() async throws {
        let original = disposition(testSignal)
        let (reports, report) = AsyncStream<String>.makeStream()
        try await withDeadline {
            var reports = reports.makeAsyncIterator()
            let first = Task { await listen("first", report) }
            #expect(await reports.next() == "first ready")
            let second = Task { await listen("second", report) }
            #expect(await reports.next() == "second ready")

            send(testSignal)
            let both = [await reports.next(), await reports.next()].compactMap { $0 }
            #expect(both.sorted() == ["first got", "second got"])

            first.cancel()
            await first.value
            #expect(disposition(testSignal) != original)  // the second still holds it
            send(testSignal)
            #expect(await reports.next() == "second got")

            second.cancel()
            await second.value
        }
        #expect(disposition(testSignal) == original)
    }
}

/// Subscribes to `testSignal` and reports `"<name> ready"`, then
/// `"<name> got"` for each delivery, until cancelled.
private func listen(_ name: String, _ report: AsyncStream<String>.Continuation) async {
    let stream = await processSignals([testSignal])
    report.yield("\(name) ready")
    for await _ in stream { report.yield("\(name) got") }
}

#if os(macOS) || os(Linux) || os(Android)
    /// Starts a child process that exits at once; returns its pid.
    private func spawnExitingChild() -> pid_t? {
        let arguments = [shell, "-c", "exit 0"]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, shell, nil, nil, argv, environment) == 0 else { return nil }
        return pid
    }

    #if os(Android)
        private let shell = "/system/bin/sh"
    #else
        private let shell = "/bin/sh"
    #endif
#endif

#if os(Windows)
    /// The signals these tests send.
    let testSignal = SIGBREAK
    let otherSignal = SIGINT
    /// Signals of the C library that no console event is delivered as.
    let uncatchable = [SIGSEGV, SIGABRT]
#else
    /// The signals these tests send: their default action is to ignore.
    let testSignal = SIGURG
    let otherSignal = SIGWINCH
    /// Signals that can never be caught.
    let uncatchable = [SIGKILL, SIGSTOP]
#endif

/// Sends `signal` to this process. With `kill(getpid(), …)`, to the whole
/// process, like a real `kill` or Ctrl-C (`raise` targets only the calling
/// thread). Windows can't send a console event to one process alone, it
/// reaches every process on the console, so there the event `signal` is
/// delivered as goes to the handler routine directly.
func send(_ signal: Int32) {
    #if os(Windows)
        _ = receiveConsoleEvent(UInt32(signal == SIGBREAK ? CTRL_BREAK_EVENT : CTRL_C_EVENT))
    #else
        kill(getpid(), signal)
    #endif
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
        #if os(Windows)
            #expect(signalName(SIGBREAK) == "SIGBREAK")
        #else
            #expect(signalName(SIGHUP) == "SIGHUP")
            #expect(signalName(SIGUSR1) == "SIGUSR1")
            #expect(signalName(SIGWINCH) == "SIGWINCH")
        #endif
    }

    @Test("falls back to the number for an unknown signal")
    func unknown() {
        #expect(signalName(1234) == "signal 1234")
    }
}
