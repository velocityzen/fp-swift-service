# Getting Started

Define services as brackets, compose them, run them, and give them work to do.

## Overview

The code in this article is the package's `Example` target, a CLI with one subcommand per step (`swift run Example <step>`).

### Define services

A service is a function that returns a bracket. Acquire starts it, and the service is ready when acquire returns. Dispose stops it. A dependency is just a parameter: `withServer(_:)` needs a `Database`.

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

Do-notation composes them into one bracket. The composition order is the dependency order: services start top to bottom and stop bottom to top.

<!-- example: dependencies -->
```swift
func withDependencies() -> BracketAsync<(Database, Server), ExampleError> {
    BracketAsyncDo<ExampleError>()
        .bind { withDatabase() }
        .bind { database in withServer(database) }
}
```

### Run them

``Service`` takes over the listed signals. Calling it starts the services and waits for a signal, then stops them in reverse order (`swift run Example`, then Ctrl-C).

<!-- example: quickstart -->
```swift
let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
let result = await withService()
```

The result is a `Result<ServiceOutcome, ServiceError<ExampleError>>`. A ``ServiceOutcome`` says why the service stopped; a ``ServiceError`` names the phase that failed and carries your own error untouched.

### Watch events

Pass a closure to observe every lifecycle event as a stream of `Result`s (`swift run Example events`). The stream ends by itself after the last event.

<!-- example: events -->
```swift
let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM]) { events in
    for await event in events {
        switch event {
            case .success(let event): print("event: \(event)")
            case .failure(let error): print("error: \(error)")
        }
    }
}
let result = await withService()
```

Because ``ServiceEvents`` is an `AsyncSequence` of `Result`s, fp-swift's combinators (`failures()`, `successes()`, `tap`) and fp-swift-pipe's `FromResult` work on it directly.

### Do work

Calling the service with no argument just waits for a signal. To do work while the services are up, pass a body. It gets the acquired resources, and when it returns, the service stops (`swift run Example job`).

<!-- example: job -->
```swift
/// Does a fixed amount of work, then returns — which stops the service.
func importBatches(_ resources: (Database, Server), _: Shutdown) async -> Result<Void, ExampleError> {
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

A body that runs until it is told to stop uses its second argument, ``Shutdown``. See <doc:Stopping>.

### Build brackets outside the main actor

``Service`` takes the bracket, the body and the observer as `sending`, so they can run in child tasks. Closures written on the main actor are isolated to it and can't be sent, so build brackets in top-level (`nonisolated`) functions, as above.
