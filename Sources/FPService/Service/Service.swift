#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import FPBracket
import ProcessSignals

/// One service — a `BracketAsync` the host has already composed — run once.
///
/// Configure it, then call it with its `serve` body, like a bracket:
///
/// ```swift
/// let withService = Service(services, shutdownSignals: [SIGTERM, SIGINT], shutdownTimeout: .seconds(10)) { events in
///     for await event in events { log(event) }       // ends by itself after .stopped
/// }
///
/// let result = await withService { resources, shutdown in
///     await api.acceptLoop(until: shutdown)
/// }
/// // Result<ServiceOutcome, ServiceError<AppError>>, after dispose has finished
/// ```
///
/// Stopping has three stages. Each signal from `shutdownSignals` moves it one
/// stage forward:
///
/// 1. **graceful** — a signal, or `serve` returning: `shutdown` is requested,
///    and the `shutdownTimeout` clock starts;
/// 2. **cancel** — a signal during stage 1, the timeout passing, or cancelling
///    the calling task: the service is cancelled; dispose still runs;
/// 3. **kill** — a signal during stage 2: the signal's default action is
///    restored and the signal re-sent, so the process ends.
///
/// The value is `~Copyable` and the call consumes it, so it runs exactly
/// once; the brackets inside stay reusable.
public struct Service<Resource, Failure: Error>: ~Copyable {
    let bracket: BracketAsync<Resource, Failure>
    let observe: ((ServiceEvents<Failure>) async -> Void)?
    let shutdownSignals: [Int32]
    let shutdownTimeout: Duration?
    let clock: ServiceClock
    let signalStream: @Sendable ([Int32]) async -> AsyncStream<Int32>
    let terminate: @Sendable (Int32) -> Void

    /// - Parameters:
    ///   - service: the composed bracket; acquire starts it, dispose stops it.
    ///   - shutdownSignals: signals taken over for the run; see the stages above.
    ///   - shutdownTimeout: how long the graceful stage may take before the
    ///     service is cancelled; `nil` waits indefinitely.
    ///   - clock: deadlines and stop durations; tests inject a manual clock.
    ///   - observe: reads the run's events; without it none are produced.
    public init(
        _ service: sending BracketAsync<Resource, Failure>,
        shutdownSignals: [Int32] = [],
        shutdownTimeout: Duration? = nil,
        clock: ServiceClock = .continuous,
        observe: sending ((ServiceEvents<Failure>) async -> Void)? = nil
    ) {
        self.init(
            service,
            shutdownSignals: shutdownSignals,
            shutdownTimeout: shutdownTimeout,
            clock: clock,
            signalStream: { await processSignals($0) },
            terminate: terminateProcess,
            observe: observe
        )
    }

    /// The seams tests replace: where signals come from, and how stage 3
    /// ends the process.
    init(
        _ service: sending BracketAsync<Resource, Failure>,
        shutdownSignals: [Int32],
        shutdownTimeout: Duration?,
        clock: ServiceClock,
        signalStream: @escaping @Sendable ([Int32]) async -> AsyncStream<Int32>,
        terminate: @escaping @Sendable (Int32) -> Void,
        observe: sending ((ServiceEvents<Failure>) async -> Void)?
    ) {
        self.bracket = service
        self.observe = observe
        self.shutdownSignals = shutdownSignals
        self.shutdownTimeout = shutdownTimeout
        self.clock = clock
        self.signalStream = signalStream
        self.terminate = terminate
    }

    /// Runs the service once: acquire, `serve`, dispose.
    ///
    /// `serve` is the bracket body — what runs while the service is up. It
    /// gets the resources and the read-only ``Shutdown``, and should return
    /// once it has stopped taking work. The default stays up until shutdown
    /// is requested.
    ///
    /// - Returns: the ``ServiceOutcome``, or a ``ServiceError`` naming the phase that
    ///   failed with the service's own error. Returns after dispose has
    ///   finished, the signal dispositions are restored and the observer has
    ///   returned.
    public consuming func callAsFunction(
        _ serve: sending @escaping (Resource, Shutdown) async -> Result<Void, Failure> = {
            _, shutdown in
            await shutdown.requested
            return .success(())
        }
    ) async -> Result<ServiceOutcome, ServiceError<Failure>> {
        // Sound: `init` took both as `sending` (disconnected from the
        // caller), and this ~Copyable value is consumed by the call, so
        // nothing else can reach them any more.
        nonisolated(unsafe) let bracket = self.bracket
        nonisolated(unsafe) let observe = self.observe

        var events: ServiceEvents<Failure>?
        var continuation: ServiceEvents<Failure>.Continuation?
        if observe != nil {
            (events, continuation) = ServiceEvents<Failure>.makeStream()
        }
        let run = ServiceRun<Failure>(
            clock: clock, continuation: continuation, terminate: terminate)
        let timeout = shutdownTimeout

        async let observed: Void = runObserver(observe, events)
        let signals = await signalStream(shutdownSignals)
        async let watched: Void = watchSignalsAndTimeout(signals, timeout: timeout, run)
        await superviseBracket(bracket, serve, run)
        await watched

        let result = run.result()
        run.finishEvents()
        await observed
        return result
    }
}

/// Stage 3: restore the signal's default action and re-send it.
@Sendable
private func terminateProcess(_ signal: Int32) {
    var action = sigaction()
    #if canImport(Darwin)
    action.__sigaction_u.__sa_handler = SIG_DFL
    #else
    action.__sigaction_handler.sa_handler = SIG_DFL
    #endif
    sigaction(signal, &action, nil)
    raise(signal)
}
