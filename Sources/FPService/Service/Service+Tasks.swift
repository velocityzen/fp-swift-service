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
// `async let`.

/// Runs the bracket: acquire, `serve`, dispose.
func runBracket<Resource, Failure: Error>(
    _ bracket: sending BracketAsync<Resource, Failure>,
    _ serve: sending @escaping (Resource, Shutdown) async -> Result<Void, Failure>,
    _ run: ServiceRun<Failure>
) async {
    run.started()
    let result = await bracket { resource in
        run.ready()
        run.served(await serve(resource, run.shutdown))
        return .success(())
    }
    // Cancelled, and not by a signal or the timeout (those move the run to
    // stage 2 first, so this is ignored): the caller cancelled it.
    if Task.isCancelled { run.cancel(.caller) }
    run.finished(result)
}

/// Runs the bracket in its own task until it finishes, or until stage 2
/// begins — then leaves the scope, which cancels that task and waits for it
/// (dispose included).
func superviseBracket<Resource, Failure: Error>(
    _ bracket: sending BracketAsync<Resource, Failure>,
    _ serve: sending @escaping (Resource, Shutdown) async -> Result<Void, Failure>,
    _ run: ServiceRun<Failure>
) async {
    async let bracketTask: Void = runBracket(bracket, serve, run)
    await firstOpened(run.done, run.cancelling)
    guard run.done.isOpen else { return }
    await bracketTask
}

/// Reads signals, and runs the `shutdownTimeout` timer from the start of
/// stage 1, until the bracket has finished. Ending it ends the signal stream,
/// which restores the dispositions.
func watchSignalsAndTimeout<Failure: Error>(
    _ signals: AsyncStream<Int32>,
    timeout: Duration?,
    _ run: ServiceRun<Failure>
) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await signal in signals { run.receive(signal) }
        }
        if let timeout {
            group.addTask {
                await run.shutdown.requested
                guard !Task.isCancelled else { return }
                await run.clock.sleep(timeout)
                guard !Task.isCancelled else { return }
                run.cancel(.shutdownTimeout(after: timeout))
            }
        }
        await run.done.opened
        group.cancelAll()
    }
}

/// Runs the observer, if there is one.
func runObserver<Failure: Error>(
    _ observe: sending ((ServiceEvents<Failure>) async -> Void)?,
    _ events: ServiceEvents<Failure>?
) async {
    guard let observe, let events else { return }
    await observe(events)
}

/// Suspends until either gate opens, or the task is cancelled.
private func firstOpened(_ a: Gate, _ b: Gate) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await a.opened }
        group.addTask { await b.opened }
        await group.next()
        group.cancelAll()
    }
}
