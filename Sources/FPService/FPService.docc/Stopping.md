# Stopping a Service

The three stages of stopping, and how a service body reacts to them.

## Overview

| Stage | Triggered by | What happens |
|---|---|---|
| 1. graceful | a signal, or the body returning | ``Shutdown`` is requested; the `shutdownTimeout` clock starts |
| 2. cancel | a signal during stage 1, the timeout passing, or cancelling the calling task | the service is cancelled; dispose still runs |
| 3. kill | a signal during stage 2 | the signal's default action is restored and the signal re-sent; the process ends (with exit status 128 + the signal, if that action would leave it running) |

Each signal from `shutdownSignals` moves the stop one stage forward. The signals are taken over before acquire and released after dispose, so they can never kill the process mid-cleanup by accident. In stage 2 dispose runs in a cancelled task; cleanup that must finish anyway uses fp-swift-bracket's `BracketAsync(acquire:uncancellableDispose:)`.

The ``ServiceOutcome`` records how it went: ``ServiceOutcome/shutdownReason`` says why stage 1 began, and ``ServiceOutcome/cancellationReason`` why stage 2 happened, if it did. A stop that outlasts `shutdownTimeout` returns ``ServiceError/shutdownTimeout(after:serve:stop:)``, which also carries any `serve` or dispose failure.

### Cancel the work on shutdown

A body that runs until it is told to stop gets ``Shutdown`` as its second argument. It is read-only: the body stops by returning. The simplest way to react is ``withCancellation(on:_:)``: it runs the work and returns its result, and if shutdown is requested first, it cancels the work and waits for it to return (`swift run Example requests`).

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

### Let the work drain

Cancelling cuts off whatever is in flight. When the work has its own graceful-stop API, call that on shutdown instead with ``withShutdownHandler(on:_:operation:)``, and let the work finish by itself (`swift run Example drain`). Here the server stands in for such a library:

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
    /// one in flight and returns.
    func run() async -> Result<Void, ExampleError> {
        var request = 0
        while accepting.withLock({ $0 }) {
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

If the work runs on its own after acquire (its own event loop), its graceful stop belongs in dispose instead, with the default body: dispose runs after the body returns, so a resource drains and closes there without ever seeing ``Shutdown``.

### Read it directly

For anything else, ``Shutdown/isRequested`` and ``Shutdown/requested`` read the request directly.
