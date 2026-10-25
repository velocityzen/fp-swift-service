import Synchronization

/// The state of one ``Service`` run, shared by its child tasks.
///
/// Every stage change and every event happens under one lock, so events come
/// out in the order the stages changed. Side effects that run user code
/// (shutdown handlers) or end the process run after the lock is released.
final class ServiceRun<Failure: Error>: Sendable {
    typealias Event = Result<ServiceEvent, ServiceError<Failure>>

    enum Stage: Sendable {
        case running
        /// Stage 1.
        case graceful
        /// Stage 2.
        case cancelling
    }

    struct State {
        var stage = Stage.running
        var shutdownReason: ShutdownReason?
        var cancellationReason: CancellationReason?
        var ready = false
        var startFailure: Failure?
        var serveFailure: Failure?
        var stopFailure: Failure?
        var timedOut: Duration?
        var stopBegan: Duration?
        var stopEnded: Duration?
    }

    /// What a signal does, decided under the lock and carried out after it.
    private enum Effect {
        case none
        case graceful
        case cancel
        case kill(Int32)
    }

    /// Handed to `serve`; requested when stage 1 begins.
    let shutdown = Shutdown()
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

    func started() {
        state.withLock { _ in emit(.success(.started)) }
    }

    func ready() {
        state.withLock { state in
            state.ready = true
            emit(.success(.ready))
        }
    }

    /// `serve` returned. Starts the graceful stage — unless the task was
    /// cancelled: cancellation never turns into a graceful request.
    func served(_ served: Result<Void, Failure>) {
        let cancelled = Task.isCancelled
        let now = clock.now()
        let effect = state.withLock { state -> Effect in
            state.stopBegan = now
            if case .failure(let error) = served {
                state.serveFailure = error
                emit(.failure(.serveFailed(error)))
            }
            guard !cancelled else { return .none }
            return beginGraceful(&state, .serveReturned) ? .graceful : .none
        }
        apply(effect)
    }

    /// The bracket call returned: acquire's failure before `ready`,
    /// dispose's after.
    func finished(_ result: Result<Void, Failure>) {
        let now = clock.now()
        state.withLock { state in
            state.stopEnded = now
            guard case .failure(let error) = result else { return }
            if !state.ready {
                state.startFailure = error
                emit(.failure(.startFailed(error)))
            } else {
                state.stopFailure = error
                if let serve = state.serveFailure {
                    emit(.failure(.serveAndStopFailed(serve: serve, stop: error)))
                } else {
                    emit(.failure(.stopFailed(error)))
                }
            }
        }
        done.open()
    }

    // MARK: Stages

    /// A signal arrived: move one stage forward from where the run is.
    func receive(_ signal: Int32) {
        let effect = state.withLock { state -> Effect in
            emit(.success(.signal(signal)))
            switch state.stage {
                case .running:
                    return beginGraceful(&state, .signal(signal)) ? .graceful : .none
                case .graceful:
                    return beginCancel(&state, .signal(signal)) ? .cancel : .none
                case .cancelling:
                    return .kill(signal)
            }
        }
        apply(effect)
    }

    /// Stage 2 for a reason other than a signal (deadline, caller).
    func cancel(_ reason: CancellationReason) {
        let began = state.withLock { beginCancel(&$0, reason) }
        if began { apply(.cancel) }
    }

    private func beginGraceful(_ state: inout State, _ reason: ShutdownReason) -> Bool {
        guard state.stage == .running else { return false }
        state.stage = .graceful
        state.shutdownReason = reason
        emit(.success(.shuttingDown(reason)))
        return true
    }

    private func beginCancel(_ state: inout State, _ reason: CancellationReason) -> Bool {
        guard state.stage != .cancelling else { return false }
        state.stage = .cancelling
        state.cancellationReason = reason
        emit(.success(.cancelling(reason)))
        if case .shutdownTimeout(let after) = reason {
            state.timedOut = after
            emit(.failure(.shutdownTimeout(after: after)))
        }
        return true
    }

    private func apply(_ effect: Effect) {
        switch effect {
            case .none: break
            case .graceful: shutdown.trigger()
            case .cancel: cancelling.open()
            case .kill(let signal): terminate(signal)
        }
    }

    // MARK: Result

    /// The run's result, read once every child has finished.
    func result() -> Result<ServiceOutcome, ServiceError<Failure>> {
        let state = state.withLock { $0 }
        if let error = state.startFailure { return .failure(.startFailed(error)) }
        switch (state.serveFailure, state.stopFailure) {
            case (let serve?, let stop?): return .failure(.serveAndStopFailed(serve: serve, stop: stop))
            case (let serve?, nil): return .failure(.serveFailed(serve))
            default: break
        }
        if let after = state.timedOut { return .failure(.shutdownTimeout(after: after)) }
        if let stop = state.stopFailure { return .failure(.stopFailed(stop)) }
        return .success(outcome(state))
    }

    /// Ends the event stream: `.stopped` for a service that started, then finish.
    func finishEvents() {
        state.withLock { state in
            if state.startFailure == nil { emit(.success(.stopped(outcome(state)))) }
        }
        continuation?.finish()
    }

    private func outcome(_ state: State) -> ServiceOutcome {
        var stopDuration: Duration?
        if let began = state.stopBegan, let ended = state.stopEnded {
            stopDuration = ended - began
        }
        return ServiceOutcome(
            shutdownReason: state.shutdownReason,
            cancellationReason: state.cancellationReason,
            stopDuration: stopDuration
        )
    }

    private func emit(_ event: Event) {
        continuation?.yield(event)
    }
}
