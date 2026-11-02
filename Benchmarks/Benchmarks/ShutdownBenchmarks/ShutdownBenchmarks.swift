import Benchmark
import BenchmarkSupport
import FPService
import Synchronization

// `Shutdown` and the helpers `serve` uses with it, which a service can call
// once per request or connection. "(baseline)" entries do the same job by
// hand: a flag under a lock, a list of handlers under a lock, a child task.

/// A flag tasks share, so a class, as `Shutdown` is.
final class Flag: Sendable {
    let value: Mutex<Bool>

    init(_ value: Bool) {
        self.value = Mutex(value)
    }
}

/// A flag that is never set, and one that is.
let unset = Flag(false)
let set = Flag(true)

/// Handlers by id, as a hand-written shutdown would keep them.
let handlers = Mutex<[(id: UInt64, handler: @Sendable () -> Void)]>([])

@Sendable
func onShutdown() {}

@concurrent
func operation() async -> VoidResult {
    await workAsync(1)
}

let benchmarks: @Sendable () -> Void = {
    let notRequested = Shutdown()
    let requested = Shutdown()
    requested.request()

    Benchmark("flag set (baseline)", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let flag = Flag(false)
            blackHole(
                flag.value.withLock { flag in
                    defer { flag = true }
                    return !flag
                }
            )
        }
    }

    Benchmark("Shutdown request", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Shutdown().request())
        }
    }

    Benchmark("flag read (baseline)", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(unset.value.withLock { $0 })
        }
    }

    Benchmark("isRequested", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(notRequested.isRequested)
        }
    }

    Benchmark("set flag read (baseline)", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(set.value.withLock { $0 })
        }
    }

    Benchmark("requested, already requested", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            await requested.requested
            blackHole(1)
        }
    }

    Benchmark("handler list (baseline)", configuration: .service()) { benchmark in
        var nextID: UInt64 = 0
        for _ in benchmark.scaledIterations {
            nextID += 1
            let id = nextID
            handlers.withLock { $0.append((id, onShutdown)) }
            blackHole(await workAsync(1))
            handlers.withLock { handlers in
                if let index = handlers.firstIndex(where: { $0.id == id }) {
                    handlers.remove(at: index)
                }
            }
        }
    }

    Benchmark("withShutdownHandler", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(
                await withShutdownHandler(on: notRequested, onShutdown) { await workAsync(1) }
            )
        }
    }

    Benchmark("child task (baseline)", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            async let result = operation()
            blackHole(await result)
        }
    }

    Benchmark("withCancellation", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await withCancellation(on: notRequested, operation))
        }
    }
}
