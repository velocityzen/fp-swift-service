import FP
import FPBracket
@testable import FPService
import Synchronization

enum TestError: Error, Equatable {
    case boom(String)
}

struct DeadlineExceeded: Error {}

/// Runs `operation` under a wall-clock deadline, so a lifecycle bug fails the
/// test instead of hanging the suite. Nothing sleeps unless the test hangs.
func withDeadline<T: Sendable>(
    _ limit: Duration = .seconds(5),
    _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withTimeout(limit, failingWith: DeadlineExceeded()) {
        Result<T, DeadlineExceeded>.success(await operation())
    }
    .get()
}

/// An ordered record of what happened, shared by a test, its brackets, its
/// `serve` and its observer.
final class Recorder: Sendable {
    private struct State {
        var entries: [String] = []
        /// One gate per entry someone waits for, opened once it is recorded.
        var awaited: [String: Gate] = [:]
    }

    private let state = Mutex(State())

    func append(_ entry: String) {
        let gate = state.withLock { state in
            state.entries.append(entry)
            return state.awaited[entry]
        }
        gate?.open()
    }

    var all: [String] { state.withLock { $0.entries } }

    /// Entries starting with `prefix`, e.g. `"stop:"`.
    func with(prefix: String) -> [String] { all.filter { $0.hasPrefix(prefix) } }

    /// The events the observer saw, without the prefix.
    var events: [String] { with(prefix: "event: ").map { String($0.dropFirst("event: ".count)) } }

    /// Waits (without sleeping or spinning) until `entry` has been recorded,
    /// or the task is cancelled.
    func wait(for entry: String) async {
        let gate = state.withLock { state in
            if let gate = state.awaited[entry] { return gate }
            let gate = Gate()
            if state.entries.contains(entry) { gate.open() }
            state.awaited[entry] = gate
            return gate
        }
        await gate.opened
    }
}

/// A one-way latch a test opens to let a blocked phase continue.
final class Latch: Sendable {
    private let gate = Gate()

    func open() { gate.open() }

    /// Waits until opened. Ignores cancellation on purpose: a phase blocked on
    /// a latch stays blocked when cancelled, like code that ignores it.
    func wait() async {
        await gate.openedIgnoringCancellation
    }
}

/// A test service: a bracket whose resource is its name, recording each phase.
func probe(
    _ name: String,
    _ log: Recorder,
    start: Result<Void, TestError> = .success(()),
    stop: Result<Void, TestError> = .success(()),
    startGate: Latch? = nil,
    stopGate: Latch? = nil
) -> BracketAsync<String, TestError> {
    BracketAsync(
        acquire: {
            log.append("start:\(name)")
            if let startGate { await startGate.wait() }
            return start.map { name }
        },
        dispose: { _ in
            log.append("stop:\(name)")
            if let stopGate { await stopGate.wait() }
            log.append("stopped:\(name)")
            return stop
        }
    )
}

/// Three probes composed with do-notation: a → b → c.
func chain(_ log: Recorder, b: BracketAsync<String, TestError>? = nil) -> BracketAsync<
    (String, String, String), TestError
> {
    BracketAsyncDo<TestError>()
        .bind { probe("a", log) }
        .bind { _ in b ?? probe("b", log) }
        .bind { _, _ in probe("c", log) }
}

/// How a test's `serve` behaves.
enum ServeMode: Sendable {
    /// Returns once shutdown is requested.
    case untilShutdown
    /// Ignores graceful shutdown; returns only when cancelled.
    case ignoreShutdown
    /// Returns at once.
    case finish
    /// Returns at once with a failure.
    case fail
    /// Registers a shutdown handler, then returns at once.
    case finishWithHandler
}

typealias Serve<Resource> = @Sendable (Resource, Shutdown) async -> Result<Void, TestError>

func serving<Resource>(_ mode: ServeMode, _ log: Recorder) -> Serve<Resource> {
    { _, shutdown in
        log.append("serve")
        switch mode {
            case .untilShutdown:
                await shutdown.requested
            case .ignoreShutdown:
                await Shutdown().requested  // never requested: returns only when cancelled
            case .finish:
                break
            case .fail:
                log.append("served")
                return .failure(.boom("serve"))
            case .finishWithHandler:
                shutdown.onShutdown { log.append("handler") }
        }
        log.append(Task.isCancelled ? "served: cancelled" : "served")
        log.append("shutdown requested: \(shutdown.isRequested)")
        return .success(())
    }
}
