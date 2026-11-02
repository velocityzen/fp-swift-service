import Benchmark
import BenchmarkSupport
import Dispatch
import ProcessSignals

#if canImport(Darwin)
    import Darwin
#endif

// `processSignals`: subscribing to one signal or two and letting go of them,
// and delivering one. "(baseline)" entries do the same with Dispatch signal
// sources by hand. The benchmarks use SIGCONT and SIGWINCH: their default
// actions resume a stopped process and do nothing, so a benchmark can never
// end the process.

let queue = DispatchQueue(label: "SignalBenchmarks")

/// The handler a hand-written subscription installs: Dispatch records the
/// signal, so it does nothing.
func ignoreSignal(_: Int32) {}

/// Subscribes to `signal` with a Dispatch source, waiting for the
/// registration as `processSignals` does, and catches it.
func subscribe(
    _ signal: Int32,
    _ handler: @escaping @Sendable () -> Void
) async -> (any DispatchSourceSignal, sigaction) {
    let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
    source.setEventHandler(handler: handler)
    await withUnsafeContinuation { (registered: UnsafeContinuation<Void, Never>) in
        source.setRegistrationHandler { registered.resume() }
        source.resume()
    }
    var action = sigaction()
    action.__sigaction_u.__sa_handler = ignoreSignal
    action.sa_flags = SA_RESTART
    sigemptyset(&action.sa_mask)
    var previous = sigaction()
    sigaction(signal, &action, &previous)
    return (source, previous)
}

/// Restores the disposition and cancels the source.
func unsubscribe(_ signal: Int32, _ source: any DispatchSourceSignal, _ previous: sigaction) {
    var previous = previous
    sigaction(signal, &previous, nil)
    source.cancel()
}

/// A stream of `signal` from a Dispatch source, which lets go of the signal
/// when the stream ends: `processSignals` by hand, for one signal.
func signalStream(_ signal: Int32) async -> AsyncStream<Int32> {
    let (stream, continuation) = AsyncStream<Int32>.makeStream()
    let (source, previous) = await subscribe(signal) { continuation.yield(signal) }
    continuation.onTermination = { _ in unsubscribe(signal, source, previous) }
    return stream
}

/// ``signalStream(_:)`` for two signals, subscribed one after the other.
func signalStream(_ first: Int32, _ second: Int32) async -> AsyncStream<Int32> {
    let (stream, continuation) = AsyncStream<Int32>.makeStream()
    let (firstSource, firstPrevious) = await subscribe(first) { continuation.yield(first) }
    let (secondSource, secondPrevious) = await subscribe(second) { continuation.yield(second) }
    continuation.onTermination = { _ in
        unsubscribe(first, firstSource, firstPrevious)
        unsubscribe(second, secondSource, secondPrevious)
    }
    return stream
}

let benchmarks: @Sendable () -> Void = {
    Benchmark("signal source (baseline)", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await signalStream(SIGCONT))
        }
    }

    Benchmark("processSignals", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let signals = await processSignals([SIGCONT])
            blackHole(signals)
        }
    }

    Benchmark("two signal sources (baseline)", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await signalStream(SIGCONT, SIGWINCH))
        }
    }

    Benchmark("processSignals, two signals", configuration: .service()) { benchmark in
        for _ in benchmark.scaledIterations {
            let signals = await processSignals([SIGCONT, SIGWINCH])
            blackHole(signals)
        }
    }

    Benchmark("signal source delivery (baseline)", configuration: .service()) { benchmark in
        let signals = await signalStream(SIGCONT)
        var iterator = signals.makeAsyncIterator()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            kill(getpid(), SIGCONT)
            blackHole(await iterator.next())
        }
        benchmark.stopMeasurement()
    }

    Benchmark("processSignals delivery", configuration: .service()) { benchmark in
        let signals = await processSignals([SIGCONT])
        var iterator = signals.makeAsyncIterator()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            kill(getpid(), SIGCONT)
            blackHole(await iterator.next())
        }
        benchmark.stopMeasurement()
    }
}
