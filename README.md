# fp-swift-service

[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Ffp-swift-service%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/velocityzen/fp-swift-service)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Ffp-swift-service%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/velocityzen/fp-swift-service)
[![Documentation](https://img.shields.io/badge/documentation-DocC-purple)](https://swiftpackageindex.com/velocityzen/fp-swift-service/documentation/fpservice)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A functional service lifecycle for Swift, in the [fp-swift](https://github.com/velocityzen/fp-swift) style. Services are `BracketAsync` values composed with do-notation, and running them returns a `Result`. Nothing throws.

The examples come from `Sources/Example`; run each step with `swift run Example <step>`.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/velocityzen/fp-swift-service", branch: "main")
]
```

Add `FPService` to your target. `ProcessSignals` is also available on its own.

Requires Swift 6.4. Runs on macOS, iOS, tvOS, watchOS and visionOS 26+, Linux, Android and Windows.

Documentation: [FPService](https://swiftpackageindex.com/velocityzen/fp-swift-service/documentation/fpservice), [ProcessSignals](https://swiftpackageindex.com/velocityzen/fp-swift-service/documentation/processsignals).

## Quick start

`swift run Example`, then Ctrl-C.

A service is a function that returns a bracket: acquire starts it, dispose stops it.

<!-- example: brackets -->
```swift
func withDatabase() -> BracketAsync<Database, ExampleError> {
    BracketAsync(
        acquire: {
            print("database: open")
            return .success(Database())
        },
        dispose: { _ in
            print("database: closed")
            return .success(())
        }
    )
}

func withServer(_ database: Database) -> BracketAsync<Server, ExampleError> {
    BracketAsync(
        acquire: {
            print("server: listening")
            return .success(Server(database: database))
        },
        dispose: { _ in
            print("server: closed")
            return .success(())
        }
    )
}
```

Compose services with do-notation. A dependency is a parameter. Services start in order and stop in reverse.

<!-- example: dependencies -->
```swift
func withDependencies() -> BracketAsync<(Database, Server), ExampleError> {
    BracketAsyncDo<ExampleError>()
        .bind { withDatabase() }
        .bind { database in withServer(database) }
}
```

`Service` subscribes to the signals, starts the services, waits for a signal, then stops them.

<!-- example: quickstart -->
```swift
let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
let result = await withService()
```

`result` is a `Result<ServiceOutcome, ServiceError<ExampleError>>`; see [Results](#results).

## Watching events

`swift run Example events`

An observer receives every lifecycle event as a stream of `Result`s. The stream finishes after the last event.

<!-- example: events -->
```swift
let withService = Service(
    withDependencies(),
    shutdownSignals: [SIGINT, SIGTERM]
) { events in
    for await event in events {
        switch event {
            case .success(let event): print("event: \(event)")
            case .failure(let error): print("error: \(error)")
        }
    }
}
let result = await withService()
```

fp-swift's combinators (`failures()`, `successes()`, `tap`) and fp-swift-pipe's `FromResult` work on the stream directly. See [Events](#events) for the full list.

## The service body

`swift run Example job`

To do work while the services are up, pass a body. It receives the resources; when it returns, the service stops.

<!-- example: job -->
```swift
/// Does a fixed amount of work, then returns — which stops the service.
/// Returns early if cancelled.
func importBatches(
    _ resources: (Database, Server),
    _: Shutdown
) async -> Result<Void, ExampleError> {
    for batch in 1...3 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { break }
        print("imported batch \(batch)")
    }
    return .success(())
}
```

<!-- example: runjob -->
```swift
let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
let result = await withService(importBatches)
```

## Shutdown

`swift run Example requests`, then Ctrl-C.

A long-running body watches its `Shutdown` argument, which is requested when the service starts stopping. `withCancellation(on:_:)` cancels the work on shutdown and returns its result.

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

`shutdown.isRequested` and `await shutdown.requested` read the request directly. To test a body on its own, pass it a `Shutdown()` and call `request()`.

## Draining

`swift run Example drain`, then Ctrl-C during a request.

When the work has its own graceful stop, call it on shutdown instead of cancelling:

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

`withShutdownHandler(on:_:operation:)` runs the handler on shutdown and removes it when the operation ends. Dispose waits for running handlers unless the service is cancelled first.

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

`shutdownTimeout` limits the graceful stop, dispose included; past it, the service is cancelled. Work that runs on its own after acquire can drain in its dispose instead.

## Stopping

| Stage | Triggered by | What happens |
|---|---|---|
| 1. graceful | a signal, or the body returning | `shutdown` is requested; the `shutdownTimeout` clock starts |
| 2. cancel | a signal during stage 1, the timeout, or cancelling the calling task | the service is cancelled; dispose still runs |
| 3. kill | a signal during stage 2 | the process ends as the signal ends it (exit status 128 + the signal if its default action wouldn't); on Windows, with `STATUS_CONTROL_C_EXIT` |

Each signal from `shutdownSignals` advances one stage. The signals are held from before acquire until after dispose, so they can't end the process mid-cleanup.

In stage 2, dispose runs in a cancelled task; use fp-swift-bracket's `BracketAsync(acquire:uncancellableDispose:)` for cleanup that must finish. A dispose that ignores cancellation is awaited until it returns or another signal ends the process.

## Reference

### Service

```swift
Service(
    _ service: BracketAsync<Resource, Failure>,      // the composed services
    shutdownSignals: [Int32] = [],                   // signals subscribed to for the run
    shutdownTimeout: Duration? = nil,                // how long stage 1 may take
    clock: ServiceClock = .continuous,               // tests inject a manual clock
    observe: ((ServiceEvents<Failure>) async -> Void)? = nil
)

await withService(body)   // body: (Resource, Shutdown) async -> Result<Void, Failure>
await withService()       // default body: wait for shutdown
```

A `Service` runs once; a second call doesn't compile. Brackets are reusable. The call returns once dispose, the shutdown handlers and the observer have finished and the signals are released.

### Results

| What happened | Result |
|---|---|
| a shutdown signal can't be subscribed to | `.failure(.signalsUnavailable(signals))`; nothing runs |
| acquire failed | `.failure(.startFailed(e))`; body and dispose skipped |
| the body failed | `.failure(.serveFailed(e))` |
| dispose failed | `.failure(.stopFailed(e))` |
| both failed | `.failure(.serveAndStopFailed(serve:stop:))` |
| the timeout passed | `.failure(.shutdownTimeout(after:serve:stop:))`, with any body or dispose failure |
| otherwise | `.success(ServiceOutcome)` |

| `ServiceOutcome` field | Meaning |
|---|---|
| `shutdownReason` | why stage 1 began: `.serveReturned` or `.signal(n)`; `nil` if the caller cancelled first |
| `cancellationReason` | why stage 2 began: `.signal(n)` or `.caller`; `nil` if the stop was graceful |
| `stopDuration` | from the end of the body to the end of dispose |
| `shutdownDuration` | from the start of stage 1 to the end of dispose, the span `shutdownTimeout` limits |

### Events

`ServiceEvents<Failure>` is an `AsyncStream<Result<ServiceEvent, ServiceError<Failure>>>`. A SIGTERM, then a second SIGTERM while shutting down:

```
.success(.started)
.success(.ready)
.success(.signal(SIGTERM))
.success(.shuttingDown(.signal(SIGTERM)))
.success(.signal(SIGTERM))
.success(.cancelling(.signal(SIGTERM)))
.success(.stopped(ServiceOutcome(shutdownReason: .signal(SIGTERM), cancellationReason: .signal(SIGTERM), stopDuration: …, shutdownDuration: …)))
```

Each failure arrives once, as `.failure`, when it happens; the result combines them. A run that never started ends with its failure instead of `.stopped`. If the calling task is cancelled, the observer may miss the last events.

### Notes

- **Build brackets outside the main actor.** The bracket, body and observer are `sending`, because they run in tasks that stage 2 can cancel. Main-actor closures can't be sent, so build them in top-level functions, as the example does.
- **Throwing code:** wrap it with fp-swift-bracket's `BracketAsync.throwing(acquire:dispose:)`.

## ProcessSignals

Process signals as an `AsyncStream`, with no package dependencies. `Service` is built on it.

```swift
import ProcessSignals

for await signal in await processSignals([SIGTERM, SIGINT]) {
    print(signalName(signal))   // "SIGTERM"
}
```

- `processSignals(_:)` returns once the signals are subscribed to, so none sent after the call is missed.
- Signals that can't be caught (`SIGKILL`, `SIGSTOP`, or numbers the platform lacks or reserves) are skipped. If none are left, the stream is already finished.
- While the stream lives, the signals' default actions are suspended. They are caught, not ignored, so child processes still start with the defaults.
- Cancelling the iterating task ends the stream; the last stream on a signal restores its previous disposition. Breaking out of the loop doesn't end it.
- Several streams can share a signal; each gets every delivery. Signals sent at the same instant may merge, except on Darwin.
- On Windows, console events arrive as `SIGINT` (Ctrl-C), `SIGBREAK` (Ctrl-Break) and `SIGTERM` (close, logoff, shutdown). A `SIGTERM` event is held while any stream subscribes to `SIGTERM`, which gives dispose the few seconds Windows allows.

The [Signal Reference](https://swiftpackageindex.com/velocityzen/fp-swift-service/documentation/processsignals/signalreference) lists what each signal means and which to subscribe to.
