# ``ProcessSignals``

Process signals as an `AsyncStream`, on Dispatch signal sources. No package dependencies.

## Overview

```swift
import ProcessSignals

for await signal in await processSignals([SIGTERM, SIGINT]) {
    print(signalName(signal))   // "SIGTERM"
}
```

- **Startup:** ``processSignals(_:)`` returns once every source is registered, so a signal sent right after the call is not missed.
- **Deliveries:** each delivery is one element, even when several arrive together.
- **While the stream lives:** the signals' default actions are off, so they can't end the process.
- **Ending the stream:** cancelling the task that iterates it ends it. That cancels the sources and restores the previous dispositions. Breaking out of the loop does not end the stream while it is still referenced.
- **No extra thread:** Dispatch delivers signals without a thread of its own.
- **Names:** ``signalName(_:)`` gives a signal's conventional name, such as `"SIGTERM"`, matched against the platform's own constants.

Dispositions are process-wide: take over each signal in one stream at a time. Which signals to take over, and which to leave alone, is in <doc:SignalReference>. `FPService`'s `Service` uses this library for its `shutdownSignals`.

## Topics

### Guides

- <doc:SignalReference>

### Signals

- ``processSignals(_:)``
- ``signalName(_:)``
