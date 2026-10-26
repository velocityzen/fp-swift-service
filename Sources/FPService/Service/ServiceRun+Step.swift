// The stage machine of one run, as a pure function: `State.step(_:)` takes
// what happened and returns the events it causes, in order, and the effect to
// carry out. No clock, lock or I/O, so tests drive it through a table of
// cases; `ServiceRun` calls it under its lock and carries out the effect.

extension ServiceRun {
    enum Stage: Sendable {
        case running
        /// Stage 1.
        case graceful
        /// Stage 2.
        case cancelling
    }

    /// What happened to the run.
    enum Input: Sendable {
        /// These shutdown signals could not be subscribed to; nothing runs.
        case signalsUnavailable([Int32])
        /// Acquire is about to begin.
        case started
        /// Acquire succeeded; `serve` begins.
        case ready
        /// `serve` returned, at `at` on the run's clock; `cancelled` if its
        /// task was.
        case served(Result<Void, Failure>, cancelled: Bool, at: Duration)
        /// The bracket call returned, at `at` on the run's clock.
        case finished(Result<Void, Failure>, at: Duration)
        /// A shutdown signal arrived.
        case signal(Int32)
        /// Stage 2 for a reason other than a signal (deadline, caller).
        case cancel(CancellationReason)
    }

    /// What a step does besides changing the state, carried out after the
    /// lock is released.
    enum Effect: Sendable, Equatable {
        case none
        /// Stage 1 began: request the shutdown.
        case graceful
        /// Stage 2 began: cancel the service.
        case cancel
        /// Stage 3: end the process the way this signal ends it.
        case kill(Int32)
    }

    /// One step's events, in order, and its effect.
    struct Step {
        var events: [Event] = []
        var effect = Effect.none
    }

    struct State: Sendable {
        var stage = Stage.running
        var shutdownReason: ShutdownReason?
        var cancellationReason: CancellationReason?
        var ready = false
        /// The bracket call has returned: nothing is left to stop.
        var finished = false
        var unavailableSignals: [Int32]?
        var startFailure: Failure?
        var serveFailure: Failure?
        var stopFailure: Failure?
        var timedOut: Duration?
        var stopBegan: Duration?
        var stopEnded: Duration?

        /// Moves the run on by what happened. Each failure is one event, as
        /// it happens; only ``result`` combines them.
        mutating func step(_ input: Input) -> Step {
            switch input {
                case .signalsUnavailable(let signals):
                    unavailableSignals = signals
                    return Step(events: [.failure(.signalsUnavailable(signals))])
                case .started:
                    return Step(events: [.success(.started)])
                case .ready:
                    ready = true
                    return Step(events: [.success(.ready)])
                case .served(let served, let cancelled, let now):
                    return serveReturned(served, cancelled: cancelled, at: now)
                case .finished(let result, let now):
                    return bracketReturned(result, at: now)
                case .signal(let signal):
                    return signalArrived(signal)
                case .cancel(let reason):
                    return beginCancel(reason, after: [])
            }
        }

        private mutating func serveReturned(
            _ served: Result<Void, Failure>,
            cancelled: Bool,
            at now: Duration
        ) -> Step {
            stopBegan = now
            var events: [Event] = []
            if case .failure(let error) = served {
                serveFailure = error
                events.append(.failure(.serveFailed(error)))
            }
            // Cancellation never turns into a graceful request.
            guard !cancelled else { return Step(events: events) }
            return beginGraceful(.serveReturned, after: events)
        }

        /// Acquire's failure before `ready`, dispose's after.
        private mutating func bracketReturned(
            _ result: Result<Void, Failure>,
            at now: Duration
        ) -> Step {
            stopEnded = now
            finished = true
            guard case .failure(let error) = result else { return Step() }
            if ready {
                stopFailure = error
                return Step(events: [.failure(.stopFailed(error))])
            }
            startFailure = error
            return Step(events: [.failure(.startFailed(error))])
        }

        /// One stage forward from where the run is. Once the bracket has
        /// returned there is nothing left to stop, so it is only an event.
        private mutating func signalArrived(_ signal: Int32) -> Step {
            let events: [Event] = [.success(.signal(signal))]
            guard !finished else { return Step(events: events) }
            switch stage {
                case .running: return beginGraceful(.signal(signal), after: events)
                case .graceful: return beginCancel(.signal(signal), after: events)
                case .cancelling: return Step(events: events, effect: .kill(signal))
            }
        }

        private mutating func beginGraceful(
            _ reason: ShutdownReason,
            after events: [Event]
        ) -> Step {
            guard stage == .running else { return Step(events: events) }
            stage = .graceful
            shutdownReason = reason
            return Step(events: events + [.success(.shuttingDown(reason))], effect: .graceful)
        }

        private mutating func beginCancel(
            _ reason: CancellationReason,
            after events: [Event]
        ) -> Step {
            guard !finished, stage != .cancelling else { return Step(events: events) }
            stage = .cancelling
            cancellationReason = reason
            var events = events + [.success(.cancelling(reason))]
            if case .shutdownTimeout(let after) = reason {
                timedOut = after
                events.append(.failure(.shutdownTimeout(after: after)))
            }
            return Step(events: events, effect: .cancel)
        }

        /// The run's result, once every child has finished.
        ///
        /// A service that never started says why: its shutdown signals were
        /// unavailable, or acquire failed (even if a timeout cancelled it
        /// first; the events show both). Then a timeout comes first — it is
        /// why the service was cancelled — carrying any serve or dispose
        /// failure with it.
        var result: Result<ServiceOutcome, ServiceError<Failure>> {
            if let signals = unavailableSignals { return .failure(.signalsUnavailable(signals)) }
            if let error = startFailure { return .failure(.startFailed(error)) }
            if let after = timedOut {
                return .failure(
                    .shutdownTimeout(after: after, serve: serveFailure, stop: stopFailure)
                )
            }
            switch (serveFailure, stopFailure) {
                case (let serve?, let stop?):
                    return .failure(.serveAndStopFailed(serve: serve, stop: stop))
                case (let serve?, nil): return .failure(.serveFailed(serve))
                case (nil, let stop?): return .failure(.stopFailed(stop))
                case (nil, nil): return .success(outcome)
            }
        }

        /// The event that ends the stream: `.stopped` for a service that
        /// started; none for one that didn't.
        var lastEvent: Event? {
            guard unavailableSignals == nil, startFailure == nil else { return nil }
            return .success(.stopped(outcome))
        }

        var outcome: ServiceOutcome {
            var stopDuration: Duration?
            if let began = stopBegan, let ended = stopEnded {
                stopDuration = ended - began
            }
            return ServiceOutcome(
                shutdownReason: shutdownReason,
                cancellationReason: cancellationReason,
                stopDuration: stopDuration
            )
        }
    }
}
