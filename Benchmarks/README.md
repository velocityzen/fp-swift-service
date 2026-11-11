# Benchmarks

Performance benchmarks for FPService and ProcessSignals, built on [ordo-one/benchmark](https://github.com/ordo-one/benchmark). They live in their own package so the library never depends on the benchmark package.

Every benchmark records wall clock and CPU time, instructions, malloc count and bytes, bytes not freed, object allocations, and retain and release counts. All values are **per call** of the API under test.

## Suites

| Target | Covers |
| --- | --- |
| `ServiceBenchmarks` | one `Service` run: on its own, with a shutdown timeout, with an observer, with shutdown signals, and cancelled by its caller |
| `ShutdownBenchmarks` | `Shutdown`: requesting it, `isRequested`, `requested`, `withShutdownHandler` and `withCancellation(on:_:)` |
| `SignalBenchmarks` | `processSignals`: subscribing to one signal or two and letting go of them, and delivering one |

A service acquires, serves and releases an `Int` with opaque functions that never suspend or allocate, and its `serve` returns at once, so a run measures the lifecycle around the bracket: its tasks, its inbox and its stage machine. The signal benchmarks use `SIGCONT` and `SIGWINCH`, whose default actions resume a stopped process and do nothing, so a benchmark can never end the process by mistake.

Entries marked `(baseline)` do the same job by hand, and the gap between a baseline and the entry next to it is what the API costs:

- **Service runs:** the bracket in a task of its own, with the caller's cancellation forwarded. That is the least a run needs. A real run also has a lifecycle loop, an inbox, a shutdown request and the signal stream, so it can't come close to this baseline.
- **`Shutdown`:** a flag or a list of handlers under a lock.
- **`withCancellation(on:_:)`:** an `async let` child running the operation. `withCancellation` adds an object holding the result and a wait on the shutdown, which the result ends early, so the caller wakes once more: once for the result, once for the child to finish.
- **`processSignals`:** a Dispatch signal source feeding a stream; for two signals, two sources, registered one after the other. `processSignals` registers every source at once and waits once, so with more than one signal it is faster than the baseline.

## Running

Requires Swift 6.4 on macOS. Malloc statistics come from the benchmark package's malloc interposer, so there is nothing to install.

Run everything from this directory:

```bash
swift package benchmark
```

Run one suite, or the benchmarks whose names match a regular expression:

```bash
swift package benchmark --target ShutdownBenchmarks
```

```bash
swift package benchmark --filter "Service.*"
```

List the benchmarks without running them:

```bash
swift package benchmark list
```

## Comparing before and after a change

Record a baseline, make the change, then compare the new code against it:

```bash
swift package --allow-writing-to-package-directory benchmark baseline update main
```

```bash
swift package benchmark baseline compare main
```

Baselines are saved in `.benchmarkBaselines/`, which is not committed: they are only comparable on the machine that recorded them.

Malloc, object-allocation and ARC counts are the same on every run of the same code, so they are the numbers to watch first. Times move with the machine's load; close other work before comparing them.

`baseline check` fails only when one of those four counts gets worse by half a call or more at the median; times and the other metrics are reported by `compare` but never fail a check. It compares and prints raw samples, not per-call values: each sample is the total of 1,000 calls plus a few allocations and retains of the benchmark harness, which move between runs. So `base 1`, `head 2` is one object allocation more in 1,000 calls, which passes, while one more per call is 1,000 more. A benchmark at `scaling: .one` has one call per sample, so its counts may move by 5% instead. The allowances are `checkedCallShare` and `checkedTolerance` in [BenchmarkSupport.swift](Sources/BenchmarkSupport/BenchmarkSupport.swift).

```bash
swift package benchmark baseline check main
```

## Continuous integration

The [Benchmarks workflow](../.github/workflows/benchmarks.yml) benchmarks every push to `main` against the commit it was pushed on top of, and every pull request against its base branch. The job summary lists every metric's change, and the job fails when an allocation or ARC count regresses; the job log shows every count that crossed its threshold. An improvement passes.

`baseline check base head` builds nothing: it compares two recorded baselines and takes its thresholds from the base one. So a change to the thresholds or the tolerance applies from the commit after it, and the commit that makes it is still checked against the old ones.

## Finding where allocations come from

Print the call stacks behind each benchmark's allocations, most frequent first:

```bash
swift package benchmark --target ServiceBenchmarks --filter "Service" --allocation-stacks
```

## Profiling

Each suite is an ordinary executable that runs all of its benchmarks when launched on its own, so it can be profiled in Instruments or debugged in lldb:

```bash
swift build -c release --product ServiceBenchmarks
```
