import Synchronization

/// The state of one ``Service`` run, shared by its child tasks.
///
/// Every stage change is a step of the pure `State.step(_:)` (see
/// ServiceRun+Step.swift), taken under one lock with its events emitted
/// there too, so events come out in the order the stages changed. Side
/// effects that run user code (shutdown handlers) or end the process run
/// after the lock is released.
final class ServiceRun<Failure: Error>: Sendable {
    typealias Event = Result<ServiceEvent, ServiceError<Failure>>

    /// Handed to `serve`; requested when stage 1 begins.
    let shutdown = Shutdown()
    /// Opens when stage 1 begins, before `shutdown` is requested. The
    /// timeout starts from it, so a shutdown handler that blocks can't hold
    /// the timeout back.
    let graceful = Gate()
    /// Opens when stage 2 begins.
    let cancelling = Gate()
    /// Opens when the bracket call has returned (dispose finished).
    let done = Gate()

    let clock: ServiceClock
    private let state = Mutex(State())
    private let continuation: ServiceEvents<Failure>.Continuation?
    private let terminate: @Sendable (Int32) -> Void

    init(
        clock: ServiceClock,
        continuation: ServiceEvents<Failure>.Continuation?,
        terminate: @escaping @Sendable (Int32) -> Void
    ) {
        self.clock = clock
        self.continuation = continuation
        self.terminate = terminate
    }

    // MARK: Lifecycle

    /// The shutdown signals could not all be subscribed to: the run fails
    /// before anything starts.
    func signalsUnavailable(_ signals: [Int32]) {
        apply(step(.signalsUnavailable(signals)))
    }

    func started() {
        apply(step(.started))
    }

    func ready() {
        apply(step(.ready))
    }

    /// `serve` returned. Starts the graceful stage — unless the task was
    /// cancelled: cancellation never turns into a graceful request.
    func served(_ served: Result<Void, Failure>) {
        apply(step(.served(served, cancelled: Task.isCancelled, at: clock.now())))
    }

    /// The bracket call returned.
    func finished(_ result: Result<Void, Failure>) {
        apply(step(.finished(result, at: clock.now())))
        done.open()
    }

    // MARK: Stages

    /// A signal arrived: move one stage forward from where the run is.
    ///
    /// Returns whether it began the graceful stage. The caller then requests
    /// `shutdown` in a task of its own: the request runs the shutdown
    /// handlers, and one that blocks must not keep the next signal from
    /// being read.
    func receive(_ signal: Int32) -> Bool {
        let effect = step(.signal(signal, at: clock.now()))
        guard effect == .graceful else {
            apply(effect)
            return false
        }
        graceful.open()
        return true
    }

    /// Stage 2 for a reason other than a signal (deadline, caller).
    func cancel(_ reason: CancellationReason) {
        apply(step(.cancel(reason)))
    }

    /// Takes one step under the lock, emitting its events there.
    private func step(_ input: Input) -> Effect {
        state.withLock { state in
            let step = state.step(input)
            step.events.forEach { continuation?.yield($0) }
            return step.effect
        }
    }

    private func apply(_ effect: Effect) {
        switch effect {
            case .none: break
            case .graceful:
                graceful.open()
                shutdown.trigger()
            case .cancel: cancelling.open()
            case .kill(let signal): terminate(signal)
        }
    }

    // MARK: Result

    /// The run's result, read once every child has finished.
    func result() -> Result<ServiceOutcome, ServiceError<Failure>> {
        state.withLock { $0.result }
    }

    /// Ends the event stream: `.stopped` for a service that started, then finish.
    func finishEvents() {
        state.withLock { state in
            if let event = state.lastEvent { continuation?.yield(event) }
        }
        continuation?.finish()
    }
}
