#if os(Windows)
    import CRT
    import FPService
    import Testing

    /// Stage 3 for real on Windows: the `ServiceFixture` executable, launched
    /// in a process group of its own and sent Ctrl-Break, the one console
    /// event that can be sent to a group. Only the fixture gets it.
    @Suite(
        "Ending the process with Ctrl-Break",
        .timeLimit(.minutes(1)),
        .enabled(if: Fixture.hasConsole, "Ctrl-Break is sent through a console, and there is none")
    )
    struct ConsoleEventTests {
        @Test("a third Ctrl-Break ends the process the way Ctrl-C does")
        func thirdBreak() throws {
            let fixture = try #require(
                Fixture.launch(["\(SIGBREAK)"]),
                "ServiceFixture is not built next to the tests"
            )
            try #require(fixture.waitFor("ready"), "output: \(fixture.lines)")
            try #require(fixture.sendBreak(), "Ctrl-Break could not be sent")
            let shuttingDown = ServiceEvent.shuttingDown(.signal(SIGBREAK)).description
            try #require(fixture.waitFor(shuttingDown), "output: \(fixture.lines)")
            try #require(fixture.sendBreak(), "Ctrl-Break could not be sent")
            // serve was cancelled; dispose never returns
            try #require(fixture.waitFor("disposing"), "output: \(fixture.lines)")
            try #require(fixture.sendBreak(), "Ctrl-Break could not be sent")
            #expect(fixture.end() == 0xC000_013A, "STATUS_CONTROL_C_EXIT; output: \(fixture.lines)")
        }
    }
#endif
