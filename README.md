# lean-posix

POSIX calls Lean 4's library lacks, as Lean bindings, for macOS. The bindings of
`Posix.Fd`, `Posix.Pty`, `Posix.Lock`, `Posix.Process`, `Posix.Spawn`,
`Posix.Kqueue` and `Posix.Term` are C in `c/fd.c`, `c/pty.c`, `c/lock.c`,
`c/process.c`, `c/spawn.c`, `c/kqueue.c` and `c/term.c`, which Lake compiles
against the macOS SDK's headers. Every binding's contract is in its doc
comment.

Written for rr's watcher, supervisor and terminal UI, and kept apart so that
their shells hold no C of their own.

## What it binds

| Module          | What                                                              |
| --------------- | ----------------------------------------------------------------- |
| `Posix.Fd`      | `dup`, `dup2`, `close`, `read`, `pread`, a pipe drained without waiting, the descriptor under a `Handle`, `isatty`, `strerror`, a file's times (`utimes`), a file's device, inode, size and bytes from an offset, on one descriptor (`fstat`, `pread`), a line appended after a check of the last byte, on one descriptor (`O_APPEND`, `fstat`, `pread`, `write`) |
| `Posix.Pty`     | a raw pty (`openpty`), `login_tty`, the window size, read and set  |
| `Posix.Process` | `execvp`, `execv` of a new build, `kill` of a process or group, the processes of a session and the end of all of them (`proc_listallpids`, `getsid`, SIGKILL in rounds until none is left), `alarm`, default signals before exec, a process's start time (`proc_pidinfo`), peak RSS |
| `Posix.Spawn`   | a spawn that says whether its exec failed (`posix_spawn` along PATH, no `fork`), in a session of its own, on a controlling terminal if asked (through the helper `lean-posix-ctty`), handing the child the descriptors named and no other if asked (`POSIX_SPAWN_CLOEXEC_DEFAULT`, `posix_spawn_file_actions_addinherit_np`), the child's pid, session and start written and synced to a descriptor before its program runs if asked (through the same helper), `pipe`, `waitpid`, `waitOutcome` (an exit code kept apart from a signal), a write of every byte |
| `Posix.Lock`    | exclusive `flock` on a file or a directory, such a lock handed to the next program this process executes (`fstat`, `stat`), `link` that fails on a taken name |
| `Posix.Kqueue`  | kqueue: a process's exit with its output pipe and a directory; the exits of processes that need not be children; stdin, SIGWINCH, files and exits of processes for a full-screen program, waited for with or without a timeout |
| `Posix.Term`    | a full-screen terminal in raw mode, with click or any-motion mouse reports or none, restored (mouse reports off, the pointer shape reset) on every exit and signal that can be caught, and handed to a new build across `exec` |

## Why not `Std.Internal.UV`

Lean ships libuv bindings in `Std.Internal.UV` (as of Lean v4.34.0: TCP, UDP,
timers, DNS, signals, system information and the event loop behind
`Std.Async`; nightly-2026-10-25 adds nothing of the below). They do not cover what these programs need: no pty, no file
watching (libuv's `fs_event` is not bound), no process groups, no exec in the
same process, no terminal modes, no `flock`, no process's exit as an event and no process's start
time. `IO.Process` spawns and waits, but
cannot report a process's exit as an event beside its output, nor kill a group,
nor tell a program whose exec failed from one that ran and died.

## Platform

macOS only: the constants (flags, errnos, ioctl numbers, struct layouts,
`__error()` for errno) are macOS's, written as numbers in each inline expression,
listed in each module's header and checked against the SDK by `c/abi.c`; the C
files take them from the SDK's headers.

Building needs the macOS SDK, from Xcode or the Command Line Tools
(`xcode-select --install`): Lake finds it with `xcrun --show-sdk-path` and
compiles `c/*.c` with the Lean toolchain's clang. This holds for every package
that requires lean-posix, as its executables link that C.

## Use

```lean
require «lean-posix» from git "https://github.com/rofrol/lean-posix" @ "<commit>"
```

and `import Posix`. Pin a commit; each pinned commit carries a tag `pin/<sha12>`
so it stays fetchable.

A program that spawns with `ctty := true` or `record := some fd` needs the helper `lean-posix-ctty`
next to its own executable, where `trySpawn` looks for it (beside
`IO.appPath`): `lake build lean-posix/lean-posix-ctty` builds it into the
package's `.lake/build/bin`, or name it in an executable's `needs`
(`` needs := #[`@«lean-posix»/«lean-posix-ctty»] ``). Install it beside the
executable wherever that is installed. Without it, such a spawn fails with the
stage `ctty helper` and ENOENT; a helper of another lean-posix version, with
EPROTONOSUPPORT.

## Tests

    lake test

runs each binding against the system: a file read by device, inode and offset as it is appended to, truncated in place and replaced by rename, a pty, locks, a lock handed across exec, links, kqueue events of a
process, its pipe, a directory and files, the exits of processes watched
while alive, after their exit and after their reaping, on their own kqueue and a full-screen
program's, a full-screen program's wait that times out with nothing and one an event ends first, processes' start times, exec, kill, spawns that
run and spawns whose exec or setup fails, each with its errno, and the terminal's full
screen entered with and without mouse reports, left, and left on a signal, with mouse reports
turned off and the pointer shape reset, in children on a pty.

## License

MIT, see `LICENSE`.
