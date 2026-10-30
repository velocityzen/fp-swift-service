// macOS, Linux and Android only: the simulators can't launch the fixture,
// and tvOS and watchOS have no `posix_spawn`.
#if os(macOS) || os(Linux) || os(Android)
    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Glibc)
        import Glibc
    #elseif canImport(Musl)
        import Musl
    #elseif canImport(Android)
        import Android
    #endif
    import Synchronization

    /// How a process ended.
    enum Ending: Equatable, Sendable {
        case exited(Int32)
        case killed(by: Int32)
    }

    /// A running `ServiceFixture` process, and the lines it has printed.
    ///
    /// Every wait has a deadline, so a fixture that hangs fails the test instead
    /// of hanging the suite; one still running when this is released is killed.
    final class Fixture {
        private let pid: pid_t
        private let output: Int32
        private var pending: [UInt8] = []
        private(set) var lines: [String] = []
        private var outputEnded = false
        private var reaped = false

        private init(pid: pid_t, output: Int32) {
            self.pid = pid
            self.output = output
        }

        deinit {
            if !reaped {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                waitpid(pid, &status, 0)
            }
            close(output)
        }

        /// Launches the `ServiceFixture` built next to this test bundle, with its
        /// standard output piped here; `nil` if it isn't built or can't start.
        static func launch(_ arguments: [String]) -> Fixture? {
            guard let path = builtExecutable(named: "ServiceFixture") else { return nil }
            // One launch at a time: a fixture launched alongside must not inherit
            // this one's write end, or this one's output would not end until that
            // one did.
            guard let (pid, output) = launching.withLock({ _ in spawn(path, arguments) }) else {
                return nil
            }
            return Fixture(pid: pid, output: output)
        }

        /// Spawns `path` with its standard output on a new pipe; returns its pid
        /// and the pipe's read end.
        ///
        /// The process starts with no signals blocked and every default action
        /// restored: the thread this runs on blocks signals, and this process
        /// may hold some, and a child would inherit both.
        private static func spawn(_ path: String, _ arguments: [String]) -> (pid_t, Int32)? {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { return nil }
            // Both ends close on exec; the child's standard output is a copy.
            for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }

            // Storage for `init` to fill: on Android it holds a pointer
            // declared non-null, so it can't start out as a `nil` variable.
            let actions = UnsafeMutablePointer<SpawnFileActions>.allocate(capacity: 1)
            defer { actions.deallocate() }
            let attributes = UnsafeMutablePointer<SpawnAttributes>.allocate(capacity: 1)
            defer { attributes.deallocate() }

            nullable(actions) { posix_spawn_file_actions_init($0) }
            defer { posix_spawn_file_actions_destroy(actions) }
            posix_spawn_file_actions_adddup2(actions, ends[1], STDOUT_FILENO)

            nullable(attributes) { posix_spawnattr_init($0) }
            defer { posix_spawnattr_destroy(attributes) }
            var none = sigset_t()
            sigemptyset(&none)
            posix_spawnattr_setsigmask(attributes, &none)
            var all = sigset_t()
            sigfillset(&all)
            sigdelset(&all, SIGKILL)
            sigdelset(&all, SIGSTOP)
            posix_spawnattr_setsigdefault(attributes, &all)
            posix_spawnattr_setflags(
                attributes,
                Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
            )

            let argv: [UnsafeMutablePointer<CChar>?] =
                ([path] + arguments).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            let environment: [UnsafeMutablePointer<CChar>?] = [nil]
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, path, actions, attributes, argv, environment)
            close(ends[1])
            guard spawned == 0 else {
                close(ends[0])
                return nil
            }
            return (pid, ends[0])
        }

        /// Sends `signal` to the fixture.
        func send(_ signal: Int32) {
            kill(pid, signal)
        }

        /// Reads output until `line` has been printed; false if the output ends,
        /// or `limit` passes, first.
        func waitFor(_ line: String, within limit: Duration = .seconds(10)) -> Bool {
            let deadline = ContinuousClock.now + limit
            while !lines.contains(line) {
                guard readMore(until: deadline) else { return false }
            }
            return true
        }

        /// Waits for the fixture to end, and returns how it did; `nil` if it
        /// still runs once `limit` has passed.
        func end(within limit: Duration = .seconds(10)) -> Ending? {
            let deadline = ContinuousClock.now + limit
            while readMore(until: deadline) {}
            // Its output ends when it does, unless the deadline came first.
            guard outputEnded else { return nil }
            var status: Int32 = 0
            guard waitpid(pid, &status, 0) == pid else { return nil }
            reaped = true
            let signal = status & 0x7f
            return signal == 0 ? .exited((status >> 8) & 0xff) : .killed(by: signal)
        }

        /// Reads the next output into `lines`; false at its end, or once
        /// `deadline` has passed.
        private func readMore(until deadline: ContinuousClock.Instant) -> Bool {
            guard !outputEnded else { return false }
            var ready: Int32
            repeat {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { return false }
                var request = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
                ready = poll(&request, 1, Int32(remaining / .milliseconds(1)) + 1)
            } while ready < 0 && errno == EINTR
            guard ready > 0 else { return false }

            var bytes = [UInt8](repeating: 0, count: 256)
            var count: Int
            repeat {
                count = read(output, &bytes, bytes.count)
            } while count < 0 && errno == EINTR
            guard count > 0 else {
                outputEnded = true
                return false
            }
            pending += bytes[..<count]
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

    // What `posix_spawn` takes its file actions and attributes in: a struct
    // with glibc and musl, a pointer that `init` sets elsewhere (and on
    // Darwin, one the headers let be `nil`).
    #if canImport(Darwin)
        private typealias SpawnFileActions = posix_spawn_file_actions_t?
        private typealias SpawnAttributes = posix_spawnattr_t?
    #else
        private typealias SpawnFileActions = posix_spawn_file_actions_t
        private typealias SpawnAttributes = posix_spawnattr_t
    #endif

    #if canImport(Android)
        /// Calls `body` with `pointer`'s memory seen as `Optional`, which has
        /// the same layout. On Android each `init` takes the pointer it sets
        /// as nullable, and every other call takes it as non-null.
        @discardableResult
        private func nullable<T, R>(
            _ pointer: UnsafeMutablePointer<T>,
            _ body: (UnsafeMutablePointer<T?>) -> R
        ) -> R {
            pointer.withMemoryRebound(to: T?.self, capacity: 1, body)
        }
    #else
        /// Calls `body` with `pointer`: only Android needs it seen as `Optional`.
        @discardableResult
        private func nullable<T, R>(
            _ pointer: UnsafeMutablePointer<T>,
            _ body: (UnsafeMutablePointer<T>) -> R
        ) -> R {
            body(pointer)
        }
    #endif

    /// The executable `name` built next to this test bundle: the nearest
    /// directory above this binary that has it.
    private func builtExecutable(named name: String) -> String? {
        guard var directory = currentBinary() else { return nil }
        for _ in 0..<5 {
            guard let slash = directory.lastIndex(of: "/") else { return nil }
            directory = String(directory[..<slash])
            let candidate = directory + "/" + name
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    /// The path of the binary this code is in: the test bundle on Darwin, where
    /// a runner loads it, and the test executable itself on Linux and
    /// Android.
    private func currentBinary() -> String? {
        #if canImport(Darwin)
            var info = Dl_info()
            guard dladdr(#dsohandle, &info) != 0, let path = info.dli_fname else { return nil }
            return String(cString: path)
        #else
            var buffer = [CChar](repeating: 0, count: 4096)
            let count = readlink("/proc/self/exe", &buffer, buffer.count)
            guard count > 0 else { return nil }
            let path = buffer[..<count].map { UInt8(truncatingIfNeeded: $0) }
            return String(validating: path, as: UTF8.self)
        #endif
    }
#endif
