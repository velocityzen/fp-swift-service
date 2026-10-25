# ``FPService``

A functional service lifecycle: a service is a `BracketAsync`, services compose with do-notation, and running them returns a `Result`.

## Overview

Each service is a function that returns a bracket: acquire starts it, dispose stops it. A dependency is just a parameter. Compose the brackets into one with `BracketAsyncDo`, the composition order is the dependency order, and run it with ``Service``:

```swift
let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
let result = await withService()   // Result<ServiceOutcome, ServiceError<AppError>>
```

- **Stopping has three stages.** Graceful, then cancel, then end the process, each reached by one more signal from `shutdownSignals`. See <doc:Stopping>.
- **Events are a stream of `Result`s.** Pass an observer to log or measure them; fp-swift's combinators work on the stream directly.
- **Nothing throws.** The services' own error type comes back untouched inside ``ServiceError``.

Signals come from the companion `ProcessSignals` library.

## Topics

### Essentials

- <doc:GettingStarted>
- ``Service``
- ``Service/init(_:shutdownSignals:shutdownTimeout:clock:observe:)``
- ``Service/callAsFunction(_:)``

### Stopping

- <doc:Stopping>
- ``Shutdown``
- ``withCancellation(on:_:)``
- ``withShutdownHandler(on:_:operation:)``

### Results

- ``ServiceOutcome``
- ``ServiceError``
- ``ServicePhase``

### Events

- ``ServiceEvents``
- ``ServiceEvent``
- ``ShutdownReason``
- ``CancellationReason``

### Testing

- ``ServiceClock``
