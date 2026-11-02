import Benchmark

/// Metrics recorded by every FPService benchmark: time, instructions, heap
/// traffic and ARC traffic. Every value is reported per call of the API
/// under test.
public let serviceMetrics: [BenchmarkMetric] = [
    .wallClock,
    .cpuTotal,
    .throughput,
    .instructions,
    .mallocCountTotal,
    .mallocBytesCount,
    .memoryLeakedBytes,
    .objectAllocCount,
    .retainCount,
    .releaseCount,
]

/// The metrics `baseline check` fails on. Allocation and ARC counts barely
/// move between runs of the same code, while times swing with the machine's
/// load, so times are reported but never fail a check.
public let checkedMetrics: [BenchmarkMetric] = [
    .mallocCountTotal,
    .objectAllocCount,
    .retainCount,
    .releaseCount,
]

/// How far, in percent, a checked metric's median may move before
/// `baseline check` reports it.
///
/// Every benchmark here allocates and retains the same way on every call, so
/// two runs of the same code agree exactly, `Service` runs and their tasks
/// included. The calls a service makes per request (`Shutdown` and its
/// helpers) count 20 or fewer of each, so one allocation or retain more is
/// at least 5%. A whole `Service` run counts 50 to 75 allocations and up to
/// about 210 releases, where 5% is three or more allocations, or several
/// retains; a run happens once per process.
let checkedTolerance = 5.0

func serviceThresholds() -> [BenchmarkMetric: BenchmarkThresholds] {
    Dictionary(
        uniqueKeysWithValues: serviceMetrics.map { metric in
            let thresholds =
                checkedMetrics.contains(metric)
                ? BenchmarkThresholds(relative: [.p50: checkedTolerance])
                : BenchmarkThresholds()
            return (metric, thresholds)
        }
    )
}

public extension Benchmark.Configuration {
    /// The configuration every FPService benchmark uses.
    ///
    /// Each sample runs `scaling` calls in a `benchmark.scaledIterations`
    /// loop, and the scaled metrics are divided back to a single call. Use
    /// `.kilo` for calls in the micro- or nanosecond range, so timer and
    /// sampling overhead stays out of the numbers, and `.one` for calls that
    /// already take a millisecond or so.
    static func service(
        _ tags: [String: String] = [:],
        scaling: BenchmarkScalingFactor = .kilo
    ) -> Self {
        .init(
            metrics: serviceMetrics,
            tags: tags,
            warmupIterations: 5,
            scalingFactor: scaling,
            maxDuration: .seconds(1),
            maxIterations: 10_000,
            thresholds: serviceThresholds()
        )
    }
}

// MARK: - Sources

// The resource every service acquires, serves and releases is an `Int`, and
// acquire, serve and release are the functions below. None of them suspends
// or allocates, so a benchmark measures FPService around them. They are
// `@inline(never)` so the optimizer can fold neither the API under test nor
// the hand-written baseline next to it into a constant.

/// The failure the benchmark sources could return.
public struct BenchError: Error, Equatable, Sendable {
    public init() {}
}

public typealias IntResult = Result<Int, BenchError>
public typealias VoidResult = Result<Void, BenchError>

@inline(never)
public func acquireAsync(_ value: Int) async -> IntResult {
    .success(value)
}

@inline(never)
public func releaseAsync(_ value: Int) async -> VoidResult {
    blackHole(value)
    return .success(())
}

@inline(never)
public func work(_ value: Int) -> VoidResult {
    blackHole(value)
    return .success(())
}

@inline(never)
public func workAsync(_ value: Int) async -> VoidResult {
    blackHole(value)
    return .success(())
}
