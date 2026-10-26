# Signal Reference

What each signal means, what it does by default, and whether to subscribe to it with ``processSignals(_:)``.

## Overview

A signal's *default action* is what happens when the process has not subscribed to it: the process is terminated, terminated with a core dump, stopped, continued, or the signal is ignored. While a ``processSignals(_:)`` stream lives, the default action is off and the signal arrives in the stream instead. ``signalName(_:)`` gives each one's name.

Signal numbers differ between platforms (`SIGUSR1` is 30 on Darwin and 10 on Linux), so always use the constants, never the numbers.

### Stopping a process

These are the signals to list in a shutdown, such as `FPService`'s `shutdownSignals`.

| Signal | Sent by | Default action | Meaning |
|---|---|---|---|
| `SIGTERM` | `kill <pid>`, launchd, systemd, Docker, Kubernetes | terminate | "Please stop." The polite request to shut down; service managers send it first, then `SIGKILL` after a grace period |
| `SIGINT` | Ctrl-C in a terminal | terminate | Interrupt from the keyboard |
| `SIGHUP` | the terminal closing; `kill -HUP` | terminate | The controlling terminal hung up. Daemons, which have no terminal, conventionally treat it as "reload configuration" |
| `SIGQUIT` | Ctrl-\\ in a terminal | terminate with a core dump | Quit from the keyboard, asking for a core dump |

### Can't be subscribed to

``processSignals(_:)`` leaves these out.

| Signal | Default action | Meaning |
|---|---|---|
| `SIGKILL` | terminate | Kill the process at once. It cannot be caught, blocked or ignored: no cleanup runs |
| `SIGSTOP` | stop | Pause the process. It cannot be caught, blocked or ignored; `SIGCONT` resumes it |

### Faults: don't subscribe to these

The kernel sends these to the thread that caused the fault, when it happens. The faulting instruction runs again if the signal is ignored, so subscribing to one doesn't recover the process; it hides the crash or loops on it. Let them crash and report.

| Signal | Default action | Meaning |
|---|---|---|
| `SIGSEGV` | core dump | Invalid memory access (segmentation violation) |
| `SIGBUS` | core dump | Bus error: misaligned access, or access past the end of a mapped file |
| `SIGILL` | core dump | Illegal instruction |
| `SIGFPE` | core dump | Arithmetic error, such as integer division by zero |
| `SIGTRAP` | core dump | Trace or breakpoint trap; debuggers use it, and Swift runtime traps can raise it |
| `SIGABRT` | core dump | `abort()` was called |
| `SIGSYS` | core dump | A system call that does not exist was invoked |
| `SIGEMT` (Darwin) | core dump | An emulator trap |

### Terminal and job control

| Signal | Sent by | Default action | Meaning |
|---|---|---|---|
| `SIGTSTP` | Ctrl-Z in a terminal | stop | Suspend from the keyboard; unlike `SIGSTOP`, it can be subscribed to |
| `SIGCONT` | `fg`, `bg`, `kill -CONT` | continue | Resume after a stop |
| `SIGTTIN` | the terminal | stop | A background process tried to read from the terminal |
| `SIGTTOU` | the terminal | stop | A background process tried to write to the terminal |
| `SIGWINCH` | the terminal | ignore | The terminal window changed size |
| `SIGINFO` (Darwin) | Ctrl-T in a terminal | ignore | A status request from the keyboard |

### Notifications

| Signal | Default action | Meaning |
|---|---|---|
| `SIGCHLD` | ignore | A child process stopped or exited |
| `SIGPIPE` | terminate | A write to a pipe or socket whose reader has gone. Servers usually ignore it and handle the write error instead |
| `SIGURG` | ignore | Urgent (out-of-band) data arrived on a socket |
| `SIGIO` | ignore (Linux: terminate) | Asynchronous I/O is possible |
| `SIGALRM` | terminate | The timer set with `alarm()` expired |
| `SIGVTALRM` | terminate | The virtual (CPU time) timer expired |
| `SIGPROF` | terminate | The profiling timer expired |
| `SIGXCPU` | terminate (Linux: core dump) | The CPU time limit was exceeded |
| `SIGXFSZ` | terminate (Linux: core dump) | The file size limit was exceeded |
| `SIGPWR` (Linux) | terminate | A power failure |
| `SIGSTKFLT` (Linux) | terminate | A coprocessor stack fault; unused on modern systems |

### Yours to define

| Signal | Default action | Meaning |
|---|---|---|
| `SIGUSR1` | terminate | No fixed meaning: a custom message from another process, such as "dump status" or "rotate logs" |
| `SIGUSR2` | terminate | The same, a second one |

Because their default action terminates the process, subscribe to them before anyone sends them.

The Darwin defaults are those of `signal(3)`. The Linux differences noted are from Linux's `signal(7)`.
