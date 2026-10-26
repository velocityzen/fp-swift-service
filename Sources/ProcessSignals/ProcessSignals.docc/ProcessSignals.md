# ``ProcessSignals``

Process signals as an `AsyncStream`, delivered through Dispatch. No package dependencies.

## Overview

```swift
import ProcessSignals

for await signal in await processSignals([SIGTERM, SIGINT]) {
    print(signalName(signal))   // "SIGTERM"
}
```

- **Startup:** ``processSignals(_:)`` returns once every signal is taken over, so a signal sent right after the call is not missed. One sent during the call has its previous effect or is delivered; it is never lost.
- **Left out:** a signal that can't be taken over is skipped: a number the platform doesn't have (on Linux, also one the C library keeps for itself), or `SIGKILL` and `SIGSTOP`, which can't be caught. If none is left, the stream is already finished.
- **Deliveries:** each delivery is one element. Signals sent in the same instant can merge: the kernel keeps only one pending instance of a standard signal (Darwin's kqueue still counts every send).
- **While the stream lives:** the signals' default actions are off, so they can't end the process.
- **Ending the stream:** cancelling the task that iterates it ends it. That releases the signals; the last stream holding a signal restores its previous disposition. Breaking out of the loop does not end the stream while it is still referenced.
- **No extra thread:** Dispatch delivers signals without a thread of its own.
- **Names:** ``signalName(_:)`` gives a signal's conventional name, such as `"SIGTERM"`, matched against the platform's own constants.

- **Sharing:** several streams can take over the same signal at once, and each gets every delivery.

Which signals to take over, and which to leave alone, is in <doc:SignalReference>. `FPService`'s `Service` uses this library for its `shutdownSignals`.

## Topics

### Guides

- <doc:SignalReference>

### Signals

- ``processSignals(_:)``
- ``signalName(_:)``
