# Getting Started

Define services as brackets, compose them, run them, and give them work.

## Overview

The code is the package's `Example` target; run each step with `swift run Example <step>`.

### Define services

A service is a function that returns a bracket: acquire starts it, dispose stops it. A dependency is a parameter.

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

### Compose them

Do-notation composes them into one bracket. Services start in order and stop in reverse.

<!-- example: dependencies -->
```swift
func withDependencies() -> BracketAsync<(Database, Server), ExampleError> {
    BracketAsyncDo<ExampleError>()
        .bind { withDatabase() }
        .bind { database in withServer(database) }
}
```

### Run them

``Service`` subscribes to the signals, starts the services, waits for a signal, then stops them (`swift run Example`, then Ctrl-C).

<!-- example: quickstart -->
```swift
let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
let result = await withService()
```

A ``ServiceOutcome`` says why the service stopped; a ``ServiceError`` names the failed phase and carries your own error.

### Watch events

An observer receives every lifecycle event as a stream of `Result`s, which finishes after the last event (`swift run Example events`).

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

fp-swift's combinators (`failures()`, `successes()`, `tap`) and fp-swift-pipe's `FromResult` work on ``ServiceEvents`` directly.

### Do work

To do work while the services are up, pass a body. It receives the resources; when it returns, the service stops (`swift run Example job`).

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

A long-running body watches its second argument, ``Shutdown``. See <doc:Stopping>.

### Build brackets outside the main actor

The bracket, body and observer are `sending`, because they run in tasks that stage 2 can cancel. Main-actor closures can't be sent, so build them in top-level functions, as above.
