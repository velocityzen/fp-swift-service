#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import FPService
import Testing

/// Stage 3 for real: the `ServiceFixture` executable, launched and signalled
/// the way a service manager would. Only the fixture gets the signals; this
/// process's dispositions are never touched.
///
/// SIGWINCH's default action ignores it, so it ends the process with exit
/// status 128 + the signal instead.
@Suite("Ending the process", .timeLimit(.minutes(1)))
struct EndingTests {
    @Test(
        "a third signal ends the process the way that signal ends it",
        arguments: zip(
            [SIGTERM, SIGWINCH],
            [Ending.killed(by: SIGTERM), .exited(128 + SIGWINCH)]
        )
    )
    func thirdSignal(_ signal: Int32, ending: Ending) throws {
        try expectThirdSignal(signal, toEnd: ending)
    }

    /// Ending the process flushes its output, which must not wait forever.
    @Test(
        "a third signal ends the process even when its output is stuck",
        arguments: zip(
            [SIGTERM, SIGWINCH],
            [Ending.killed(by: SIGTERM), .exited(128 + SIGWINCH)]
        )
    )
    func stalledOutput(_ signal: Int32, ending: Ending) throws {
        try expectThirdSignal(signal, toEnd: ending, stall: true)
    }
}

/// Launches the fixture and sends it `signal` three times, each once the
/// one before has had its effect; expects the process to end as `ending`.
private func expectThirdSignal(_ signal: Int32, toEnd ending: Ending, stall: Bool = false) throws {
    let fixture = try #require(
        Fixture.launch(["\(signal)"] + (stall ? ["stall"] : [])),
        "ServiceFixture is not built next to the tests"
    )
    try #require(fixture.waitFor("ready"), "output: \(fixture.lines)")
    fixture.send(signal)
    let shuttingDown = ServiceEvent.shuttingDown(.signal(signal)).description
    try #require(fixture.waitFor(shuttingDown), "output: \(fixture.lines)")
    fixture.send(signal)
    // serve was cancelled; dispose never returns
    try #require(fixture.waitFor("disposing"), "output: \(fixture.lines)")
    fixture.send(signal)
    #expect(fixture.end() == ending, "output: \(fixture.lines)")
}
