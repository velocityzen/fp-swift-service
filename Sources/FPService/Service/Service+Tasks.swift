import FPBracket

// The tasks of one `callAsFunction` call. Every input reaches the loop in
// `ServiceLifecycle.run` through the run's inbox, and the loop carries out
// every effect:
//
//   callAsFunction
//   ├── runObserver                the observer reads events
//   └── runLifecycle
//       ├── the bracket's task     runBracket: acquire → serve → dispose
//       └── the loop's task        takes each step, carries out its effect
//           ├── forward            signals → inbox
//           ├── cancel(after:)     from stage 1: the timeout → inbox
//           └── shutdown requests  run the shutdown handlers
//
// The two tasks `runLifecycle` starts are not children of the call:
// cancelling the caller must reach the run as an input (stage 2), not as
// cancellation, so the loop runs on through dispose and holds the signals
// until it ends; stage 2 is the loop cancelling the bracket's task.
// `runLifecycle` awaits the loop and the loop awaits the bracket's task, so
// neither outlives the call.

/// Starts the bracket's task and the loop's, and returns the lifecycle once
/// the loop has ended. Cancelling the caller begins stage 2 at once, so a
/// signal during the cancelled dispose ends the process.
func runLifecycle<Resource, Failure: Error>(
    _ lifecycle: ServiceLifecycle<Failure>,
    _ bracket: sending BracketAsync<Resource, Failure>,
    _ serve: sending @escaping @concurrent (Resource, Shutdown) async -> Result<Void, Failure>,
    signals: AsyncStream<Int32>
) async -> ServiceLifecycle<Failure> {
    let inbox = lifecycle.inbox
    let shutdown = Shutdown()
    let service = Task {
        // Sound: this function took both as `sending`, and this task is the
        // only one that can reach them.
        nonisolated(unsafe) let bracket = bracket
        nonisolated(unsafe) let serve = serve
        await runBracket(bracket, serve, shutdown, inbox)
    }
    let loop = Task {
        var lifecycle = lifecycle
        await lifecycle.run(service, shutdown: shutdown, signals: signals)
        return lifecycle
    }
    return await withTaskCancellationHandler {
        await loop.value
    } onCancel: {
        inbox.post(.cancel(.caller))
    }
}

/// Runs the bracket — acquire, `serve`, dispose — telling the loop how it
/// goes. Once `serve` returns, waits for the loop's step: if it begins stage
/// 1, the shutdown handlers run before dispose does. `@concurrent`: it is
/// the bracket's own task, off the caller's actor.
@concurrent
func runBracket<Resource, Failure: Error>(
    _ bracket: sending BracketAsync<Resource, Failure>,
    _ serve: sending @escaping @concurrent (Resource, Shutdown) async -> Result<Void, Failure>,
    _ shutdown: Shutdown,
    _ inbox: Inbox<Failure>
) async {
    let result = await bracket { resource in
        inbox.post(.ready)
        let served = await serve(resource, shutdown)
        await inbox.ask(.served(served, cancelled: Task.isCancelled, at: inbox.now))
        return .success(())
    }
    inbox.post(.finished(result, at: inbox.now))
}

/// Hands every signal to the loop until cancelled. Ending it ends the
/// stream, which releases the signals.
func forward<Failure>(_ signals: AsyncStream<Int32>, to inbox: Inbox<Failure>) async {
    for await signal in signals {
        inbox.post(.signal(signal, at: inbox.now))
    }
}

/// Tells the loop the timeout has passed, `timeout` from now, unless
/// cancelled first.
func cancel<Failure>(after timeout: Duration, _ inbox: Inbox<Failure>) async {
    await inbox.clock.sleep(timeout)
    guard !Task.isCancelled else { return }
    inbox.post(.cancel(.shutdownTimeout(after: timeout)))
}

/// Ends a signal stream that is never read, which releases its signals: a
/// stream iterated in a cancelled task ends.
func release(_ signals: AsyncStream<Int32>) async {
    let reader = Task {
        for await _ in signals {}
    }
    reader.cancel()
    await reader.value
}

/// Runs the observer, if there is one.
func runObserver<Failure: Error>(
    _ observe: sending (@concurrent (ServiceEvents<Failure>) async -> Void)?,
    _ events: ServiceEvents<Failure>?
) async {
    guard let observe, let events else {
        return
    }

    await observe(events)
}
