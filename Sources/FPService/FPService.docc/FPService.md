# ``FPService``

A functional service lifecycle: services are `BracketAsync` values composed with do-notation, and running them returns a `Result`.

## Overview

Each service is a function that returns a bracket. Compose them with `BracketAsyncDo`, in dependency order, and run the result with ``Service``:

<!-- example: quickstart -->
```swift
let withService = Service(withDependencies(), shutdownSignals: [SIGINT, SIGTERM])
let result = await withService()
```

`result` is a `Result<ServiceOutcome, ServiceError<ExampleError>>`. The code is the package's Example; see <doc:GettingStarted>.

- **Three stopping stages:** graceful, cancel, then end the process, each reached by another signal. See <doc:Stopping>.
- **Events:** an observer receives the lifecycle as a stream of `Result`s.
- **Nothing throws:** the services' own error comes back untouched inside ``ServiceError``.

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
