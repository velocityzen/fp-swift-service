import Dispatch

/// One ``Service`` run, driven by one loop.
///
/// Everything that happens to the run — a signal, the bracket's progress,
/// the timeout passing, the caller cancelling — arrives in the ``Inbox`` as
/// an `Input`, in order. The loop is the only place the state changes: it
/// takes each step (`State.step(_:)`, see ServiceLifecycle+Step.swift),
/// emits the step's events and carries out its effect itself. So events come
/// out in the order the stages changed, and no task waits on a flag.
struct ServiceLifecycle<Failure: Error>: Sendable {
    typealias Event = Result<ServiceEvent, ServiceError<Failure>>

    let inbox: Inbox<Failure>
    private(set) var state = State()
    private let timeout: Duration?
    private let events: ServiceEvents<Failure>.Continuation?
    private let terminate: @Sendable (Int32) -> Void

    init(
        clock: ServiceClock,
        timeout: Duration?,
        events: ServiceEvents<Failure>.Continuation?,
        terminate: @escaping @Sendable (Int32) -> Void
    ) {
        self.inbox = Inbox(clock: clock)
        self.timeout = timeout
        self.events = events
        self.terminate = terminate
    }

    /// Takes one step, emitting its events; returns its effect.
    mutating func take(_ input: Input) -> Effect {
        let step = state.step(input)
        step.events.forEach { events?.yield($0) }
        return step.effect
    }

    /// The loop: takes every input until the bracket has returned, then
    /// ends the signal stream, which releases the signals, and returns once
    /// every shutdown handler has. `service` is the bracket's task, started
    /// next to this one, and `shutdown` the one its `serve` was handed.
    ///
    /// The loop carries out each effect itself. Stage 1 starts the timeout
    /// and requests the shutdown on a thread of its own (see
    /// ``requestOnItsOwnThread(_:)``), so a handler that blocks never holds up
    /// the loop; stage 2 cancels the bracket's task; stage 3 ends the process.
    ///
    /// Once `serve` has returned in stage 1, however stage 1 began, dispose
    /// waits for the shutdown handlers to return, or for stage 2: `mayStop`
    /// opens on whichever comes first.
    mutating func run(
        _ service: Task<Void, Never>,
        shutdown: Shutdown,
        signals: AsyncStream<Int32>
    ) async {
        let (inbox, timeout, terminate) = (self.inbox, self.timeout, self.terminate)
        let mayStop = Gate()
        await withTaskGroup(of: Void.self) { helpers in
            helpers.addTask { await forward(signals, to: inbox) }
            for await message in inbox.messages {
                switch take(message.input) {
                    case .graceful:
                        if let timeout {
                            helpers.addTask { await cancel(after: timeout, inbox) }
                        }
                        helpers.addTask {
                            await requestOnItsOwnThread(shutdown)
                            mayStop.open()
                        }
                        if let reply = message.reply { mayStop.wait { reply.resume() } }
                    case .awaitHandlers:
                        if let reply = message.reply { mayStop.wait { reply.resume() } }
                    case .cancel:
                        service.cancel()
                        mayStop.open()
                        message.reply?.resume()
                    case .kill(let signal):
                        terminate(signal)
                        message.reply?.resume()
                    case .none:
                        message.reply?.resume()
                }
                if state.finished { break }
            }
            await service.value
            helpers.cancelAll()
        }
        inbox.close()
    }

    /// The run's result, once the loop has ended.
    var result: Result<ServiceOutcome, ServiceError<Failure>> { state.result }

    /// Ends the event stream: `.stopped` for a service that started, then finish.
    func finishEvents() {
        if let event = state.lastEvent { events?.yield(event) }
        events?.finish()
    }
}

/// Requests `shutdown` on a Dispatch thread, and waits for its handlers to
/// return without holding a thread of the concurrency pool. A handler that
/// blocks then blocks only that thread: the pool, however few threads it has
/// (the simulators can have one or two), keeps running the loop, the later
/// signals and the timeout.
private func requestOnItsOwnThread(_ shutdown: Shutdown) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue(label: "FPService.shutdown").async {
            shutdown.request()
            done.resume()
        }
    }
}

/// Where everything that happens to a run arrives for its loop, in order.
struct Inbox<Failure: Error>: Sendable {
    typealias Input = ServiceLifecycle<Failure>.Input

    /// One input, and the task waiting for the loop to carry out its step.
    struct Message: Sendable {
        let input: Input
        let reply: CheckedContinuation<Void, Never>?
    }

    let messages: AsyncStream<Message>
    let clock: ServiceClock
    private let continuation: AsyncStream<Message>.Continuation

    init(clock: ServiceClock) {
        (messages, continuation) = AsyncStream<Message>.makeStream()
        self.clock = clock
    }

    /// Now on the run's clock, for the inputs that carry a time.
    var now: Duration { clock.now() }

    /// Hands `input` to the loop.
    func post(_ input: Input) {
        continuation.yield(Message(input: input, reply: nil))
    }

    /// Hands `input` to the loop and waits until its effect has been carried
    /// out, the shutdown handlers included. Returns at once if the loop has
    /// ended.
    func ask(_ input: Input) async {
        await withCheckedContinuation { (reply: CheckedContinuation<Void, Never>) in
            if case .terminated = continuation.yield(Message(input: input, reply: reply)) {
                reply.resume()
            }
        }
    }

    /// Ends the inbox once the loop has: later inputs are dropped.
    func close() {
        continuation.finish()
    }
}
