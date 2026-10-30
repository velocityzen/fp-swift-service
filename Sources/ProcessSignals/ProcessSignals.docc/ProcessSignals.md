# ``ProcessSignals``

Process signals as an `AsyncStream`, delivered through Dispatch (on Windows, console events). No package dependencies.

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
- **While the stream lives:** a handler of its own catches the signals, so their default actions can't end the process. Like any handler, it can interrupt a blocking call on a thread that doesn't block the signal; with `SA_RESTART`, most calls resume.
- **Child processes:** `exec` resets a caught signal to its default action, so a child started with `posix_spawn`, `fork` and `exec`, or `system()` is unaffected. That is why the signals are caught, never set to `SIG_IGN`, which survives `exec`. `SIGCHLD` can be subscribed to as well, and children can still be waited for.
- **Ending the stream:** cancelling the task that iterates it ends it. That unsubscribes it from the signals; the last subscriber to a signal restores its previous disposition. Breaking out of the loop does not end the stream while it is still referenced.
- **Sharing:** several streams can subscribe to the same signal at once, and each gets every delivery.
- **No extra thread:** Dispatch delivers signals without a thread of its own.
- **Names:** ``signalName(_:)`` gives a signal's conventional name, such as `"SIGTERM"`, or `"signal N"` for an unknown number, matched against the platform's own constants.
- **Windows:** there are no signals. Ctrl-C, Ctrl-Break, and the console closing, logoff or shutdown arrive as console control events, delivered as `SIGINT`, `SIGBREAK` and `SIGTERM`, the only signals that can be subscribed to there, so `[SIGINT, SIGTERM]` works everywhere. Windows ends the process once a close, logoff or shutdown event is handled, so the handler holds it until no stream is subscribed to `SIGTERM`: the run's dispose gets the time Windows allows. The handler routine runs on a thread Windows starts for each event.

Which signals to subscribe to, and which to leave alone, is in <doc:SignalReference>. `FPService`'s `Service` uses this library for its `shutdownSignals`.

## Topics

### Guides

- <doc:SignalReference>

### Signals

- ``processSignals(_:)``
- ``signalName(_:)``
