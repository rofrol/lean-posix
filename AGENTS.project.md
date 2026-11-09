# lean-posix's own rules for agents

- Everything is Lean: the bindings, their tests, the checks (`lake build`,
  `lake test`) and any helper or stand-in a test needs. No shell, bash, perl,
  Python or C files in this repository; C lives only inside each binding's
  `@[extern c inline "..."]` expression, which declares every function it calls,
  so there is no header and no build step beyond Lake's.
- The queue is `issues/ORDER` with one `issues/ID.md` per item, in rr's format:
  sections `## Next, in order`, `## Proposed`, `## Needs a decision`; one
  `ID TITLE` line per item, ID six characters of a-z and 2-7; the item's file
  starts with its title. It changes only through rr2's
  `rr2 issue add|move|edit|finish` (run from rr2's checkout as
  `lake -d <rr2> exe rr2 issue ...` in this repository), under the queue lock,
  each change committed at once; never by hand or with `ad todo`, which edits
  without the lock. An agent rr2 runs on an item changes no file under
  `issues/`: rr2 finishes the item and adds its proposals.
- macOS only: every constant (flags, errnos, ioctl numbers, struct layouts,
  `__error()` for errno) is macOS's, written as a number in the expression and
  listed in its module's header. A Linux port would be new work (inotify and
  poll, Linux termios), not a change to a binding.
- Toolchain: `lean-toolchain` (a Lean nightly); no Lake dependencies.
- Each binding's contract is its doc comment, and consumers rely on it: a
  change to what a public declaration returns, blocks on, or leaves open or
  inherited is a public contract change (AGENTS.md, Human Responsibility).
- Consumers pin a commit; each pinned commit carries a tag `pin/<sha12>` here
  (`README.md`, "Use"). Moving rr2's tags when this history is rewritten is
  the owner's exception in `DECISIONS.md` ("History and pin tags").

## Architecture map

There is no shared core beyond the convention every module follows: a
descriptor or pid is a `UInt32`; a failure mostly comes back as a value (an
errno, a large number, the high bit set with the errno, or an `Except`), as
each doc comment states; `spawn`, `pipe`, `waitpid` and `waitOutcome` throw, and
`trySpawn` throws on a descriptor 0, 1 or 2. Whether a child inherits a
descriptor made here is stated in its doc comment ("which no child
inherits") where it is close-on-exec. `Posix.lean` imports
every module; consumers `import Posix`.

Modules, each under `Posix/`, all in `namespace Posix`:

- `Fd.lean`: descriptors. `dup2`, `dupPrivate`, `close`, `read`, `readAt` (by
  path, opened and closed per call), `readFileAt` (device, inode, size and
  bytes from one descriptor; `FileAt`, `noSuchFile`), `drainNow` (a pipe's
  bytes without waiting), `handleFd` (the descriptor under an
  `IO.FS.Handle`), `isatty`, `strerror`, `setTimes` (`utimes`).
- `Pty.lean`: `openPty` (raw), `loginTty`, `winSize` (stdout's),
  `winSizeOf` (any descriptor's, or the errno), `setWinSize`.
- `Process.lean`: `exec` (`execvp` in place), `execResume` (`execv` of
  `path --resume`), `killNow` (SIGKILL to a process or group), `kill` (any signal, the errno), `alarm`,
  `defaultSignals`, `defaultPipe`, `processStart` (`proc_pidinfo` start time),
  `peakRss`.
- `Spawn.lean` (imports `Fd`): `trySpawn`/`spawn` (fork, a close-on-exec
  result pipe, `execve` along `candidates`, the PATH lookup; optionally
  `setsid` and a controlling terminal; `SpawnFailure`, `inherit`, `devNull`),
  `pipe`, `waitpid`, `waitOutcome` (`ExitOutcome`: an exit code or a signal,
  decoded by `ExitOutcome.ofStatus` with theorems), `writeAll`. `spawnRaw` is public but internal to
  `trySpawn`. One process-wide lock (`spawnLock`) serializes `pipe` and spawn.
- `Lock.lean`: `lockFile`/`unlock`, `lockHanded` (a lock handed across
  exec; `lockHeld`, `lockElsewhere`), `lockDir`, `link`. `lockRaw` is public
  but internal to `lockFile`.
- `Kqueue.lean` (imports `Fd`): four kinds of waiting. A process and its
  output pipe and a directory (`openEvents`, `watchSession`, `nextEvent`,
  `unwatchRead`); a full-screen program's stdin, SIGWINCH, files and process
  exits (`kqOpen`, `kqSetup`, `watch`, `watchExit`, `unwatchExit`, `kqWait`,
  `kqWaitFor`); the exits of processes that need not be children
  (`watchExits`, `ExitWatch`, `ExitWatch.forget`, `ExitWatch.wait`,
  `awaitExits`); catchable signals as events, each caught by a no-op handler
  that exec resets (`catchSignals`, `nextSignal`).
- `Term.lean`: `termCtl` (one entry point by numeric `op`: enter, leave,
  install signal handlers, hand the terminal across exec through
  `LEAN_POSIX_TERMIOS`, or a signal number arriving) and `termEnter`. Its C
  keeps the saved terminal and an "entered" flag in two statics, so the
  terminal state is process-global.

Allowed dependency directions: `Spawn` and `Kqueue` may import `Fd`
(`Spawn` also imports `Std.Sync.Mutex` and `Std.Tactic.BVDecide`); no other
module imports another; nothing here imports a consumer. The tests import
`Posix` only.

## Trust, effects and failure

- Every binding is FFI into libc on macOS, unchecked by Lean: an expression's
  struct layout or constant that is wrong for the running OS is undefined
  behavior, caught only by `lake test` on that OS.
- Privileged or process-wide effects: `exec`/`execResume` replace the
  process; `killNow` and `kill` signal any pid or group the caller names;
  `catchSignals` catches the signals it is given process-wide with a no-op handler; `termCtl`
  installs handlers for every catchable terminating signal, ignores SIGTSTP,
  changes stdin's termios and writes escape sequences to stdout;
  `defaultSignals`/`defaultPipe` change signal dispositions; `trySpawn`
  forks, and its child calls only async-signal-safe functions before exec.
- Arguments are passed to `execve`/`execvp` as an array, never through a
  shell; validating them against the consumer's rules is the consumer's job.
- The library owns no persistent data. Files it opens, locks or links are
  the caller's paths.

## Consumers

Found by the lakefiles that require `«lean-posix»` (2026-11-09):

- rr2 (`lakefile.lean`, pinned commit).
- rr (`lakefile.lean`, pinned commit).
- lean-tui (`lakefile.lean`, pinned commit), and through it lean-markdown,
  which requires lean-tui only.

Other users, if any, are not known here.

## Verification

- `lake build`: the library.
- `lake test`: the `tests` executable (`Tests/Main.lean`), each binding
  against the real system in a temporary directory, the terminal tests in
  children it starts on a pty (`tests term`, `tests term-signal`); the exit
  status is the number of failures. Some tests run system programs (for
  example `stat(1)`) to compare results.
- `lake exe spawnstress ROUNDS SPAWNS THREADS [KIND,...]`
  (`Diag/SpawnStress.lean`): a diagnostic stress run of `trySpawn` in fresh
  processes whose other threads call into libSystem, counting each child's
  outcome; not a test, and not run by `lake test`. Its exit status is 1 when
  any spawn did not reach its exec and exit 0.

## Types for lifecycles and invariants (Lean)

Source: the principles of Guyingjie's post "Thinking in types"
(https://x.com/guyingjie129/status/2116885870049714505). The rules below are
normative; the post is not required reading.

- Think in algebraic data types, not in state diagrams or flags: a lifecycle
  is a sum whose constructors carry only the data valid in that phase (no bag
  of flags and Options); decisions are a pure
  `step : State → Input → State × Array Out`, effects done by a thin IO
  shell. In this library most code is the shell: a binding is one C
  expression, and what it decides there cannot be proved in Lean.
- Make illegal states and illegal arguments unrepresentable where the type
  says it plainly: an inductive instead of a numeric code (an `op`, a stage
  number, a bit in a mask), an `Except` or a structure instead of a high bit
  or a "large number" a caller must decode. Keep the raw encoding private to
  the module that decodes it. Otherwise state the guarantee as a theorem next
  to the pure Lean function it holds for (decoding, `candidates`,
  `watchExits`'s bookkeeping), its doc comment saying what it guarantees and
  what it assumes about the OS. Tests cover what neither reaches (the C, the
  kernel, real processes and terminals) and that the model reaches its states
  (no vacuous theorems).
- This refines AGENTS.md Rule 4: an inductive with payloads is its "explicit
  state type"; a transition or argument the type rules out needs no rejection
  test.
- Theorem statements and the definitions they rest on are the owner's
  decision; never weaken one to make a proof pass. Changing a public type to
  carry an invariant changes the contract of every consumer above: it needs
  the owner's approval here, and each consumer moves its pin in its own
  repository, through its own queue.
- Not for linear, single-owner or ephemeral code, nor for parsing at the I/O
  boundary: a plain function or enum is enough there.
- The bindings predate these rules: `termCtl`'s numeric `op`, the high-bit
  and "large number" results and the public `spawnRaw` and `lockRaw` are the
  current public contract. Moving one of them into a type is a contract
  change, proposed as its own queue item, never done in passing.
