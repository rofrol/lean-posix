import Posix.Fd

/-!
# kqueue: file, process and signal events

Lean's library has no file watching and no process-exit event. These are the two
ways of waiting a program built on this library uses, each one blocking `kevent`:

- a process and its output pipe (`watchSession`, `nextEvent`): its end is the
  process exiting (EVFILT_PROC, NOTE_EXIT), not its output closing, which an orphan
  holding the pipe can put off for ever; and a directory, written to by others;
- stdin, the window size, files and the exits of processes (`kqOpen`, `kqSetup`,
  `watch`, `watchExit`, `kqWait`, `kqWaitFor`), for a full-screen program that
  wakes on events only, or also when a given time has passed;
- the exits of processes that need not be this program's children
  (`watchExits`, `ExitWatch.wait`), which nothing else in Lean or POSIX can wait
  for.
- catchable signals as events (`catchSignals`, `nextSignal`), for a program
  that passes them on to a child instead of dying of them.

The C is `c/kqueue.c`, which takes `struct kevent`, `struct sigaction` and every
constant from the SDK's headers.
-/

namespace Posix

/-- A descriptor of `path` for its events only, which no child inherits; a large
number when it cannot be opened. -/
@[extern "lean_posix_open_events"]
opaque openEvents (path : @& String) : IO UInt32

/-- A kqueue, which no child inherits, that reports `fd` readable, `pid`'s exit,
and a write to the directory `dir` (from `openEvents`; none when that failed);
`fd` is made non-blocking. With the high bit set, `pid` had exited already and
only `fd` and `dir` are watched. -/
@[extern "lean_posix_watch_session"]
opaque watchSession (pid fd dir : UInt32) : IO UInt32

/-- Blocks until the kqueue of `watchSession` has news: 0 the output is readable, 1
the output closed with nothing left in it, 2 the process exited (or the kqueue
failed, which ends the wait all the same), 3 the directory was written to. -/
@[extern "lean_posix_next_event"]
opaque nextEvent (kq : UInt32) : IO UInt32

/-- Stops reporting `fd`, whose writers are all gone. -/
@[extern "lean_posix_unwatch_read"]
opaque unwatchRead (kq fd : UInt32) : IO Unit

/-- A kqueue that no child inherits. -/
@[extern "lean_posix_kq_open"]
opaque kqOpen : IO UInt32

/-- Watches stdin for input and SIGWINCH, which is ignored by default and still
reaches the kqueue. -/
@[extern "lean_posix_kq_setup"]
opaque kqSetup (kq : UInt32) : IO Unit

/-- Watches the signals `sigs` on `kq` and catches each with a handler that does
nothing (a plain C `void (int)`, with SA_RESTART and an empty mask), so that it no longer ends, stops or is ignored by this process but arrives
on `kq` (EVFILT_SIGNAL): 0, or the errno of the first signal that failed, those
before it watched and caught (EINVAL (22) for SIGKILL, SIGSTOP or a number that is
no signal). Each is watched on `kq` before it is caught, so one that comes in
between still has the effect it had before the call (its default, unless the
program changed it), never a lost event. `nextSignal` reads them; `kqWait` would report
any of them as bit 2, a new window size, so give them a kqueue of their own (from
`kqOpen`) when the program also uses `kqWait`.

Caught, not ignored: an ignored signal stays ignored across exec, so a child
started afterwards (by `spawn`, `trySpawn`, Lean's spawn, `posix_spawn`) would not
die of SIGINT on Ctrl-C; exec resets a caught signal to its default, so the program
the child executes gets SIGHUP, SIGINT, SIGTERM and the others with their default
effect. The signal mask is not changed, and a kqueue is not inherited. Between
`fork` and exec, `trySpawn`'s child still has the handler: a signal sent to it in
that window does nothing, and it executes its program all the same.

A wrapper that forwards SIGTERM and SIGHUP to its child calls this before it starts
the child: a signal before the call ends the wrapper while there is no child to
orphan, and one after it reaches `kq`, to be passed on with `kill`. With SIGINT
caught too, a Ctrl-C reaches the child in the same process group and leaves the
wrapper running to reap it. The handlers are process-wide and stay until the
program changes them (`defaultSignals`, `termCtl 1001`). -/
@[extern "lean_posix_catch_signals"]
opaque catchSignals (kq : UInt32) (sigs : @& Array UInt32) : IO UInt32

/-- `nextSignal`'s result, encoded: the signal's number, or the high bit or-ed with
the errno. -/
@[extern "lean_posix_next_signal_raw"]
private opaque nextSignalRaw (kq : UInt32) : IO UInt64

/-- Blocks until a signal watched on `kq` by `catchSignals` arrives, and gives its
number. One signal sent again before it is read comes once (the count is not
kept). Two different signals sent one after the other came in that order (the
test, on macOS 27); macOS's `kevent(2)` promises no order, so no more is claimed. The errno when the wait fails,
or EINVAL (22) when `kq` gave an event that is not a signal's: `kq` holds signal
watches only. -/
def nextSignal (kq : UInt32) : IO (Except UInt32 UInt32) := do
  let r ← nextSignalRaw kq
  return if r &&& ((1 : UInt64) <<< 63) == 0 then .ok r.toUInt32 else .error (r &&& 0xffffffff).toUInt32

/-- Opens `path` for events only and watches it for writes, growth, deletion and
renames, tagged with `tag` (0 or not: `kqWait` tells the two apart); the
descriptor, or 0x80000000 or-ed with the errno when it cannot be opened or
watched. Closing the descriptor ends the watch. -/
@[extern "lean_posix_watch"]
opaque watch (kq : UInt32) (path : @& String) (tag : UInt32) : IO UInt32

/-- The wait of `kqWait` and `kqWaitFor`: with `forever`, until something happens;
otherwise for at most `ms` milliseconds from the call, an interrupted wait
resuming with what is left of them (CLOCK_MONOTONIC), so a signal never stretches
it; one that interrupts the last, zero-length look ends the wait with nothing. -/
@[extern "lean_posix_kq_wait_until"]
private opaque kqWaitUntil (kq : UInt32) (forever : Bool) (ms : UInt32) :
    IO (UInt32 × Array UInt32 × Array UInt32)

/-- Waits until something happens, or with `poll` only looks at what has: 1 input,
2 a new window size, 4 a file watched with tag 0 changed, 8 one with another tag
changed, 16 a process watched on it with `watchExit` exited, or-ed, 0x80000000
when the wait fails; the descriptors of the files of tag 0 that changed; and the
pids of the processes that exited. At most 64 events a call; the rest wait for the
next. -/
def kqWait (kq : UInt32) (poll : Bool) : IO (UInt32 × Array UInt32 × Array UInt32) :=
  kqWaitUntil kq (!poll) 0

/-- `kqWait` that waits at most `ms` milliseconds: what happened first, as
`kqWait` gives it, or 0 and no descriptors or pids when the time ran out with
nothing happened (every event sets a bit, so 0 is only that). A signal that
interrupts the wait does not lengthen it: it goes on for what is left of `ms`.
`ms` 0 is `kqWait`'s `poll`. -/
def kqWaitFor (kq : UInt32) (ms : UInt32) : IO (UInt32 × Array UInt32 × Array UInt32) :=
  kqWaitUntil kq false ms

/-- Watches the exit of process `pid` on `kq` (from `kqOpen`), once: 0 when it is
watched, ESRCH (3) when no live process has that pid, one that exited and is not
reaped yet included, or the errno of another failure. The watch holds the process,
not its pid: a process that takes the pid after this one exited is not reported. -/
@[extern "lean_posix_watch_exit"]
opaque watchExit (kq pid : UInt32) : IO UInt32

/-- Stops watching the exit of `pid` on `kq`. -/
@[extern "lean_posix_unwatch_exit"]
opaque unwatchExit (kq pid : UInt32) : IO Unit

/-- Blocks until `n` exits watched on `kq` have come: 0 then, or the errno of a
failed wait. `kq` holds exit watches only; every event it gives counts as one. -/
@[extern "lean_posix_await_exits"]
opaque awaitExits (kq n : UInt32) : IO UInt32

/-- The exits `watchExits` watches, and what it found of each pid it was given. -/
structure ExitWatch where
  kq : UInt32
  /-- Live when watched; each one's exit is reported once. -/
  watching : Array UInt32
  /-- No live process had the pid: it has exited already, or never was. -/
  gone : Array UInt32
  /-- Not watched, each with the errno of why. -/
  failed : Array (UInt32 × UInt32)

/-- Watches the exits of `pids`, each pid once however often it is given. A kqueue
that cannot be opened fails every pid. -/
def watchExits (pids : Array UInt32) : IO ExitWatch := do
  let kq ← kqOpen
  let mut w : ExitWatch := { kq, watching := #[], gone := #[], failed := #[] }
  for pid in pids do
    if w.watching.contains pid || w.gone.contains pid || w.failed.any (·.1 == pid) then continue
    match ← watchExit kq pid with
    | 0 => w := { w with watching := w.watching.push pid }
    | 3 => w := { w with gone := w.gone.push pid }
    | e => w := { w with failed := w.failed.push (pid, e) }
  return w

/-- Stops watching `pid`, which leaves `watching`. -/
def ExitWatch.forget (w : ExitWatch) (pid : UInt32) : IO ExitWatch := do
  unless w.watching.contains pid do return w
  unwatchExit w.kq pid
  return { w with watching := w.watching.filter (· != pid) }

/-- Blocks until every process in `watching` has exited, then closes the kqueue: 0
when each has, or the errno of a failed wait, after which some may live. -/
def ExitWatch.wait (w : ExitWatch) : IO UInt32 := do
  let r ← if w.watching.isEmpty then pure 0 else awaitExits w.kq w.watching.size.toUInt32
  close w.kq
  return r

end Posix
