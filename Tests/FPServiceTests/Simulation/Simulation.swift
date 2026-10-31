import Dispatch
import Synchronization

/// A deterministic runtime for one run: every task that prefers it runs on
/// one thread, one job at a time, in an order the seed picks, and its clock
/// moves only when no job is ready. So a seed is one interleaving, and the
/// same seed is the same run.
///
/// A task prefers it when started with `Task(executorPreference:)`, and its
/// child tasks and `@concurrent` functions inherit that. Anything else — a
/// plain `Task {}`, Dispatch, `Task.sleep` — escapes it, so code under
/// simulation takes its tasks, threads and clock from seams.
final class Simulation: TaskExecutor, Sendable {
    private struct Timer {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var random: SplitMix64
        var ready: [UnownedJob] = []
        var timers: [Timer] = []
        var now: Duration = .zero
        var nextTimerID = 0
        /// While offloaded work runs: the stretches it keeps its thread
        /// busy for, in order (see ``block(for:then:)``).
        var busy: [(duration: Duration, then: @Sendable () -> Void)]?
    }

    private let state: Mutex<State>

    init(seed: UInt64) {
        state = Mutex(State(random: SplitMix64(seed: seed)))
    }

    /// The simulated clock: it moves only when no job is ready, straight to
    /// the next deadline.
    var clock: SimulationClock { SimulationClock(simulation: self) }

    /// Simulated time since the run began.
    var now: Duration { state.withLock { $0.now } }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        state.withLock { $0.ready.append(job) }
    }

    /// Runs `operation` in a task that prefers this executor until nothing
    /// is left to run, on a thread of its own (the concurrency pool may have
    /// one thread). Returns its result, or `nil` if it never finished: every
    /// task left was waiting for something that could never happen.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T? {
        let result = Mutex<T?>(nil)
        Task(executorPreference: self) {
            let value = await operation()
            result.withLock { $0 = value }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "Simulation").async {
                self.drain()
                done.resume()
            }
        }
        return result.withLock { $0 }
    }

    /// Runs synchronous work as a task of its own, as ``Service`` runs its
    /// shutdown request on a thread of its own: the work interleaves with
    /// the rest of the run, and returns once every stretch it was busy for
    /// has passed. Nothing cancels it, as nothing cancels a thread.
    func offload(_ work: @escaping @Sendable () -> Void) async {
        await Task(executorPreference: self) { [self] in
            state.withLock { $0.busy = [] }
            work()
            let busy = state.withLock { state in
                defer { state.busy = nil }
                return state.busy ?? []
            }
            for stretch in busy {
                try? await clock.sleep(for: stretch.duration)
                stretch.then()
            }
        }.value
    }

    /// From synchronous work: keeps its thread busy for `duration`, as a
    /// slow or blocking call would, then runs `then`. Under ``offload(_:)``
    /// the rest of the run goes on meanwhile; anywhere else a thread of the
    /// run would be held, so it takes no time.
    func block(for duration: Duration, then: @escaping @Sendable () -> Void) {
        let offloaded = state.withLock { state in
            state.busy?.append((duration, then))
            return state.busy != nil
        }
        if !offloaded { then() }
    }

    private enum Step {
        case run(UnownedJob)
        case wake([CheckedContinuation<Void, any Error>])
        case idle
    }

    /// Runs a ready job the seed picks; when none is ready, moves the clock
    /// to the next deadline and wakes its sleeps, in the order they began.
    private func drain() {
        while true {
            let step = state.withLock { state -> Step in
                if !state.ready.isEmpty {
                    let index = Int(state.random.next() % UInt64(state.ready.count))
                    return .run(state.ready.remove(at: index))
                }
                guard let next = state.timers.map(\.deadline).min() else { return .idle }
                state.now = next
                let due = state.timers.filter { $0.deadline <= next }.sorted { $0.id < $1.id }
                state.timers.removeAll { $0.deadline <= next }
                return .wake(due.map(\.continuation))
            }
            switch step {
                case .run(let job): job.runSynchronously(on: asUnownedTaskExecutor())
                case .wake(let sleepers): sleepers.forEach { $0.resume() }
                case .idle: return
            }
        }
    }

    fileprivate func sleep(until deadline: Duration) async throws {
        let id = state.withLock { state in
            state.nextTimerID += 1
            return state.nextTimerID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let immediate = state.withLock { state -> Bool? in
                    if deadline <= state.now { return true }
                    if Task.isCancelled { return false }
                    state.timers.append(
                        Timer(id: id, deadline: deadline, continuation: continuation)
                    )
                    return nil
                }
                switch immediate {
                    case true?: continuation.resume()
                    case false?: continuation.resume(throwing: CancellationError())
                    case nil: break
                }
            }
        } onCancel: {
            let timer = state.withLock { state in
                state.timers.firstIndex { $0.id == id }.map { state.timers.remove(at: $0) }
            }
            timer?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// A ``Simulation``'s clock.
struct SimulationClock: Clock {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    let simulation: Simulation

    var now: Instant { Instant(offset: simulation.now) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await simulation.sleep(until: deadline.offset)
    }
}

/// A small, fast, seedable generator (SplitMix64): the same seed gives the
/// same numbers on every platform.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
