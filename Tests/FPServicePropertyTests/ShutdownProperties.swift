// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import FPService
    import HegelTesting
    import Synchronization
    import Testing

    /// How `serve` reacts to shutdown: `withCancellation(on:_:)` and
    /// `withShutdownHandler(on:_:operation:)`.
    @Suite(.hegel)
    struct ShutdownProperties {
        /// The result is always the operation's own, and the call returns
        /// only once the operation has. The operation is cancelled only if
        /// shutdown was requested or the caller cancelled before it returned,
        /// and then it is: an operation that waits for its cancellation ends.
        ///
        /// Shutdown is requested before the call, at a drawn step of the
        /// operation, or never; the caller is cancelled at a drawn step. An
        /// operation that has requested shutdown waits to be cancelled, so a
        /// cancel that never comes is a stall. (One requested before the call
        /// may still finish first: the operation starts before the call sees
        /// the request.)
        @Test(.hegel(testCases: 500))
        func withCancellationReturnsTheOperationsResult() async throws {
            try await property(reaching: CancellationReach.all) { tc in
                let work = try tc.draw(ShutdownGen.work, named: "work")
                let shutdown = Shutdown()
                if work.requestAt == .before { shutdown.request() }
                let log = Log()
                let run = try await tc.withRandomCancellation(
                    checkpoints: 0...work.steps,
                    endsWithin: stallLimit,
                    stallsAfter: stallLimit
                ) { cancellation in
                    let result = await withCancellation(on: shutdown) {
                        await work.run(shutdown, log) { cancellation.checkpoint("step \($0)") }
                    }
                    log.append("call returned")
                    return result
                }

                let trace = log.all
                let returned = try #require(trace.firstIndex { $0.hasPrefix("returned ") })
                #expect(
                    run.value == work.result(in: trace[returned]),
                    "the result isn't the operation's"
                )
                #expect(
                    trace.last == "call returned",
                    "the call returned before the operation: \(trace)"
                )
                let sawCancel = trace[returned].hasSuffix("cancelled")
                let cancelSent = shutdown.isRequested || run.cancelledAt != nil
                #expect(!sawCancel || cancelSent, "cancelled with no shutdown or caller cancel")
                // The caller's cancel reaches the operation: a cancel at a
                // checkpoint, or before a call with a step to take, is seen
                // by the step after it.
                if let at = run.cancelledAt, at > 0 || work.steps > 0 {
                    #expect(sawCancel, "the caller cancelled at checkpoint \(at), unseen")
                }
                if sawCancel {
                    try tc.event(
                        shutdown.isRequested
                            ? CancellationReach.byShutdown : CancellationReach.byCaller
                    )
                }
                if !cancelSent { try tc.event(CancellationReach.uncancelled) }
            }
        }

        /// The handler runs once if shutdown is requested before the
        /// operation returns: at once if it already was, else inside the
        /// request. Requested after the operation returned, it never runs.
        @Test(.hegel(testCases: 500))
        func shutdownHandlerRunsOnlyWhileRegistered() async throws {
            try await property(reaching: ["handler ran", "handler removed"]) { tc in
                let work = try tc.draw(ShutdownGen.work, named: "work")
                let shutdown = Shutdown()
                let log = Log()
                if work.requestAt == .before { shutdown.request() }
                _ = await withShutdownHandler(
                    on: shutdown,
                    { log.append("handler") },
                    operation: {
                        log.append("operation")
                        return await work.run(shutdown, log, waitingToBeCancelled: false) { _ in }
                    }
                )
                if work.requestAt == .after { shutdown.request() }

                let trace = log.all
                let handlers = trace.count { $0 == "handler" }
                #expect(handlers <= 1, "the handler ran \(handlers) times")
                switch work.requestAt {
                    case .before:
                        #expect(trace.first == "handler", "not run at once: \(trace)")
                    case .step(let step) where step < work.steps:
                        let request = try #require(trace.firstIndex(of: "request \(step)"))
                        #expect(
                            trace[request + 1] == "handler",
                            "not run inside the request: \(trace)"
                        )
                    default:
                        #expect(handlers == 0, "ran with the operation over: \(trace)")
                        if work.requestAt == .after { try tc.event("handler removed") }
                }
                if handlers == 1 { try tc.event("handler ran") }
            }
        }
    }

    enum CancellationReach {
        static let byShutdown = "cancelled by shutdown"
        static let byCaller = "cancelled by the caller"
        static let uncancelled = "neither came"

        static let all = [byShutdown, byCaller, uncancelled]
    }

    /// How long an operation may go without a step, or take to end once
    /// cancelled.
    let stallLimit = Duration.seconds(10)

    /// An operation: some steps, each a suspension, that stops at the first
    /// step that finds its task cancelled; one step may request shutdown and
    /// then wait to be cancelled. Its result says how it ended.
    struct Work: Sendable, CustomStringConvertible {
        enum Request: Sendable, Equatable {
            case before
            case step(Int)
            case after
            case never
        }

        var steps: Int
        var requestAt: Request
        var fails: Bool

        var description: String { "\(steps) steps, request \(requestAt), fails \(fails)" }

        /// Runs it, recording each step, the request, and how it returned.
        /// After its request, it waits to be cancelled, unless
        /// `waitingToBeCancelled` is false: nothing cancels it then.
        @concurrent
        func run(
            _ shutdown: Shutdown,
            _ log: Log,
            waitingToBeCancelled: Bool = true,
            checkpoint: @Sendable (Int) -> Void
        ) async -> Result<String, TestError> {
            var how = "finished"
            for step in 0..<steps {
                if requestAt == .step(step) {
                    log.append("request \(step)")
                    shutdown.request()
                    // A shutdown never requested: returns once cancelled.
                    if waitingToBeCancelled { await Shutdown().requested }
                }
                checkpoint(step + 1)
                if Task.isCancelled {
                    how = "cancelled"
                    break
                }
                await Task.yield()
            }
            log.append("returned \(how)")
            return result(in: "returned \(how)")
        }

        /// The result an operation that recorded `line` returned.
        func result(in line: String) -> Result<String, TestError> {
            fails ? .failure(.boom(line)) : .success(line)
        }
    }

    enum ShutdownGen {
        static let work: Gen<Work> = Gen { tc in
            let steps = try tc.draw(.oneOf(.int(in: 0...3), .int(in: 0...20)))
            let request: Gen<Work.Request> = .oneOf(
                .just(.never),
                .element(of: [.before, .after]),
                Gen.int(in: 0...max(steps - 1, 0)).map { .step($0) }
            )
            return Work(steps: steps, requestAt: try tc.draw(request), fails: try tc.draw(.bool()))
        }
    }

#endif
