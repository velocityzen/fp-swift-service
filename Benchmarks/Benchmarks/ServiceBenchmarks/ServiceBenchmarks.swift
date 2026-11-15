import Benchmark
import BenchmarkSupport
import FPBracket
import FPService
import Synchronization

#if canImport(Darwin)
    import Darwin
#endif

// One `Service` run: acquire, `serve`, dispose, with the lifecycle around
// them. `serve` returns at once, so a run is the service's own overhead:
// its tasks, its inbox and its stage machine. "(baseline)" entries run the
// same bracket by hand, in a task of its own as the service does, so the
// gap is what the lifecycle costs.

/// The service every benchmark runs: acquires 1, releases it.
func makeBracket() -> BracketAsync<Int, BenchError> {
    BracketAsync(acquire: { await acquireAsync(1) }, dispose: { await releaseAsync($0) })
}

/// A `serve` that returns at once.
@concurrent
func serveAtOnce(_ resource: Int, _: Shutdown) async -> VoidResult {
    work(resource)
}

/// A `serve` that returns once shutdown is requested or its task cancelled.
@concurrent
func serveUntilShutdown(_ resource: Int, _ shutdown: Shutdown) async -> VoidResult {
    await shutdown.requested
    return work(resource)
}

/// An observer that reads every event.
@concurrent
func readEvents(_ events: ServiceEvents<BenchError>) async {
    for await event in events {
        blackHole(event)
    }
}

// The run with a shutdown timeout keeps time on `StoppedClock`. Stage 1
// starts a task that sleeps for the timeout, and the run cancels it once
// dispose has returned, which with `serveAtOnce` is almost at once. Whether
// that task has begun its sleep by then is up to the scheduler, and a
// `ContinuousClock` sleep that has begun costs 5 allocations, one of them an
// object, a retain and a release more than one whose task is already
// cancelled. On a busy runner the two orderings mix differently from run to
// run, so the same code moved by more than half a call. `StoppedClock`'s
// sleep costs the same whichever comes first, so the benchmark counts what
// FPService does for a timeout, its task and its steps, and not the
// standard library's timer.

/// A clock on which no time passes: a sleep ends only when its task is
/// cancelled, and costs the same whether the cancel comes before the sleep
/// or during it.
struct StoppedClock: Clock {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {
        let sleeper = Sleeper()
        await withTaskCancellationHandler {
            await withUnsafeContinuation { sleeper.suspend($0) }
        } onCancel: {
            sleeper.cancel()
        }
        throw CancellationError()
    }
}

/// One sleep on `StoppedClock`: the cancel resumes it, or, if the cancel
/// came first, it never suspends.
final class Sleeper: Sendable {
    private enum State {
        case awake
        case asleep(UnsafeContinuation<Void, Never>)
        case cancelled
    }

    private let state = Mutex(State.awake)

    func suspend(_ continuation: UnsafeContinuation<Void, Never>) {
        let cancelled = state.withLock { state in
            guard case .awake = state else { return true }
            state = .asleep(continuation)
            return false
        }
        if cancelled { continuation.resume() }
    }

    func cancel() {
        let asleep = state.withLock { state -> UnsafeContinuation<Void, Never>? in
            defer { state = .cancelled }
            guard case .asleep(let continuation) = state else { return nil }
            return continuation
        }
        asleep?.resume()
    }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark("bracket in a Task (baseline)", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let bracket = makeBracket()
            let task = Task { await bracket { work($0) } }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            blackHole(result)
        }
    }

    Benchmark("Service", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let withService = Service(makeBracket())
            blackHole(await withService(serveAtOnce))
        }
    }

    Benchmark("Service with shutdown timeout", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let withService = Service(
                makeBracket(),
                shutdownTimeout: .seconds(60),
                clock: ServiceClock(StoppedClock())
            )
            blackHole(await withService(serveAtOnce))
        }
    }

    Benchmark("Service with observer", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let withService = Service(makeBracket(), observe: readEvents)
            blackHole(await withService(serveAtOnce))
        }
    }

    // SIGCONT: its default action only resumes a stopped process, so the
    // benchmark can never end the process by mistake.
    Benchmark("Service with shutdown signals", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let withService = Service(makeBracket(), shutdownSignals: [SIGCONT])
            blackHole(await withService(serveAtOnce))
        }
    }

    // The caller cancels at once: stage 2 cancels `serve`, which waits for
    // shutdown.
    Benchmark("cancelled bracket in a Task (baseline)", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let bracket = makeBracket()
            let shutdown = Shutdown()
            let task = Task { await bracket { await serveUntilShutdown($0, shutdown) } }
            task.cancel()
            blackHole(await task.value)
        }
    }

    Benchmark("Service cancelled by its caller", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let task = Task {
                let withService = Service(makeBracket())
                return await withService(serveUntilShutdown)
            }
            task.cancel()
            blackHole(await task.value)
        }
    }
}
