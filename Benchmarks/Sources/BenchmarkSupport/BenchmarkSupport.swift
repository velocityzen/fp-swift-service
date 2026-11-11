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

// Every benchmark here allocates and retains the same way on every call, so
// two runs of the same code agree exactly per call, `Service` runs and their
// tasks included, and one allocation or retain more per call is a
// regression. `baseline check` compares raw samples, though, each the total
// of `scaling` calls plus a few allocations and retains of the benchmark
// harness around them, and those few move from run to run: a signal
// delivery allocates no object, yet its samples count one or two. On counts
// near zero any percentage fails on that.

/// How far a checked count's median may move, as a share of one call,
/// before `baseline check` reports it. In a sample of 1,000 calls half a
/// call is hundreds of times the harness's few, and half of one more
/// allocation or retain per call.
let checkedCallShare = 0.5

/// How far, in percent, a checked count's median may move before
/// `baseline check` reports it at `scaling: .one`, where a sample is a
/// single call and cannot tell the harness's few from the call's own. A
/// `Service` run counts 50 to 75 allocations and up to about 210 releases,
/// where 5% is three or more.
let checkedTolerance = 5.0

func serviceThresholds(scaling: BenchmarkScalingFactor) -> [BenchmarkMetric: BenchmarkThresholds] {
    let checked =
        scaling == .one
        ? BenchmarkThresholds(relative: [.p50: checkedTolerance])
        : BenchmarkThresholds(absolute: [.p50: Int(checkedCallShare * Double(scaling.rawValue))])
    return Dictionary(
        uniqueKeysWithValues: serviceMetrics.map { metric in
            (metric, checkedMetrics.contains(metric) ? checked : BenchmarkThresholds())
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
            thresholds: serviceThresholds(scaling: scaling)
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
