# fp-swift-service

[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Ffp-swift-service%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/velocityzen/fp-swift-service)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Ffp-swift-service%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/velocityzen/fp-swift-service)
[![Documentation](https://img.shields.io/badge/documentation-DocC-purple)](https://swiftpackageindex.com/velocityzen/fp-swift-service/documentation/fpservice)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A functional service lifecycle for Swift, in the [fp-swift](https://github.com/velocityzen/fp-swift) style. A service is a `BracketAsync`, you compose services with do-notation, and running them returns a `Result`. Nothing throws.

The walkthrough below is `Sources/Example`, a CLI with one subcommand per step: `swift run Example <step>`. Its code blocks are copied from the example. The Reference and ProcessSignals sections show API outlines.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/velocityzen/fp-swift-service", branch: "main")
]
```

Then add `FPService` to your target's dependencies. `ProcessSignals` is a separate product, if you only need the signal stream.

Documentation: [FPService](https://swiftpackageindex.com/velocityzen/fp-swift-service/documentation/fpservice), [ProcessSignals](https://swiftpackageindex.com/velocityzen/fp-swift-service/documentation/processsignals).

## Quick start

`swift run Example`, then Ctrl-C.

**A service is a function that returns a bracket.** Acquire starts it, and the service is ready when acquire returns. Dispose stops it.

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

**Compose services into one bracket** with do-notation. A dependency is just a parameter: `withServer(_:)` needs a `Database`, so it comes second. Services start in this order and stop in reverse.

<!-- example: dependencies -->
```swift
func withDependencies() -> BracketAsync<(Database, Server), ExampleError> {
    BracketAsyncDo<ExampleError>()
        .bind { withDatabase() }
        .bind { database in withServer(database) }
}
```

**Run it.** `Service` takes over the listed signals. Calling it starts the services and waits for a signal, then stops them: the server closes first, the database last.

<!-- example: quickstart -->
```swift
let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
let result = await withService()
```

`result` is a `Result<ServiceOutcome, ServiceError<ExampleError>>`. `ServiceOutcome` says what stopped the service; a `ServiceError` names the phase that failed and carries your own error untouched. See [Results](#results).

## Watching events

`swift run Example events`

Pass a closure to observe the service. It receives every lifecycle event as a stream of `Result`s, so logging or metrics is just a loop. The stream ends by itself after the last event.

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

The observer runs next to the service, so its lines can interleave with the services' own output. See [Events](#events) for the full list.

Because `events` is an `AsyncSequence` of `Result`s, fp-swift's combinators work on it directly: `events.failures()` gives just the errors, `events.tap { … }` runs a side effect per success, and `events.successes()` drops the failures. fp-swift-pipe reads it with `FromResult(events)` as the source of a `Pipe`.

## Doing work: the service body

`swift run Example job`

Calling `withService()` with no argument just waits for a signal. To do work while the services are up, pass a body. It gets the acquired resources, and **when it returns, the service stops**, the same as on a signal.

<!-- example: job -->
```swift
/// Does a fixed amount of work, then returns — which stops the service.
func importBatches(
    _ resources: (Database, Server),
    _: Shutdown
) async -> Result<Void, ExampleError> {
    for batch in 1...3 {
        try? await Task.sleep(for: .seconds(1))
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

A body that runs until it is told to stop needs to know when a stop was requested, from a signal, say. That is its second argument, `Shutdown`. It's read-only: the body still stops by returning.

The simplest way to use it is `withCancellation(on: shutdown, work)`. It runs `work` and returns its result; if shutdown is requested first, `work` is cancelled, and the call waits for it to return. A failure that happens before shutdown comes back at once.

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

For anything else, `shutdown.isRequested` and `await shutdown.requested` read it directly.

## Draining

`swift run Example drain`, then Ctrl-C while a request is in flight.

Cancelling the work cuts off whatever is in flight. When the work has its own graceful-stop API, call that on shutdown instead, and let the work finish by itself. Here the server stands in for such a library:

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

`withShutdownHandler(on:_:operation:)` calls the handler when shutdown is requested (at once, if it already was) and removes it when the operation ends:

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

`shutdownTimeout` bounds the whole graceful stop. If the body and dispose take longer, the service is cancelled.

Dispose runs after the body returns, so a resource drains and closes in its own dispose without ever seeing `shutdown`.

## Stopping

| Stage | Triggered by | What happens |
|---|---|---|
| 1. graceful | a signal, or the body returning | `shutdown` is requested; the `shutdownTimeout` clock starts |
| 2. cancel | a signal during stage 1, the timeout passing, or cancelling the calling task | the service is cancelled; dispose still runs |
| 3. kill | a signal during stage 2 | the signal's default action is restored and the signal re-sent; the process ends |

Each signal from `shutdownSignals` moves the stop one stage forward. The signals are taken over before acquire and released after dispose, so they can never kill the process mid-cleanup by accident.

In stage 2, dispose runs in a cancelled task. Cleanup that must finish anyway uses fp-swift-bracket's `BracketAsync(acquire:uncancellableDispose:)`.

## Reference

### Service

```swift
Service(
    _ service: BracketAsync<Resource, Failure>,      // the composed services
    shutdownSignals: [Int32] = [],                   // signals taken over for the run
    shutdownTimeout: Duration? = nil,                // how long stage 1 may take
    clock: ServiceClock = .continuous,               // tests inject a manual clock
    observe: ((ServiceEvents<Failure>) async -> Void)? = nil
)

await withService(body)   // body: (Resource, Shutdown) async -> Result<Void, Failure>
await withService()       // default body: wait for shutdown
```

A `Service` value runs once; calling it twice doesn't compile. Brackets stay reusable, so build a new `Service` for another run. The call returns after dispose has finished, the signals are released and the observer has returned.

### Results

| What happened | Result |
|---|---|
| acquire failed | `.failure(.startFailed(e))` — body and dispose skipped |
| the body failed | `.failure(.serveFailed(e))` |
| dispose failed | `.failure(.stopFailed(e))` |
| both failed | `.failure(.serveAndStopFailed(serve:stop:))` |
| the timeout passed | `.failure(.shutdownTimeout(after:))` |
| otherwise | `.success(ServiceOutcome)` |

`ServiceOutcome` holds what the stop events said:

| Field | Meaning |
|---|---|
| `shutdownReason` | why the graceful shutdown began: `.serveReturned` or `.signal(n)`; `nil` if there was none (the caller cancelled while it was running) |
| `cancellationReason` | `nil` if it stopped gracefully; otherwise why it was cancelled: `.signal(n)` or `.caller` |
| `stopDuration` | from the end of the body to the end of dispose |

### Events

`ServiceEvents<Failure>` is an `AsyncStream<Result<ServiceEvent, ServiceError<Failure>>>`. A SIGTERM, then a second SIGTERM while shutting down:

```
.success(.started)
.success(.ready)
.success(.signal(SIGTERM))
.success(.shuttingDown(.signal(SIGTERM)))
.success(.signal(SIGTERM))
.success(.cancelling(.signal(SIGTERM)))
.success(.stopped(ServiceOutcome(shutdownReason: .signal(SIGTERM), cancellationReason: .signal(SIGTERM), stopDuration: …)))
```

Failures arrive as `.failure` where they happen. A run whose acquire failed ends with `.failure(.startFailed)` instead of `.stopped`. If the calling task is cancelled, the observer is cancelled too and may miss the last events; the result still reports the cancellation.

### Notes

- **Build brackets outside the main actor.** `Service` takes the bracket, the body and the observer as `sending`, so they can run in child tasks. Closures written on the main actor are isolated to it and can't be sent. Build them in top-level (`nonisolated`) functions, as the example does.
- **Throwing code:** fp-swift-bracket's `BracketAsync.throwing(acquire:dispose:)` bridges it into a bracket.

## ProcessSignals

A separate product with no package dependencies: process signals as an `AsyncStream`, on Dispatch signal sources. `Service` uses it; you can use it on its own.

```swift
import ProcessSignals

for await signal in await processSignals([SIGTERM, SIGINT]) {
    print(signalName(signal))   // "SIGTERM"
}
```

- **Startup:** `processSignals` returns once every source is registered, so a signal sent right after the call is not missed.
- **Deliveries:** each delivery is one element. Signals sent in the same instant can merge: the kernel keeps only one pending instance of a standard signal (Darwin's kqueue still counts every send).
- **While the stream lives:** the signals' default actions are off.
- **Ending the stream:** cancelling the task that iterates it ends it. That releases the signals and restores their previous dispositions. Breaking out of the loop does not end the stream while it is still referenced.
- **No extra thread:** Dispatch delivers signals without a thread of our own.
- **Reference:** the [Signal Reference](https://swiftpackageindex.com/velocityzen/fp-swift-service/documentation/processsignals/signalreference) explains what each signal means, its default action, and which ones to take over.
- **Names:** `signalName(_:)` gives a signal's conventional name, such as `"SIGTERM"`, or `"signal N"` for an unknown number. It matches against the platform's own constants, because the numbers differ between platforms.
