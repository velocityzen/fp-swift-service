// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #endif
    @testable import FPService
    import HegelTesting
    import Testing

    typealias Lifecycle = ServiceLifecycle<TestError>
    typealias LifecycleEvent = Lifecycle.Event

    /// The stage machine, `ServiceLifecycle.State.step`, over whole runs: the
    /// inputs the loop can give it, in an order it can give them, each step
    /// checked as it is taken.
    @Suite(.hegel)
    struct StageMachineProperties {
        /// Over any run the loop can produce, every step does what Stopping.md
        /// says: a signal moves one stage forward, serve returning begins stage
        /// 1, the caller or the timeout begins stage 2, a signal in stage 2
        /// ends the process; nothing moves once the bracket has returned. The
        /// step's events say so, in order, and the result and outcome are what
        /// the run went through.
        @Test(.hegel(testCases: 1_000))
        func everyStepFollowsTheStages() throws {
            try property(reaching: StageReach.all) { tc in
                let policy = try tc.draw(StageGen.policy, named: "policy")
                var run = StageRun(policy: policy)
                if let unavailable = policy.unavailable {
                    try run.take(.signalsUnavailable(unavailable), tc)
                } else {
                    try run.take(.started, tc)
                    while !run.environment.finished {
                        try run.take(try tc.draw(run.environment.next, named: "input"), tc)
                    }
                    for _ in 0..<policy.signalsAfterFinish {
                        try run.take(.signal(SIGTERM, at: run.environment.now), tc)
                    }
                }
                try run.checkResult(tc)
            }
        }
    }

    /// The reach claims: states the runs must get to for the checks to mean
    /// anything.
    enum StageReach {
        static let killed = "a signal in stage 2 ended the process"
        static let timedOut = "the timeout cancelled the service"
        static let callerCancelled = "the caller cancelled the service"
        static let awaitedHandlers = "serve returned in stage 1"
        static let servedCancelled = "serve returned cancelled"
        static let afterFinish = "a signal came after the bracket returned"
        static let startFailed = "acquire failed"
        static let serveAndStopFailed = "serve and dispose both failed"

        static let all = [
            killed, timedOut, callerCancelled, awaitedHandlers, servedCancelled, afterFinish,
            startFailed, serveAndStopFailed,
        ]
    }

    /// What every run of one test case shares, drawn first, so runs differ in
    /// kind: some never fail, some always do; some have no timeout.
    struct StagePolicy: Sendable, CustomStringConvertible {
        /// Set for a run whose signals could not be subscribed to.
        var unavailable: [Int32]?
        var timeout: Duration?
        /// How often acquire, serve and dispose fail, each on its own.
        var acquireFails: Double
        var serveFails: Double
        var disposeFails: Double
        /// How many inputs from outside the bracket (signals, the caller, the
        /// timeout) at most.
        var outsideInputs: Int
        /// Signals that arrive after the bracket returned: the loop has ended
        /// by then, but the step still takes them.
        var signalsAfterFinish: Int

        var description: String {
            "unavailable \(unavailable.map { "\($0)" } ?? "none"), timeout "
                + "\(timeout.map { "\($0)" } ?? "none"), failing acquire \(acquireFails), serve "
                + "\(serveFails), dispose \(disposeFails), "
                + "outside inputs \(outsideInputs), signals after finish \(signalsAfterFinish)"
        }
    }

    enum StageGen {
        /// Mostly available.
        static let unavailable: Gen<[Int32]?> = .oneOf(
            .just(nil),
            .just(nil),
            .just(nil),
            .element(of: [[1234], [SIGTERM, 1234]])
        )
        static let timeout: Gen<Duration?> = .oneOf(
            .just(nil),
            .element(of: [.zero, .milliseconds(250), .seconds(1)])
        )
        /// Some failures first, so a failure shrinks toward the mix; then none
        /// and all.
        static let failureRate: Gen<Double> = .element(of: [0.25, 0.0, 1.0])
        static let outsideInputs: Gen<Int> = .oneOf(.int(in: 0...4), .int(in: 0...16))
        static let signalsAfterFinish: Gen<Int> = .oneOf(.just(0), .int(in: 1...2))

        static let policy: Gen<StagePolicy> = Hegel.zip(
            unavailable,
            timeout,
            failureRate,
            failureRate,
            failureRate,
            outsideInputs,
            signalsAfterFinish
        ).map {
            StagePolicy(
                unavailable: $0,
                timeout: $1,
                acquireFails: $2,
                serveFails: $3,
                disposeFails: $4,
                outsideInputs: $5,
                signalsAfterFinish: $6
            )
        }

        /// Mostly the same instant, so inputs coincide; sometimes later.
        static let advance: Gen<Duration> = .oneOf(
            .just(.zero),
            .element(of: [.milliseconds(250), .seconds(1), .seconds(30)])
        )

        static let signal: Gen<Int32> = .element(of: [SIGTERM, SIGINT, SIGHUP])
    }

    /// What can happen next from outside the stage machine, as the loop and
    /// the bracket's task would make it happen. It learns only from the
    /// effects the loop carries out: a `.graceful` starts the timeout, a
    /// `.cancel` cancels the bracket's task.
    struct StageEnvironment {
        enum Bracket { case acquiring, serving, disposing, returned }

        let policy: StagePolicy
        var bracket = Bracket.acquiring
        var now: Duration = .zero
        var outsideLeft: Int
        var callerCancelled = false
        /// When the timeout passes, once stage 1 has started it.
        var timeoutAt: Duration?
        var timeoutFired = false
        /// Whether the loop has cancelled the bracket's task.
        var cancelled = false

        init(policy: StagePolicy) {
            self.policy = policy
            outsideLeft = policy.outsideInputs
        }

        var finished: Bool { bracket == .returned }

        /// What the loop sees next: the bracket's progress, or (while the
        /// budget lasts) a signal, the caller cancelling or the timeout
        /// passing. The bracket's progress comes first, so a failure shrinks
        /// toward the shortest run.
        var next: Gen<Lifecycle.Input> {
            let env = self
            return Gen { tc in
                let at = env.now + (try tc.draw(StageGen.advance))
                var choices: [Gen<Lifecycle.Input>] = [env.progress(at: at)]
                if env.outsideLeft > 0 {
                    choices.append(StageGen.signal.map { .signal($0, at: at) })
                    if !env.callerCancelled { choices.append(.just(.cancel(.caller))) }
                    // Inputs after the timeout carry a time after it (`took`).
                    if env.timeoutAt != nil, !env.timeoutFired, let timeout = env.policy.timeout {
                        choices.append(.just(.cancel(.shutdownTimeout(after: timeout))))
                    }
                }
                let choice = try tc.draw(.int(in: 0...(choices.count - 1)))
                return try tc.draw(choices[choice])
            }
            .printed { input, printer in printer.text(describe(input)) }
        }

        /// The bracket's next step: acquire succeeds or fails; serve returns,
        /// cancelled only if the loop has cancelled it; dispose returns.
        private func progress(at now: Duration) -> Gen<Lifecycle.Input> {
            switch bracket {
                case .acquiring:
                    return Gen.bool(probability: policy.acquireFails).map {
                        $0 ? .finished(.failure(.boom("acquire")), at: now) : .ready
                    }
                case .serving:
                    let wasCancelled = cancelled ? Gen.bool() : .just(false)
                    return Hegel.zip(Gen.bool(probability: policy.serveFails), wasCancelled).map {
                        fails,
                        cancelled in
                        .served(
                            fails ? .failure(.boom("serve")) : .success(()),
                            cancelled: cancelled,
                            at: now
                        )
                    }
                case .disposing:
                    return Gen.bool(probability: policy.disposeFails).map {
                        .finished($0 ? .failure(.boom("dispose")) : .success(()), at: now)
                    }
                case .returned:
                    return .just(.signal(SIGTERM, at: now))
            }
        }

        /// Moves on by `input`, which the step turned into `effect`.
        mutating func took(_ input: Lifecycle.Input, effect: Lifecycle.Effect) {
            switch input {
                case .ready: bracket = .serving
                case .served(_, _, let at):
                    bracket = .disposing
                    now = at
                case .finished(_, let at):
                    bracket = .returned
                    now = at
                case .signal(_, let at):
                    outsideLeft -= 1
                    now = at
                case .cancel(.caller):
                    outsideLeft -= 1
                    callerCancelled = true
                case .cancel(.shutdownTimeout):
                    outsideLeft -= 1
                    timeoutFired = true
                    now = max(now, timeoutAt ?? now)
                case .cancel(.signal), .started, .signalsUnavailable: break
            }
            switch effect {
                case .graceful:
                    if let timeout = policy.timeout { timeoutAt = now + timeout }
                case .cancel: cancelled = true
                case .none, .awaitHandlers, .kill: break
            }
        }
    }

    /// One run: the stage machine under test, the model beside it, and the
    /// environment feeding both.
    struct StageRun {
        var state = Lifecycle.State()
        var model = StageModel()
        var environment: StageEnvironment
        var events: [LifecycleEvent] = []

        init(policy: StagePolicy) { environment = StageEnvironment(policy: policy) }

        /// Steps both with `input`, and checks the step.
        mutating func take(_ input: Lifecycle.Input, _ tc: TestCase) throws {
            let stageBefore = stage(of: state.stage)
            let finishedBefore = state.finished
            let step = state.step(input)
            let expected = model.take(input)
            events += step.events

            #expect(step.effect == expected, "effect of \(describe(input))")
            #expect(
                stage(of: state.stage) >= stageBefore,
                "the stage moved back on \(describe(input))"
            )
            #expect(
                stage(of: state.stage) == model.stage,
                "stage \(state.stage), not \(model.stage), after \(describe(input))"
            )
            if case .signal(let signal, _) = input {
                #expect(step.events.first == .success(.signal(signal)), "signal event first")
            }
            #expect(
                step.events.filter(isTold) == told(input),
                "\(step.events) on \(describe(input))"
            )
            if finishedBefore {
                #expect(step.effect == .none, "\(step.effect) after the bracket returned")
                #expect(
                    step.events.allSatisfy(isSignal),
                    "\(step.events) after the bracket returned"
                )
                try tc.event(StageReach.afterFinish)
            }
            #expect(
                step.events.contains(where: isShuttingDown) == (step.effect == .graceful),
                "shuttingDown iff the step began stage 1: \(step.events)"
            )
            #expect(
                step.events.contains(where: isCancelling) == (step.effect == .cancel),
                "cancelling iff the step began stage 2: \(step.events)"
            )
            try reach(input, step.effect, tc)
            environment.took(input, effect: step.effect)
        }

        /// The events, besides stages and signals, that `input` must be told
        /// with: each failure as it happens (a timeout is told with its
        /// cancel), and the start.
        private func told(_ input: Lifecycle.Input) -> [LifecycleEvent] {
            switch input {
                case .signalsUnavailable(let signals): [.failure(.signalsUnavailable(signals))]
                case .started: [.success(.started)]
                case .ready: [.success(.ready)]
                case .served(.failure(let error), _, _): [.failure(.serveFailed(error))]
                case .finished(.failure(let error), _):
                    [.failure(model.ready ? .stopFailed(error) : .startFailed(error))]
                default: []
            }
        }

        private func reach(_ input: Lifecycle.Input, _ effect: Lifecycle.Effect, _ tc: TestCase)
            throws
        {
            switch (input, effect) {
                case (_, .kill): try tc.event(StageReach.killed)
                case (.cancel(.shutdownTimeout), .cancel): try tc.event(StageReach.timedOut)
                case (.cancel(.caller), .cancel): try tc.event(StageReach.callerCancelled)
                case (_, .awaitHandlers): try tc.event(StageReach.awaitedHandlers)
                case (.served(_, true, _), _): try tc.event(StageReach.servedCancelled)
                default: break
            }
        }

        /// The run's events, result and outcome, once it has ended.
        func checkResult(_ tc: TestCase) throws {
            let kinds = events.compactMap { event -> String? in
                guard case .failure(let error) = event else { return nil }
                return "\(error.phase) \(error)"
            }
            #expect(Set(kinds).count == kinds.count, "a failure event repeated: \(kinds)")
            #expect(events.count(where: isShuttingDown) <= 1, "shuttingDown repeated")
            #expect(events.count(where: isCancelling) <= 1, "cancelling repeated")
            let timeouts = events.compactMap { event -> Duration? in
                guard case .failure(.shutdownTimeout(let after, _, _)) = event else { return nil }
                return after
            }
            #expect(
                timeouts == (model.timedOut.map { [$0] } ?? []),
                "a shutdownTimeout event iff the timeout cancelled the service"
            )

            let parts = Parts(state.result)
            #expect(parts.unavailable == model.unavailable, "unavailable signals in \(parts)")
            #expect(parts.start == model.startFailure, "start failure in \(parts)")
            let started = model.unavailable == nil && model.startFailure == nil
            #expect(parts.timeout == (started ? model.timedOut : nil), "timeout in \(parts)")
            #expect(
                parts.serve == (started ? model.serveFailure : nil),
                "serve failure in \(parts)"
            )
            #expect(parts.stop == (started ? model.stopFailure : nil), "stop failure in \(parts)")
            if parts.serve != nil, parts.stop != nil { try tc.event(StageReach.serveAndStopFailed) }
            if model.startFailure != nil { try tc.event(StageReach.startFailed) }

            #expect((state.lastEvent != nil) == started, "stopped iff the service started")
            guard started else { return }
            let outcome = state.outcome
            #expect(outcome.shutdownReason == model.shutdownReason, "shutdown reason")
            #expect(outcome.cancellationReason == model.cancellationReason, "cancellation reason")
            #expect(
                outcome.stopDuration
                    == model.finishedAt.flatMap { end in model.servedAt.map { end - $0 } },
                "stop duration: from serve returning to the end of dispose"
            )
            #expect(
                outcome.shutdownDuration
                    == model.finishedAt.flatMap { end in model.shutdownAt.map { end - $0 } },
                "shutdown duration: from stage 1 to the end of dispose"
            )
            if let shutdown = outcome.shutdownDuration, let stop = outcome.stopDuration {
                #expect(shutdown >= stop, "stage 1 began after serve returned")
            }
        }

        private func stage(of stage: Lifecycle.Stage) -> Int {
            switch stage {
                case .running: 0
                case .graceful: 1
                case .cancelling: 2
            }
        }
    }

    /// A run's result, taken apart: what it carries, whichever case carries it.
    private struct Parts: CustomStringConvertible {
        var unavailable: [Int32]?
        var start: TestError?
        var timeout: Duration?
        var serve: TestError?
        var stop: TestError?

        init(_ result: Result<ServiceOutcome, ServiceError<TestError>>) {
            guard case .failure(let error) = result else { return }
            switch error {
                case .signalsUnavailable(let signals): unavailable = signals
                case .startFailed(let error): start = error
                case .serveFailed(let error): serve = error
                case .stopFailed(let error): stop = error
                case .serveAndStopFailed(let serve, let stop):
                    (self.serve, self.stop) = (serve, stop)
                case .shutdownTimeout(let after, let serve, let stop):
                    (timeout, self.serve, self.stop) = (after, serve, stop)
            }
        }

        var description: String {
            "unavailable \(unavailable as Any), start \(start as Any), timeout \(timeout as Any), "
                + "serve \(serve as Any), stop \(stop as Any)"
        }
    }

    /// An input as the report shows it, e.g. `served failure at 1.0 seconds`.
    func describe(_ input: Lifecycle.Input) -> String {
        func result(_ result: Result<Void, TestError>) -> String {
            result.failure.map { "failure \($0)" } ?? "success"
        }
        switch input {
            case .signalsUnavailable(let signals): return "signals unavailable \(signals)"
            case .started: return "started"
            case .ready: return "ready"
            case .served(let served, let cancelled, let at):
                return "served \(result(served))\(cancelled ? ", cancelled" : "") at \(at)"
            case .finished(let finished, let at): return "finished \(result(finished)) at \(at)"
            case .signal(let signal, let at): return "signal \(signal) at \(at)"
            case .cancel(let reason): return "cancel: \(reason)"
        }
    }

    private func isSignal(_ event: LifecycleEvent) -> Bool {
        if case .success(.signal) = event { return true }
        return false
    }

    private func isShuttingDown(_ event: LifecycleEvent) -> Bool {
        if case .success(.shuttingDown) = event { return true }
        return false
    }

    private func isCancelling(_ event: LifecycleEvent) -> Bool {
        if case .success(.cancelling) = event { return true }
        return false
    }

    /// Not a stage, a signal or a timeout: the events one input tells.
    private func isTold(_ event: LifecycleEvent) -> Bool {
        switch event {
            case .success(.started), .success(.ready): true
            case .failure(.shutdownTimeout): false
            case .failure: true
            default: false
        }
    }

    extension Result {
        /// The error, if it failed.
        var failure: Failure? {
            if case .failure(let error) = self { return error }
            return nil
        }
    }

#endif
