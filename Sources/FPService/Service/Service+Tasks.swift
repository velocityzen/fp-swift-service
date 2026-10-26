import FPBracket

// The concurrent tasks a `Service` runs around the user's bracket. They are
// all child tasks of one `callAsFunction` call, so none outlives it:
//
//   callAsFunction
//   ├── runObserver              the observer reads events
//   ├── watchSignalsAndTimeout   signals and the shutdownTimeout timer
//   └── superviseBracket         stage 2 cancels the bracket's own task
//       └── runBracket           acquire → serve → dispose
//
// Each takes its non-`Sendable` work as `sending`, so it can be started with
// `async let`. The one exception is the task that reads signals: it must
// outlive the caller's cancellation (see `watchSignalsAndTimeout`), so it is
// an unstructured task that `watchSignalsAndTimeout` ends and awaits, along
// with the child it requests a signal's graceful shutdown in.

/// Runs the bracket: acquire, `serve`, dispose.
func runBracket<Resource, Failure: Error>(
    _ bracket: sending BracketAsync<Resource, Failure>,
    _ serve: sending @escaping (Resource, Shutdown) async -> Result<Void, Failure>,
    _ run: ServiceRun<Failure>
) async {
    let result = await bracket { resource in
        run.ready()
        run.served(await serve(resource, run.shutdown))
        return .success(())
    }
    run.finished(result)
}

/// Runs the bracket in its own task until it finishes, or until stage 2
/// begins — then leaves the scope, which cancels that task and waits for it
/// (dispose included).
///
/// Cancelling the caller begins stage 2 at once, not when the bracket
/// returns, so a signal during the cancelled dispose ends the process.
func superviseBracket<Resource, Failure: Error>(
    _ bracket: sending BracketAsync<Resource, Failure>,
    _ serve: sending @escaping (Resource, Shutdown) async -> Result<Void, Failure>,
    _ run: ServiceRun<Failure>
) async {
    async let bracketTask: Void = runBracket(bracket, serve, run)
    await withTaskCancellationHandler {
        await firstOpened(run.done, run.cancelling)
    } onCancel: {
        run.cancel(.caller)
    }
    guard run.done.isOpen else { return }
    await bracketTask
}

/// Reads signals, and runs the `shutdownTimeout` timer from the start of
/// stage 1, until the bracket has finished. Ending it ends the signal stream,
/// which releases the signals.
///
/// The signals are held until dispose has finished even when the caller is
/// cancelled, so they never fall back to their default action mid-cleanup:
/// the reader is not a child task (a child would be cancelled with the
/// caller, ending the stream), and the wait for the bracket ignores
/// cancellation.
///
/// A signal's graceful request runs the shutdown handlers, so the reader
/// makes it in a child of its own: a handler that blocks never keeps a later
/// signal from cancelling the service or ending the process. Returns once
/// that handler has, after the signals are released.
func watchSignalsAndTimeout<Failure: Error>(
    _ signals: AsyncStream<Int32>,
    timeout: Duration?,
    _ run: ServiceRun<Failure>
) async {
    let reader = Task {
        await withTaskGroup(of: Void.self) { requests in
            for await signal in signals {
                guard run.receive(signal) else { continue }
                requests.addTask { run.shutdown.trigger() }
            }
        }
    }
    await withTaskGroup(of: Void.self) { group in
        if let timeout {
            group.addTask {
                await run.graceful.openedOrCancelled
                guard !Task.isCancelled else { return }
                await run.clock.sleep(timeout)
                guard !Task.isCancelled else { return }
                run.cancel(.shutdownTimeout(after: timeout))
            }
        }
        await run.done.openedIgnoringCancellation
        group.cancelAll()
    }
    reader.cancel()
    await reader.value
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
    _ observe: sending ((ServiceEvents<Failure>) async -> Void)?,
    _ events: ServiceEvents<Failure>?
) async {
    guard let observe, let events else {
        return
    }

    await observe(events)
}

/// Suspends until either gate opens, or the task is cancelled.
private func firstOpened(_ a: Gate, _ b: Gate) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await a.openedOrCancelled }
        group.addTask { await b.openedOrCancelled }
        await group.next()
        group.cancelAll()
    }
}
