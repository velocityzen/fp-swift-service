@testable import FPService

extension Run {
    /// What any run of `scenario` must do, whatever the interleaving: each
    /// broken rule, described. Empty when the run behaved.
    func violations(of scenario: Scenario) -> [String] {
        var checks = Checks(run: self, scenario: scenario)
        checks.brackets()
        checks.serving()
        checks.events()
        checks.result()
        return checks.broken
    }
}

private struct Checks {
    let run: Run
    let scenario: Scenario
    var broken: [String] = []

    var trace: [String] { run.trace }
    var returned: Int { index("returned") ?? trace.count }
    var acquired: [String] { names("acquired ") }
    var failedAcquire: Bool { trace.contains { $0.hasPrefix("acquire failed ") } }
    var startedAll: Bool { !failedAcquire && acquired.count == scenario.brackets.count }
    var firstDispose: Int { trace.firstIndex { $0.hasPrefix("dispose ") } ?? trace.count }

    mutating func check(_ holds: Bool, _ rule: String) { if !holds { broken.append(rule) } }

    func index(_ line: String) -> Int? { trace.firstIndex(of: line) }

    /// The bracket names of lines starting with `prefix`.
    func names(_ prefix: String) -> [String] {
        trace.filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count).prefix { $0 != " " }) }
            .filter { $0 != "failed" }
    }

    /// Acquired in order, each acquired one disposed once, in reverse, and
    /// nothing left running once the run has returned.
    mutating func brackets() {
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
    mutating func serving() {
        let firstDispose = firstDispose
        if let serve = index("serve") {
            check(startedAll, "served a partial start")
            let served = trace.firstIndex { $0.hasPrefix("served") }
            check(served.map { $0 < firstDispose } ?? false, "disposed before serve returned")
            check(serve < firstDispose, "disposed before serving")
        }
        let cancelled = firstDispose < trace.count && trace[firstDispose].hasSuffix(" cancelled")
        if let handler = index("handler"), handler < firstDispose, !cancelled {
            check(
                (index("handler returned") ?? trace.count) < firstDispose,
                "disposed while a shutdown handler was still running"
            )
        }
    }

    /// The events tell the same story as the trace.
    mutating func events() {
        let events = trace.filter { $0.hasPrefix("event: ") }.map { String($0.dropFirst(7)) }
        guard scenario.observes else {
            check(events.isEmpty, "events with no observer")
            return
        }
        check(events.first == "started", "first event is \(events.first ?? "nothing")")
        check(events.filter { $0 == "started" }.count == 1, "started more than once")
        check(events.filter { $0 == "stopped" }.count <= 1, "stopped more than once")
        check(!events.contains("ready") || startedAll, "ready without every service acquired")
        for event in events where event.hasPrefix("signal ") {
            check(index("send \(event.dropFirst(7))") != nil, "\(event) never sent")
        }
        for line in trace where line.hasPrefix("terminate ") {
            check(trace.contains("send \(line.dropFirst(10))"), "\(line) for a signal never sent")
        }
    }

    /// The result matches what happened.
    mutating func result() {
        let servedFailed = trace.contains("served failed")
        let disposeFailed = trace.contains { $0.hasPrefix("dispose failed ") }
        switch run.result {
            case .success(let outcome):
                check(
                    !failedAcquire && !servedFailed && !disposeFailed,
                    "success despite a failure"
                )
                outcomeReasons(outcome)
            case .failure(.startFailed):
                check(failedAcquire, "start failed, though every acquire succeeded")
            case .failure(let error):
                check(!failedAcquire, "\(error), though start failed")
                switch error {
                    case .serveFailed: check(servedFailed, "serve failed, though it never did")
                    case .stopFailed: check(disposeFailed, "stop failed, though no dispose did")
                    case .serveAndStopFailed:
                        check(servedFailed && disposeFailed, "serve and stop failed")
                    case .shutdownTimeout:
                        check(scenario.shutdownTimeout != nil, "timed out with no timeout")
                    case .signalsUnavailable, .startFailed: check(false, "\(error)")
                }
        }
    }

    private mutating func outcomeReasons(_ outcome: ServiceOutcome) {
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
