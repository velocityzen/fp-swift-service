# Stopping a Service

The three stages of stopping, and how a service body responds.

## Overview

| Stage | Triggered by | What happens |
|---|---|---|
| 1. graceful | a signal, or the body returning | ``Shutdown`` is requested; the `shutdownTimeout` clock starts |
| 2. cancel | a signal during stage 1, the timeout, or cancelling the calling task | the service is cancelled; dispose still runs |
| 3. kill | a signal during stage 2 | the process ends as the signal ends it (exit status 128 + the signal if its default action wouldn't); on Windows, with `STATUS_CONTROL_C_EXIT` |

Each signal from `shutdownSignals` advances one stage. The signals are held from before acquire until after dispose, so they can't end the process mid-cleanup.

In stage 2, dispose runs in a cancelled task; use fp-swift-bracket's `BracketAsync(acquire:uncancellableDispose:)` for cleanup that must finish. A dispose that ignores cancellation is awaited until it returns or another signal ends the process.

``ServiceOutcome/shutdownReason`` and ``ServiceOutcome/cancellationReason`` record why each stage began. A stop that outlasts `shutdownTimeout` fails with ``ServiceError/shutdownTimeout(after:serve:stop:)``.

### Cancel the work

``withCancellation(on:_:)`` runs the work and returns its result, cancelling it if shutdown is requested first (`swift run Example requests`).

<!-- example: requests -->
```swift
/// Handles requests until shutdown is requested, then stops and returns.
func handleRequests(_ resources: (Database, Server), _ shutdown: Shutdown) async -> Result<
    Void, ExampleError
> {
    await withCancellation(on: shutdown, work)
}

/// Handles a request once a second until cancelled.
func work() async -> Result<Void, ExampleError> {
    var request = 0
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }
        request += 1
        print("handled request \(request)")
    }
    return .success(())
}
```

<!-- example: runrequests -->
```swift
let withService = Service(
    withDependencies(),
    shutdownSignals: [SIGINT, SIGTERM],
    shutdownTimeout: .seconds(10)
)
let result = await withService(handleRequests)
```

### Drain the work

When the work has its own graceful stop, call it from a handler with ``withShutdownHandler(on:_:operation:)`` (`swift run Example drain`). The handler is removed when the operation ends. Dispose waits for running handlers unless the service is cancelled first.

<!-- example: server -->
```swift
/// Stands in for a server library with its own graceful stop.
final class Server: Sendable {
    let database: Database
    private let accepting = Mutex(true)

    init(database: Database) {
        self.database = database
    }

    /// Handles requests until `beginGracefulShutdown()`, then finishes the
    /// one in flight and returns; stops at once if cancelled.
    func run() async -> Result<Void, ExampleError> {
        var request = 0
        while accepting.withLock({ $0 }) && !Task.isCancelled {
            request += 1
            print("handling request \(request)")
            try? await Task.sleep(for: .seconds(1))
            print("finished request \(request)")
        }
        return .success(())
    }

    /// Stops taking new requests; `run()` returns once the current one is done.
    func beginGracefulShutdown() {
        accepting.withLock { $0 = false }
    }
}
```

<!-- example: drain -->
```swift
/// Lets the server finish the request in flight instead of cancelling it.
func drainRequests(_ resources: (Database, Server), _ shutdown: Shutdown) async -> Result<
    Void, ExampleError
> {
    let (_, server) = resources
    return await withShutdownHandler(on: shutdown, server.beginGracefulShutdown) {
        await server.run()
    }
}
```

<!-- example: rundrain -->
```swift
let withService = Service(
    withDependencies(),
    shutdownSignals: [SIGINT, SIGTERM],
    shutdownTimeout: .seconds(10)
)
let result = await withService(drainRequests)
```

Work that runs on its own after acquire can drain in its dispose instead, with the default body.

### Read it directly

``Shutdown/isRequested`` and ``Shutdown/requested`` read the request. To test a body on its own, pass it a ``Shutdown`` and call ``Shutdown/request()``.
