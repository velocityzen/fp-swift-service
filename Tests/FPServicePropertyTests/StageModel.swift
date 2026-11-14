// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    @testable import FPService

    /// What Stopping.md says a run goes through, kept apart from the stage
    /// machine: stage numbers, and what began each.
    struct StageModel {
        var stage = 0
        var finished = false
        var ready = false
        var shutdownReason: ShutdownReason?
        var cancellationReason: CancellationReason?
        var shutdownAt: Duration?
        var servedAt: Duration?
        var finishedAt: Duration?
        var unavailable: [Int32]?
        var startFailure: TestError?
        var serveFailure: TestError?
        var stopFailure: TestError?
        var timedOut: Duration?

        /// Takes `input`; returns the effect the loop must carry out.
        mutating func take(_ input: Lifecycle.Input) -> Lifecycle.Effect {
            switch input {
                case .signalsUnavailable(let signals):
                    unavailable = signals
                    return .none
                case .started: return .none
                case .ready:
                    ready = true
                    return .none
                case .served(let result, let cancelled, let at):
                    servedAt = at
                    serveFailure = result.failure
                    if cancelled || stage == 2 { return .none }
                    if stage == 1 { return .awaitHandlers }
                    return graceful(.serveReturned, at: at)
                case .finished(let result, let at):
                    finishedAt = at
                    finished = true
                    if ready { stopFailure = result.failure } else { startFailure = result.failure }
                    return .none
                case .signal(let signal, let at):
                    return signalled(signal, at: at)
                case .cancel(let reason):
                    return cancel(reason)
            }
        }

        /// Each signal begins the next stage; after stage 2, it ends the
        /// process. Once the run has finished, signals do nothing.
        private mutating func signalled(_ signal: Int32, at: Duration) -> Lifecycle.Effect {
            if finished { return .none }
            switch stage {
                case 0: return graceful(.signal(signal), at: at)
                case 1: return cancel(.signal(signal))
                default: return .kill(signal)
            }
        }

        private mutating func graceful(_ reason: ShutdownReason, at: Duration) -> Lifecycle.Effect {
            stage = 1
            shutdownReason = reason
            shutdownAt = at
            return .graceful
        }

        private mutating func cancel(_ reason: CancellationReason) -> Lifecycle.Effect {
            if finished || stage == 2 { return .none }
            stage = 2
            cancellationReason = reason
            if case .shutdownTimeout(let after) = reason { timedOut = after }
            return .cancel
        }
    }

#endif
