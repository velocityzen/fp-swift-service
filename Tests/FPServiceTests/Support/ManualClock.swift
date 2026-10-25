import Synchronization

/// A clock that only moves when a test advances it, so deadlines elapse
/// deterministically and no test sleeps.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var nextID = 0
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// How many sleeps are pending.
    var sleepers: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Bool? = state.withLock { state in
                    if deadline <= state.now { return true }
                    if Task.isCancelled { return false }
                    state.sleepers.append(
                        Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                switch immediate {
                    case true?: continuation.resume()
                    case false?: continuation.resume(throwing: CancellationError())
                    case nil: break
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                state.sleepers.firstIndex { $0.id == id }.map { state.sleepers.remove(at: $0) }
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleep that is now due.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    /// Waits until at least `count` sleeps are pending.
    func waitForSleepers(_ count: Int = 1) async {
        while sleepers < count, !Task.isCancelled {
            await Task.yield()
        }
    }
}
