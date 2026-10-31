# ``ProcessSignals``

Process signals as an `AsyncStream`, with no package dependencies.

## Overview

```swift
import ProcessSignals

for await signal in await processSignals([SIGTERM, SIGINT]) {
    print(signalName(signal))   // "SIGTERM"
}
```

- **Subscribing:** ``processSignals(_:)`` returns once the signals are subscribed to, so none sent after the call is missed. One sent during the call is delivered or has its previous effect.
- **Skipped signals:** those that can't be caught (`SIGKILL`, `SIGSTOP`, or numbers the platform lacks or reserves). If none are left, the stream is already finished.
- **While the stream lives:** the signals' default actions are suspended. The handler can interrupt a blocking call; with `SA_RESTART`, most resume.
- **Child processes:** the signals are caught, not ignored, so `exec` resets them and children start with the defaults. `SIGCHLD` can be subscribed to, and children can still be waited for.
- **Ending:** cancelling the iterating task ends the stream; the last stream on a signal restores its previous disposition. Breaking out of the loop doesn't end it.
- **Sharing:** several streams can share a signal; each gets every delivery. Signals sent at the same instant may merge, except on Darwin.
- **Windows:** console events arrive as `SIGINT` (Ctrl-C), `SIGBREAK` (Ctrl-Break) and `SIGTERM` (close, logoff, shutdown), the only signals available there. A `SIGTERM` event is held while any stream subscribes to `SIGTERM`, which gives cleanup the few seconds Windows allows.

``signalName(_:)`` gives a signal's name, such as `"SIGTERM"`. <doc:SignalReference> lists what each signal means and which to subscribe to.

## Topics

### Guides

- <doc:SignalReference>

### Signals

- ``processSignals(_:)``
- ``signalName(_:)``
