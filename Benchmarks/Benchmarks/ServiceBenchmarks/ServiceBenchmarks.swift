import Benchmark
import BenchmarkSupport
import FPBracket
import FPService

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
            let withService = Service(makeBracket(), shutdownTimeout: .seconds(60))
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
