// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    @testable import FPService
    import Testing

    extension Run {
        /// Checks what any run of `scenario` must do, whatever the interleaving.
        /// Each rule is its own expectation, at its own line, so each broken rule
        /// is its own failure, shrunk on its own.
        func check(against scenario: Scenario) {
            let checks = Checks(run: self, scenario: scenario)
            checks.subscribing()
            checks.brackets()
            checks.serving()
            checks.handlers()
            checks.stageTwo()
            checks.events()
            checks.result()
            checks.timeout()
        }
    }

    private struct Checks {
        let run: Run
        let scenario: Scenario

        var trace: [String] { run.trace }
        var returned: Int { index("returned") ?? trace.count }
        var acquired: [String] { names("acquired ") }
        var failedAcquire: Bool { trace.contains { $0.hasPrefix("acquire failed ") } }
        var startedAll: Bool { !failedAcquire && acquired.count == scenario.brackets.count }
        var firstDispose: Int { trace.firstIndex { $0.hasPrefix("dispose ") } ?? trace.count }
        /// Where the bracket call returned: its last dispose ended, or acquire failed.
        var bracketReturned: Int? {
            trace.lastIndex { line in
                ["disposed ", "dispose failed ", "acquire failed "].contains { line.hasPrefix($0) }
            }
        }
        /// A dispose beginning: `dispose a`, or `dispose a cancelled`.
        func isDisposeStart(_ line: String) -> Bool {
            line.hasPrefix("dispose ") && !line.hasPrefix("dispose failed ")
        }

        var observed: [String] {
            trace.filter { $0.hasPrefix("event: ") }.map { String($0.dropFirst(7)) }
        }

        func check(
            _ holds: Bool,
            _ rule: @autoclosure () -> String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            #expect(holds, Comment(rawValue: rule()), sourceLocation: sourceLocation)
        }

        func index(_ line: String) -> Int? { trace.firstIndex(of: line) }

        /// The bracket names of lines starting with `prefix`.
        func names(_ prefix: String) -> [String] {
            trace.filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count).prefix { $0 != " " }) }
                .filter { $0 != "failed" }
        }

        /// The service subscribes to its shutdown signals once, before anything
        /// else runs; with one unavailable, nothing runs at all, and the run
        /// fails saying which (checked in `result`).
        func subscribing() {
            check(
                trace.filter { $0.hasPrefix("subscribe ") } == [
                    "subscribe \(scenario.shutdownSignals)"
                ],
                "subscribed \(trace.filter { $0.hasPrefix("subscribe ") })"
            )
            check(
                !trace.prefix { !$0.hasPrefix("subscribe ") }.contains { line in
                    ["acquire", "serve", "event: "].contains { line.hasPrefix($0) }
                },
                "ran before subscribing"
            )
            guard !scenario.unavailable.isEmpty else { return }
            check(
                !trace.contains { line in
                    ["acquire", "serve", "dispose", "handler"].contains { line.hasPrefix($0) }
                },
                "ran with \(scenario.unavailable) unavailable"
            )
        }

        /// Acquired in order, each acquired one disposed once, in reverse, and
        /// nothing left running once the run has returned.
        func brackets() {
            let acquires = names("acquire ")
            check(
                acquires.elementsEqual(scenario.brackets.map(\.name).prefix(acquires.count)),
                "acquired out of order: \(acquires)"
            )
            check(
                acquires.count == acquired.count + (failedAcquire ? 1 : 0),
                "acquired after a failed acquire"
            )
            let disposes = names("dispose ")
            check(disposes == acquired.reversed(), "disposed \(disposes), acquired \(acquired)")
            let ends = trace.filter { $0.hasPrefix("disposed ") || $0.hasPrefix("dispose failed ") }
            check(ends.count == disposes.count, "a dispose did not finish")
            check(
                !trace[returned...].contains { line in
                    ["acquire", "dispose", "serve", "handler"].contains { line.hasPrefix($0) }
                },
                "work still running after the run returned"
            )
        }

        /// Serve runs on everything acquired and returns before any dispose;
        /// shutdown handlers finish first too, unless stopping was cancelled.
        func serving() {
            let firstDispose = firstDispose
            if let serve = index("serve") {
                check(startedAll, "served a partial start")
                let served = trace.firstIndex { $0.hasPrefix("served") }
                check(served.map { $0 < firstDispose } ?? false, "disposed before serve returned")
                check(serve < firstDispose, "disposed before serving")
            }
            // Stage 2 stops the wait for the handlers: in the simulation only
            // sleeps take time, so dispose begins at the instant of the cancel
            // or of serve returning, whichever is later. The observer records
            // the cancel at its instant.
            if let served = trace.firstIndex(where: { $0.hasPrefix("served") }),
                let cancel = trace.firstIndex(where: { $0.hasPrefix("event: cancelling") }),
                firstDispose < trace.count
            {
                check(
                    run.times[firstDispose] <= max(run.times[served], run.times[cancel]),
                    "dispose began at \(run.times[firstDispose]), after stage 2 at "
                        + "\(run.times[cancel]) and serve returning at \(run.times[served])"
                )
            }
            // Every phase is finite, so only a serve waiting for a shutdown
            // or a cancel that never came is still running at the backstop.
            if let backstop = index("backstop") {
                check(
                    (index("serve") ?? trace.count) < backstop
                        && !trace[..<backstop].contains { $0.hasPrefix("served") },
                    "still running at the backstop, though not serving"
                )
            }
        }

        /// The events tell the same story as the trace.
        func events() {
            let events = observed
            guard scenario.observes else {
                check(events.isEmpty, "events with no observer")
                return
            }
            guard scenario.unavailable.isEmpty else {
                check(
                    events == ["failed: signalsUnavailable"],
                    "events \(events), signals unavailable"
                )
                return
            }
            check(events.first == "started", "first event is \(events.first ?? "nothing")")
            check(events.filter { $0 == "started" }.count == 1, "started more than once")
            check(events.filter { $0 == "stopped" }.count <= 1, "stopped more than once")
            check(!events.contains("ready") || startedAll, "ready without every service acquired")
            // Each failure is told once, as it happens, and the stream ends
            // with `stopped` for a service that started, even once the caller
            // has cancelled: the cancel doesn't reach the observer.
            func told(_ failure: String) -> Int { events.count { $0 == "failed: \(failure)" } }
            func once(_ count: Int, if expected: Bool) -> Bool { count == (expected ? 1 : 0) }
            check(
                once(told("startFailed"), if: failedAcquire),
                "start failure told \(told("startFailed")) times"
            )
            check(
                once(told("serveFailed"), if: trace.contains("served failed")),
                "serve failure told \(told("serveFailed")) times"
            )
            let disposeFailed = trace.contains { $0.hasPrefix("dispose failed ") }
            check(
                once(told("stopFailed"), if: events.contains("ready") && disposeFailed),
                "stop failure told \(told("stopFailed")) times"
            )
            // A start failure wins the result over a timeout that came first.
            var timedOut = false
            if case .failure(.shutdownTimeout) = run.result { timedOut = true }
            check(
                once(told("shutdownTimeout"), if: timedOut)
                    || failedAcquire && told("shutdownTimeout") <= 1,
                "timeout told \(told("shutdownTimeout")) times"
            )
            if failedAcquire {
                check(
                    !events.contains { $0.hasPrefix("stopped") },
                    "stopped, though it never started"
                )
            } else {
                check(
                    events.last?.hasPrefix("stopped") == true,
                    "last event is \(events.last ?? "nothing")"
                )
            }
            for event in events where event.hasPrefix("signal ") {
                check(index("send \(event.dropFirst(7))") != nil, "\(event) never sent")
            }
            for line in trace where line.hasPrefix("terminate ") {
                check(
                    trace.contains("send \(line.dropFirst(10))"),
                    "\(line) for a signal never sent"
                )
            }
        }

        /// The result matches what happened.
        func result() {
            let servedFailed = trace.contains("served failed")
            let disposeFailed = trace.contains { $0.hasPrefix("dispose failed ") }
            if !scenario.unavailable.isEmpty {
                guard case .failure(.signalsUnavailable) = run.result else {
                    return check(
                        false,
                        "\(run.result), though \(scenario.unavailable) are unavailable"
                    )
                }
            }
            switch run.result {
                case .success(let outcome):
                    check(
                        !failedAcquire && !servedFailed && !disposeFailed,
                        "success despite a failure"
                    )
                    outcomeReasons(outcome)
                    durations(outcome)
                case .failure(.signalsUnavailable(let signals)):
                    check(
                        signals == scenario.unavailable,
                        "\(signals) unavailable, not \(scenario.unavailable)"
                    )
                case .failure(.startFailed):
                    check(failedAcquire, "start failed, though every acquire succeeded")
                case .failure(let error):
                    check(!failedAcquire, "\(error), though start failed")
                    switch error {
                        case .serveFailed:
                            check(servedFailed, "serve failed, though it never did")
                            check(!disposeFailed, "serve failed, and a dispose too")
                        case .stopFailed:
                            check(disposeFailed, "stop failed, though no dispose did")
                            check(!servedFailed, "stop failed, and serve too")
                        case .serveAndStopFailed:
                            check(servedFailed && disposeFailed, "serve and stop failed")
                        case .shutdownTimeout(let after, let serve, let stop):
                            check(after == scenario.shutdownTimeout, "timed out after \(after)")
                            check(
                                (serve != nil) == servedFailed,
                                "timed out, serve failure \(String(describing: serve))"
                            )
                            check(
                                (stop != nil) == disposeFailed,
                                "timed out, stop failure \(String(describing: stop))"
                            )
                        case .signalsUnavailable, .startFailed: check(false, "\(error)")
                    }
            }
        }

        private func outcomeReasons(_ outcome: ServiceOutcome) {
            switch outcome.shutdownReason {
                case .signal(let signal)?:
                    check(trace.contains("send \(signal)"), "shut down by \(signal), never sent")
                case .serveReturned?:
                    check(trace.contains("served"), "shut down by serve, which never returned")
                case nil: break
            }
            if case .caller? = outcome.cancellationReason {
                check(trace.contains("cancel caller"), "cancelled by a caller that never cancelled")
            }
        }
    }

    // What Stopping.md claims about handlers, stage 2 and the timeout, and the
    // outcome's durations.
    extension Checks {
        /// The shutdown handlers registered when shutdown is requested each
        /// run once, in registration order, and return in that order, as they
        /// run one after the other on the request's thread; dispose waits for
        /// all of them unless stage 2 came first. (Under simulation a handler
        /// that blocks returns at once and its thread stays busy after, so the
        /// next one is recorded as starting before it is recorded as
        /// returning.)
        func handlers() {
            guard case .handlers(let blocks, _) = scenario.body else { return }
            let started = blocks.indices.map { index("handler \($0)") }
            let ended = blocks.indices.map { index("handler \($0) returned") }
            for handler in blocks.indices {
                check(
                    trace.count { $0 == "handler \(handler)" } <= 1,
                    "handler \(handler) ran more than once"
                )
            }
            // All are registered while serve waits for the request, and
            // removed only once it has come.
            check(
                started.allSatisfy { $0 == nil } || started.allSatisfy { $0 != nil },
                "only some handlers ran: \(started)"
            )
            let starts = started.compactMap(\.self)
            check(starts == starts.sorted(), "handlers ran out of order: \(starts)")
            let ends = ended.compactMap(\.self)
            check(ends == ends.sorted(), "handlers returned out of order: \(ends)")
            let cancelled =
                firstDispose < trace.count && trace[firstDispose].hasSuffix(" cancelled")
            if let first = started.first, let first, first < firstDispose, !cancelled {
                check(
                    ended.allSatisfy { ($0 ?? trace.count) < firstDispose },
                    "disposed while a shutdown handler was still running"
                )
            }
        }

        /// In stage 2, dispose runs in a cancelled task (Stopping.md): a
        /// dispose that begins after stage 2 began is cancelled, and one is
        /// cancelled only in a run that reached stage 2.
        func stageTwo() {
            guard scenario.observes else { return }
            let stageTwo = trace.firstIndex { $0.hasPrefix("event: cancelling") }
            for (line, entry) in trace.enumerated() where isDisposeStart(entry) {
                let cancelled = entry.hasSuffix(" cancelled")
                if let stageTwo, stageTwo < line {
                    check(cancelled, "\(entry), not cancelled, though stage 2 began before it")
                }
                if cancelled {
                    check(stageTwo != nil, "\(entry), though the run never reached stage 2")
                }
            }
        }

        /// A stop that outlasts `shutdownTimeout` fails with `shutdownTimeout`
        /// (Stopping.md), unless stage 2 began first some other way or start
        /// failed; and a run times out only once its stop has lasted that
        /// long. Timed from the observer's `shuttingDown`, recorded at its
        /// instant, as only sleeps take time.
        func timeout() {
            guard scenario.observes, let limit = scenario.shutdownTimeout,
                let graceful = trace.firstIndex(where: { $0.hasPrefix("event: shutting down") }),
                let returned = bracketReturned
            else { return }
            let deadline = run.times[graceful] + limit
            var timedOut = false
            if case .failure(.shutdownTimeout) = run.result { timedOut = true }
            if timedOut {
                check(run.times[returned] >= deadline, "timed out, though the stop ended in time")
            }
            let cancelledFirst = trace.indices.contains { line in
                trace[line].hasPrefix("event: cancelling")
                    && !trace[line].contains("shutdownTimeout") && run.times[line] <= deadline
            }
            if run.times[returned] > deadline, !cancelledFirst, !failedAcquire {
                check(timedOut, "the stop outlasted \(limit), and the run returned \(run.result)")
            }
        }

        /// The outcome's durations, on the simulated clock: the stop from serve
        /// returning, the shutdown from the first signal or serve returning,
        /// whichever began it, each to the end of dispose.
        func durations(_ outcome: ServiceOutcome) {
            guard let returned = bracketReturned else {
                return check(false, "succeeded, though the bracket never returned")
            }
            let end = run.times[returned]
            let served = trace.firstIndex { $0.hasPrefix("served") }
            check(
                outcome.stopDuration == served.map { end - run.times[$0] },
                "stopped in \(String(describing: outcome.stopDuration))"
            )
            let firstSend = trace.firstIndex { $0.hasPrefix("send ") }
            let began: Int? =
                switch outcome.shutdownReason {
                    case .signal(let signal)?:
                        firstSend.flatMap { trace[$0] == "send \(signal)" ? $0 : nil }
                    case .serveReturned?: served
                    case nil: nil
                }
            if outcome.shutdownReason != nil {
                check(
                    began != nil,
                    "shut down by \(outcome.shutdownReason!), not the first to come"
                )
            }
            check(
                outcome.shutdownDuration == began.map { end - run.times[$0] },
                "shut down in \(String(describing: outcome.shutdownDuration))"
            )
        }
    }

#endif
