// Windows's counterpart of Fixture.swift: there is no `posix_spawn` or
// `kill`, and only Ctrl-Break can be sent to a process group of its own.
#if os(Windows)
    import Synchronization
    import WinSDK

    /// A running `ServiceFixture` process, in a process group of its own so
    /// that Ctrl-Break reaches it alone, and the lines it has printed.
    ///
    /// Every wait has a deadline, so a fixture that hangs fails the test
    /// instead of hanging the suite; one still running when this is released
    /// is ended.
    final class Fixture {
        private let process: HANDLE
        private let processID: DWORD
        private let output: HANDLE
        private var pending: [UInt8] = []
        private(set) var lines: [String] = []
        private var outputEnded = false
        private var exited = false

        private init(process: HANDLE, processID: DWORD, output: HANDLE) {
            self.process = process
            self.processID = processID
            self.output = output
        }

        deinit {
            if !exited {
                TerminateProcess(process, 1)
                WaitForSingleObject(process, UInt32.max)
            }
            CloseHandle(process)
            CloseHandle(output)
        }

        /// Whether this process is attached to a console, which Ctrl-Break is
        /// sent through.
        static var hasConsole: Bool {
            var processes: [DWORD] = [0]
            return GetConsoleProcessList(&processes, 1) > 0
        }

        /// Launches the `ServiceFixture` built next to this test binary, with
        /// its standard output piped here; `nil` if it isn't built or can't
        /// start.
        static func launch(_ arguments: [String]) -> Fixture? {
            guard let path = builtExecutable(named: "ServiceFixture.exe") else { return nil }
            // One launch at a time: a fixture launched alongside must not
            // inherit this one's write end, or this one's output would not
            // end until that one did.
            return launching.withLock { _ in spawn(path, arguments) }
        }

        private static func spawn(_ path: String, _ arguments: [String]) -> Fixture? {
            var security = SECURITY_ATTRIBUTES()
            security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
            security.bInheritHandle = true
            var readEnd: HANDLE?
            var writeEnd: HANDLE?
            guard ok(CreatePipe(&readEnd, &writeEnd, &security, 0)), let readEnd, let writeEnd
            else {
                return nil
            }
            // Only the write end is the child's.
            SetHandleInformation(readEnd, DWORD(HANDLE_FLAG_INHERIT), 0)

            var startup = STARTUPINFOW()
            startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
            startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
            startup.hStdOutput = writeEnd
            startup.hStdError = GetStdHandle(STD_ERROR_HANDLE)
            var info = PROCESS_INFORMATION()
            var commandLine = Array("\"\(path)\" \(arguments.joined(separator: " "))".utf16) + [0]
            let created = path.withCString(encodedAs: UTF16.self) { application in
                ok(
                    CreateProcessW(
                        application,
                        &commandLine,
                        nil,
                        nil,
                        true,
                        DWORD(CREATE_NEW_PROCESS_GROUP),
                        nil,
                        nil,
                        &startup,
                        &info
                    )
                )
            }
            CloseHandle(writeEnd)
            guard created, let process = info.hProcess else {
                CloseHandle(readEnd)
                return nil
            }
            CloseHandle(info.hThread)
            return Fixture(process: process, processID: info.dwProcessId, output: readEnd)
        }

        /// Sends Ctrl-Break to the fixture's process group: the fixture alone.
        /// Returns whether it could be sent.
        func sendBreak() -> Bool {
            ok(GenerateConsoleCtrlEvent(DWORD(CTRL_BREAK_EVENT), processID))
        }

        /// Reads output until `line` has been printed; false if the output
        /// ends, or `limit` passes, first.
        func waitFor(_ line: String, within limit: Duration = .seconds(10)) -> Bool {
            let deadline = ContinuousClock.now + limit
            while !lines.contains(line) {
                guard readMore(until: deadline) else { return false }
            }
            return true
        }

        /// Waits for the fixture to end, and returns its exit code; `nil` if
        /// it still runs once `limit` has passed.
        func end(within limit: Duration = .seconds(10)) -> UInt32? {
            let deadline = ContinuousClock.now + limit
            while readMore(until: deadline) {}
            let remaining = max(ContinuousClock.now.duration(to: deadline), .zero)
            guard WaitForSingleObject(process, DWORD(remaining / .milliseconds(1))) == 0 else {
                return nil
            }
            var code: DWORD = 0
            guard ok(GetExitCodeProcess(process, &code)) else { return nil }
            exited = true
            return code
        }

        /// Reads the next output into `lines`; false at its end, or once
        /// `deadline` has passed.
        private func readMore(until deadline: ContinuousClock.Instant) -> Bool {
            guard !outputEnded else { return false }
            var available: DWORD = 0
            while true {
                // Fails once the write end is closed: the fixture has ended.
                guard ok(PeekNamedPipe(output, nil, 0, nil, &available, nil)) else {
                    outputEnded = true
                    return false
                }
                if available > 0 { break }
                guard ContinuousClock.now < deadline else { return false }
                Sleep(10)
            }

            var bytes = [UInt8](repeating: 0, count: 256)
            var count: DWORD = 0
            guard ok(ReadFile(output, &bytes, DWORD(bytes.count), &count, nil)), count > 0 else {
                outputEnded = true
                return false
            }
            pending += bytes[..<Int(count)]
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(
                    String(validating: pending[..<newline], as: UTF8.self) ?? "<not UTF-8>"
                )
                pending.removeSubrange(...newline)
            }
            return true
        }
    }

    /// Held while a fixture is spawned.
    private let launching = Mutex(())

    /// The executable `name` built next to this test binary: the nearest
    /// directory above it that has it.
    private func builtExecutable(named name: String) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 4096)
        let count = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        guard count > 0 else { return nil }
        var directory = String(decoding: buffer[..<count], as: UTF16.self)
        for _ in 0..<5 {
            guard let separator = directory.lastIndex(of: "\\") else { return nil }
            directory = String(directory[..<separator])
            let candidate = directory + "\\" + name
            let attributes = candidate.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
            if attributes != DWORD.max { return candidate }
        }
        return nil
    }

    /// Whether a Windows call succeeded. Swift imports the C `BOOL` it
    /// returns as `Bool` or as `WindowsBool`; this reads either.
    private func ok(_ result: Bool) -> Bool { result }
    private func ok(_ result: WindowsBool) -> Bool { result.boolValue }
#endif
