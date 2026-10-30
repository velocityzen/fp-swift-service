#if os(Linux) || os(Android)
    import Testing

    /// Linux and Android only: there the signals reach their streams
    /// through a pipe, made once per process, so a process with no file
    /// descriptor left can't subscribe to any. (Darwin's Dispatch signal
    /// sources need none.) The `ServiceFixture` runs out of them in a
    /// process of its own.
    @Suite("Out of file descriptors", .timeLimit(.minutes(1)))
    struct FileDescriptorTests {
        @Test("the run fails before acquire and leaves the signals alone; the next run subscribes")
        func outOfFileDescriptors() throws {
            let fixture = try #require(
                Fixture.launch(["nofile"]),
                "ServiceFixture is not built next to the tests"
            )
            #expect(fixture.end() == .exited(0), "output: \(fixture.lines)")
            #expect(
                fixture.lines == [
                    "first: Service could not subscribe to SIGTERM, so it did not start.",
                    "SIGTERM: default",
                    "second: ran",
                ]
            )
        }
    }
#endif
