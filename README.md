# lean-posix

POSIX calls Lean 4's library lacks, as Lean bindings, for macOS. Each binding is
one `@[extern c inline "..."]` expression that declares the C functions it calls,
so there is no C file, no header and no build step beyond Lake's. Every binding's
contract is in its doc comment.

Written for rr's watcher, supervisor and terminal UI, and kept apart so that
their shells hold no C of their own.

## What it binds

| Module          | What                                                              |
| --------------- | ----------------------------------------------------------------- |
| `Posix.Fd`      | `dup`, `dup2`, `close`, `read`, `pread`, a pipe drained without waiting, the descriptor under a `Handle`, `isatty`, `strerror` |
| `Posix.Pty`     | a raw pty (`openpty`), `login_tty`, the window size               |
| `Posix.Process` | `execvp`, `execv` of a new build, `kill` of a process or group, `alarm`, default signals before exec, peak RSS |
| `Posix.Spawn`   | a spawn that says whether its exec failed (fork, a close-on-exec pipe for the exec's result, `execve` along PATH), `pipe`, `waitpid`, a write of every byte |
| `Posix.Lock`    | exclusive `flock` on a file or a directory, `link` that fails on a taken name |
| `Posix.Kqueue`  | kqueue: a process's exit with its output pipe and a directory; the exits of processes that need not be children; stdin, SIGWINCH and files for a full-screen program |
| `Posix.Term`    | a full-screen terminal in raw mode, restored on every exit and signal that can be caught, and handed to a new build across `exec` |

## Why not `Std.Internal.UV`

Lean ships libuv bindings in `Std.Internal.UV` (as of Lean v4.34.0: TCP, UDP,
timers, DNS, signals, system information and the event loop behind
`Std.Async`). They do not cover what these programs need: no pty, no file
watching (libuv's `fs_event` is not bound), no process groups, no exec in the
same process, no terminal modes, no `flock`. `IO.Process` spawns and waits, but
cannot report a process's exit as an event beside its output, nor kill a group,
nor tell a program whose exec failed from one that ran and died.

## Platform

macOS only: the constants (flags, errnos, ioctl numbers, `struct kevent`'s
layout, `__error()` for errno) are macOS's, written as numbers in each expression
and listed in each module's header.

## Use

```lean
require «lean-posix» from git "https://github.com/rofrol/lean-posix" @ "<commit>"
```

and `import Posix`. Pin a commit; each pinned commit carries a tag `pin/<sha12>`
so it stays fetchable.

## Tests

    lake test

runs each binding against the system: a pty, locks, links, kqueue events of a
process, its pipe, a directory and files, the exits of processes watched
while alive, after their exit and after their reaping, exec, kill, spawns that
run and spawns whose exec or setup fails, each with its errno, and the terminal's full
screen entered, left, and left on a signal, in children on a pty.

## License

MIT, see `LICENSE`.
