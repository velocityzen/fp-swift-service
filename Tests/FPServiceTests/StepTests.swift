#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
@testable import FPService
import Testing

private typealias Run = ServiceRun<TestError>

/// The stage machine on its own: from a state, one input, to the events, the
/// effect and the stage it gives. No tasks, clocks or signals.
@Suite("Stage machine")
struct StepTests {
    @Test(arguments: steps)
    fileprivate func step(_ row: StepRow) {
        var state = row.state
        let step = state.step(row.input)
        #expect(step.events.map(describe) == row.events)
        #expect(step.effect == row.effect)
        #expect(state.stage == row.stage)
    }

    @Test(arguments: results)
    fileprivate func result(_ row: ResultRow) {
        #expect(row.state.result == row.result)
    }

    @Test("only a service that started ends with stopped")
    func lastEvent() {
        #expect(Run.State().lastEvent.map(describe) == "stopped")
        #expect(Run.State(startFailure: .boom("start")).lastEvent == nil)
        #expect(Run.State(unavailableSignals: [SIGKILL]).lastEvent == nil)
    }
}

private let running = Run.State()
private let graceful = Run.State(stage: .graceful, ready: true)
private let cancelling = Run.State(stage: .cancelling, ready: true)
private let returned = Run.State(stage: .graceful, ready: true, finished: true)

private let steps: [StepRow] = [
    StepRow(
        "a signal while running begins stage 1",
        running,
        .signal(SIGTERM),
        events: ["signal 15", "shutting down: signal 15"],
        effect: .graceful,
        stage: .graceful
    ),
    StepRow(
        "a signal in stage 1 begins stage 2",
        graceful,
        .signal(SIGINT),
        events: ["signal 2", "cancelling: signal 2"],
        effect: .cancel,
        stage: .cancelling
    ),
    StepRow(
        "a signal in stage 2 ends the process",
        cancelling,
        .signal(SIGTERM),
        events: ["signal 15"],
        effect: .kill(SIGTERM),
        stage: .cancelling
    ),
    StepRow(
        "a signal after the bracket returned is only an event",
        returned,
        .signal(SIGTERM),
        events: ["signal 15"],
        effect: .none,
        stage: .graceful
    ),
    StepRow(
        "serve returning begins stage 1",
        Run.State(ready: true),
        .served(.success(()), cancelled: false, at: .zero),
        events: ["shutting down: serve returned"],
        effect: .graceful,
        stage: .graceful
    ),
    StepRow(
        "a serve failure comes before stage 1",
        Run.State(ready: true),
        .served(.failure(.boom("serve")), cancelled: false, at: .zero),
        events: ["failed: serve", "shutting down: serve returned"],
        effect: .graceful,
        stage: .graceful
    ),
    StepRow(
        "serve returning in stage 1 changes no stage",
        graceful,
        .served(.success(()), cancelled: false, at: .zero),
        events: [],
        effect: .none,
        stage: .graceful
    ),
    StepRow(
        "a cancelled serve never begins stage 1",
        Run.State(ready: true),
        .served(.success(()), cancelled: true, at: .zero),
        events: [],
        effect: .none,
        stage: .running
    ),
    StepRow(
        "the timeout begins stage 2, and is a failure",
        graceful,
        .cancel(.shutdownTimeout(after: .seconds(5))),
        events: ["cancelling: shutdown timeout", "failed: shutdown timeout"],
        effect: .cancel,
        stage: .cancelling
    ),
    StepRow(
        "the caller cancelling while running begins stage 2",
        running,
        .cancel(.caller),
        events: ["cancelling: caller"],
        effect: .cancel,
        stage: .cancelling
    ),
    StepRow(
        "cancelling again in stage 2 changes nothing",
        cancelling,
        .cancel(.caller),
        events: [],
        effect: .none,
        stage: .cancelling
    ),
    StepRow(
        "cancelling after the bracket returned changes nothing",
        returned,
        .cancel(.shutdownTimeout(after: .seconds(5))),
        events: [],
        effect: .none,
        stage: .graceful
    ),
    StepRow(
        "a failure before ready is acquire's",
        running,
        .finished(.failure(.boom("start")), at: .zero),
        events: ["failed: start"],
        effect: .none,
        stage: .running
    ),
    StepRow(
        "a failure after ready is dispose's",
        graceful,
        .finished(.failure(.boom("stop")), at: .zero),
        events: ["failed: stop"],
        effect: .none,
        stage: .graceful
    ),
    StepRow(
        "unavailable shutdown signals are a failure",
        running,
        .signalsUnavailable([SIGKILL]),
        events: ["failed: signals unavailable [9]"],
        effect: .none,
        stage: .running
    ),
]

private let results: [ResultRow] = [
    ResultRow(
        "a clean run's outcome measures the stop",
        Run.State(
            stage: .graceful,
            shutdownReason: .serveReturned,
            ready: true,
            finished: true,
            stopBegan: .seconds(1),
            stopEnded: .seconds(3)
        ),
        .success(
            ServiceOutcome(
                shutdownReason: .serveReturned,
                cancellationReason: nil,
                stopDuration: .seconds(2)
            )
        )
    ),
    ResultRow(
        "unavailable signals: nothing ran",
        Run.State(unavailableSignals: [SIGKILL]),
        .failure(.signalsUnavailable([SIGKILL]))
    ),
    ResultRow(
        "a start failure comes before a timeout",
        Run.State(startFailure: .boom("start"), timedOut: .seconds(5)),
        .failure(.startFailed(.boom("start")))
    ),
    ResultRow(
        "a timeout carries the serve and dispose failures",
        Run.State(serveFailure: .boom("serve"), stopFailure: .boom("stop"), timedOut: .seconds(5)),
        .failure(.shutdownTimeout(after: .seconds(5), serve: .boom("serve"), stop: .boom("stop")))
    ),
    ResultRow(
        "serve and dispose failures are both kept",
        Run.State(serveFailure: .boom("serve"), stopFailure: .boom("stop")),
        .failure(.serveAndStopFailed(serve: .boom("serve"), stop: .boom("stop")))
    ),
    ResultRow(
        "a serve failure",
        Run.State(serveFailure: .boom("serve")),
        .failure(.serveFailed(.boom("serve")))
    ),
    ResultRow(
        "a dispose failure",
        Run.State(stopFailure: .boom("stop")),
        .failure(.stopFailed(.boom("stop")))
    ),
]

/// From `state`, `input` gives these events, effect and stage.
private struct StepRow: Sendable, CustomTestStringConvertible {
    let name: String
    let state: Run.State
    let input: Run.Input
    let events: [String]
    let effect: Run.Effect
    let stage: Run.Stage

    init(
        _ name: String,
        _ state: Run.State,
        _ input: Run.Input,
        events: [String],
        effect: Run.Effect,
        stage: Run.Stage
    ) {
        self.name = name
        self.state = state
        self.input = input
        self.events = events
        self.effect = effect
        self.stage = stage
    }

    var testDescription: String { name }
}

/// `state` at the end of a run gives `result`.
private struct ResultRow: Sendable, CustomTestStringConvertible {
    let name: String
    let state: Run.State
    let result: Result<ServiceOutcome, ServiceError<TestError>>

    init(
        _ name: String,
        _ state: Run.State,
        _ result: Result<ServiceOutcome, ServiceError<TestError>>
    ) {
        self.name = name
        self.state = state
        self.result = result
    }

    var testDescription: String { name }
}
