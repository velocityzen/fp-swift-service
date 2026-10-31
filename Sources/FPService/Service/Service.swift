import FPBracket
import ProcessSignals
import Synchronization

/// One service — a `BracketAsync` the host has already composed — run once.
///
/// Configure it, then call it with its `serve` body, like a bracket:
///
/// ```swift
/// let withService = Service(
///     withDependencies(),
///     shutdownSignals: [SIGINT, SIGTERM],
///     shutdownTimeout: .seconds(10)
/// )
/// let result = await withService(handleRequests)
/// ```
///
/// `result` is a `Result<ServiceOutcome, ServiceError<ExampleError>>`. (The
/// code is the package's Example; see <doc:GettingStarted>.)
///
/// Each signal from `shutdownSignals` advances the stop one stage (see
/// <doc:Stopping>):
///
/// 1. **graceful** — a signal, or `serve` returning: `shutdown` is requested
///    and the `shutdownTimeout` clock starts;
/// 2. **cancel** — a signal during stage 1, the timeout, or cancelling the
///    calling task: the service is cancelled; dispose still runs;
/// 3. **kill** — a signal during stage 2: the process ends as the signal
///    ends it.
///
/// The value is `~Copyable` and the call consumes it, so it runs once; the
/// brackets inside stay reusable.
public struct Service<Resource, Failure: Error>: ~Copyable {
    // What the run sends to tasks of its own. `init` takes them as
    // `sending`, and each `Mutex` keeps its value disconnected from the
    // caller, and from the other, until the call takes it out, once.
    let bracket: Mutex<BracketAsync<Resource, Failure>?>
    let observe: Mutex<(@concurrent (ServiceEvents<Failure>) async -> Void)?>
    let shutdownSignals: [Int32]
    let shutdownTimeout: Duration?
    let clock: ServiceClock
    let signalStream: @Sendable ([Int32]) async -> Signals
    let terminate: @Sendable (Int32) -> Void

    /// - Parameters:
    ///   - service: the composed bracket; acquire starts it, dispose stops it.
    ///   - shutdownSignals: signals subscribed to for the run. If one can't
    ///     be, the run fails with ``ServiceError/signalsUnavailable(_:)``
    ///     before acquire, since that signal could end the process mid-run.
    ///   - shutdownTimeout: how long the graceful stage may take before the
    ///     service is cancelled; `nil` waits indefinitely.
    ///   - clock: deadlines and stop durations; tests inject a manual clock.
    ///   - observe: reads the run's events; without it none are produced.
    public init(
        _ service: sending BracketAsync<Resource, Failure>,
        shutdownSignals: [Int32] = [],
        shutdownTimeout: Duration? = nil,
        clock: ServiceClock = .continuous,
        observe: sending (@concurrent (ServiceEvents<Failure>) async -> Void)? = nil
    ) {
        self.init(
            service,
            shutdownSignals: shutdownSignals,
            shutdownTimeout: shutdownTimeout,
            clock: clock,
            signalStream: { await registerSignals($0) },
            terminate: { endProcess(as: $0) },
            observe: observe
        )
    }

    /// The seams tests replace: where signals come from (and which were
    /// subscribed to), and how stage 3 ends the process.
    init(
        _ service: sending BracketAsync<Resource, Failure>,
        shutdownSignals: [Int32],
        shutdownTimeout: Duration?,
        clock: ServiceClock,
        signalStream: @escaping @Sendable ([Int32]) async -> Signals,
        terminate: @escaping @Sendable (Int32) -> Void,
        observe: sending (@concurrent (ServiceEvents<Failure>) async -> Void)?
    ) {
        self.bracket = Mutex(service)
        self.observe = Mutex(observe)
        self.shutdownSignals = shutdownSignals
        self.shutdownTimeout = shutdownTimeout
        self.clock = clock
        self.signalStream = signalStream
        self.terminate = terminate
    }

    /// Runs the service once: acquire, `serve`, dispose.
    ///
    /// `serve` is the bracket body — what runs while the service is up. It
    /// gets the resources and the run's ``Shutdown``, and should return once
    /// it has stopped taking work. The default stays up until shutdown is
    /// requested.
    ///
    /// - Returns: the ``ServiceOutcome``, or a ``ServiceError`` naming the
    ///   failed phase with the service's own error. Returns once dispose,
    ///   the shutdown handlers and the observer have finished and the
    ///   signals are released.
    public consuming func callAsFunction(
        _ serve: sending @escaping @concurrent (Resource, Shutdown) async -> Result<Void, Failure> =
            waitForShutdown
    ) async -> Result<ServiceOutcome, ServiceError<Failure>> {
        // Always there: the call consumes this value, so it runs once.
        let bracket = bracket.withLock { $0.take()! }
        let observe = observe.withLock { $0.take() }
        var events: ServiceEvents<Failure>?
        var continuation: ServiceEvents<Failure>.Continuation?
        if observe != nil {
            (events, continuation) = ServiceEvents<Failure>.makeStream()
        }
        var lifecycle = ServiceLifecycle<Failure>(
            clock: clock,
            timeout: shutdownTimeout,
            events: continuation,
            terminate: terminate
        )

        async let observed: Void = runObserver(observe, events)
        let (signals, _, unavailable) = await signalStream(shutdownSignals)
        if unavailable.isEmpty {
            _ = lifecycle.take(.started)
            lifecycle = await runLifecycle(lifecycle, bracket, serve, signals: signals)
        } else {
            _ = lifecycle.take(.signalsUnavailable(unavailable))
            await release(signals)
        }

        let result = lifecycle.result
        lifecycle.finishEvents()
        await observed
        return result
    }
}

/// The default `serve`: stays up until shutdown is requested.
@usableFromInline
@Sendable
func waitForShutdown<Resource, Failure: Error>(
    _: Resource,
    _ shutdown: Shutdown
) async -> Result<Void, Failure> {
    await shutdown.requested
    return .success(())
}
