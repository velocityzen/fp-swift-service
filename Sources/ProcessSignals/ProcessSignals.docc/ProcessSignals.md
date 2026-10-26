# ``ProcessSignals``

Process signals as an `AsyncStream`, delivered through Dispatch. No package dependencies.

## Overview

```swift
import ProcessSignals

for await signal in await processSignals([SIGTERM, SIGINT]) {
    print(signalName(signal))   // "SIGTERM"
}
```

- **Startup:** ``processSignals(_:)`` returns once every signal is subscribed to, so a signal sent right after the call is not missed. One sent during the call has its previous effect or is delivered; it is never lost.
- **Left out:** a signal that can't be subscribed to is skipped: a number the platform doesn't have (on Linux, also one the C library keeps for itself), or `SIGKILL` and `SIGSTOP`, which can't be caught. If none is left, the stream is already finished.
- **Deliveries:** each delivery is one element. Signals sent in the same instant can merge: the kernel keeps only one pending instance of a standard signal (Darwin's kqueue still counts every send).
- **While the stream lives:** the signals' default actions are off, so they can't end the process.
- **Child processes:** on Darwin a subscribed signal is set to `SIG_IGN`, and ignored signals survive `exec`: a child started with `posix_spawn`, `fork` and `exec`, or `system()` can't be stopped with that signal. Reset the child's signals as it starts (`POSIX_SPAWN_SETSIGDEF`), as Foundation's `Process` does. On Linux the signal gets a handler, which `exec` resets.
- **Ending the stream:** cancelling the task that iterates it ends it. That unsubscribes it from the signals; the last subscriber to a signal restores its previous disposition. Breaking out of the loop does not end the stream while it is still referenced.
- **Sharing:** several streams can subscribe to the same signal at once, and each gets every delivery.
- **No extra thread:** Dispatch delivers signals without a thread of its own.
- **Names:** ``signalName(_:)`` gives a signal's conventional name, such as `"SIGTERM"`, or `"signal N"` for an unknown number, matched against the platform's own constants.

Which signals to subscribe to, and which to leave alone, is in <doc:SignalReference>. `FPService`'s `Service` uses this library for its `shutdownSignals`.

## Topics

### Guides

- <doc:SignalReference>

### Signals

- ``processSignals(_:)``
- ``signalName(_:)``
