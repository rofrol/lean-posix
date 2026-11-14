import Std.Sync.Mutex
import Std.Tactic.BVDecide
import Posix.Fd

/-!
# Spawning a program that says whether its exec failed

Lean's `IO.Process.spawn` forks, and a child whose `execvp` fails prints "could
not execute external process" and exits 255 (Lean nightly-2026-10-25's
`src/runtime/process.cpp`), so its caller cannot tell a program that did not run
(no file, no execute bit, a script whose interpreter is missing) from one that ran
and died at once. `spawn` starts the program with `posix_spawn`, which on macOS
returns the exec's own errno: when the exec fails, no child is left.

No `fork`: every Lean program has threads, and on macOS `fork` runs libSystem's
atfork handlers in the child before its own code; with other threads inside
libnotify's first calls, children were killed by SIGKILL inside `fork` itself
(item tuvst2, `lake exe spawnstress`). The parent builds everything first: the
program's paths from PATH, as `execvp` would try them (an empty entry is the
current directory; with no PATH, `/usr/bin:/bin`), and its environment, and
tries each path with `posix_spawn`. Unlike `execvp`, a file the kernel will not
execute (ENOEXEC, a script with no `#!`) is not run through `/bin/sh`: it is a
failed exec.

macOS's `posix_spawn` has `POSIX_SPAWN_SETSID` but no attribute for a
controlling terminal, so a spawn with `ctty` starts the helper `lean-posix-ctty`
(`helper/ctty.c`, the Lake target of that name, with the protocol in its
header), which does `setsid`, `ioctl(TIOCSCTTY)` and the `execve`s, and reports
a failure through a pipe whose write end closes on exec
(`docs/decisions/0001-ctty-helper.md`). The helper is looked for next to
`IO.appPath`: a program that spawns with `ctty` installs it there.

macOS has no `pipe2`, so a pipe (`pipe`, and the result pipe of a `ctty`
spawn) is made close-on-exec in a second call, and a spawn in another thread in
between gives its child the pipe's ends, without close-on-exec, until it exits.
Every `pipe` and `spawn` here holds one lock, so they cannot leak into each
other; a spawn by something else (Lean's own spawn) in that window gives its
child such a copy, which delays the end of the pipe until that child exits.

Signals are left as the parent has them, as Lean's spawn leaves them: Lean
ignores SIGPIPE, and so does the child (`defaultSignals` restores it before an
`exec`). Descriptors the parent has open without close-on-exec stay open in the
child, as with Lean's spawn, unless the spawn names the ones it keeps (`keep`):
then the child has its 0, 1 and 2 and those only (`POSIX_SPAWN_CLOEXEC_DEFAULT`,
`posix_spawn_file_actions_addinherit_np`), each kept one at its own number and
open across the child's exec, while the parent's stays as it is, close-on-exec
included, so no copy is made and none is left behind on a failure.

All of it is C in `c/spawn.c`, which takes every constant and the wait-status
macros from the SDK's headers.
-/

namespace Posix

/-- What `spawn` uses for a standard stream the child inherits. -/
def inherit : UInt32 := 0xFFFFFFFF

/-- What `spawn` uses for a standard stream on `/dev/null`, read and written. -/
def devNull : UInt32 := 0xFFFFFFFE

initialize spawnLock : Std.Mutex Unit ← Std.Mutex.new ()

@[extern "lean_posix_spawn"]
private opaque spawnC (paths argv env : @& Array String) (stdin stdout stderr : UInt32) (setsid ctty : Bool)
  (only : Bool) (keep : @& Array UInt32) (helper : @& String) : IO UInt64

/-- The name of the ctty helper's executable, which `trySpawn` looks for in the
directory of `IO.appPath`. -/
def cttyHelperName : String := "lean-posix-ctty"

/-- The helper's path next to `IO.appPath`, or "", which no spawn finds, when
`IO.appPath` fails. -/
private def cttyHelperPath : IO String := do
  match ← IO.appPath.toBaseIO with
  | .ok app => return ((app.parent.getD ".") / cttyHelperName).toString
  | .error _ => return ""

/-- The `posix_spawn` of `spawn`. `paths` are the program's paths to try in order,
`argv` its arguments with its name first, `env` the `NAME=value` entries, of
distinct names, that come before the parent's environment and replace its entries
of the same names; an entry without `=` is a name whose entry the child does not
get. Each of
`stdin`, `stdout` and `stderr` is a descriptor above 2, made the child's 0, 1 or 2,
or `inherit` or `devNull`. The pid; or, with the high bit set, what failed in bits
32 to 39 (0 the exec, 1 opening `/dev/null`, 2 `dup2`, 3 `setsid`, 4 `pipe`, 6 a
result pipe that failed or gave a record cut short, the child then killed, 7
`ioctl(TIOCSCTTY)`, 8 the ctty helper) and its errno in the low 32 bits; 3 only
with `ctty`, since a spawn without it makes the session with
`POSIX_SPAWN_SETSID`, whose failure comes back as the exec's. A source
descriptor that is not open is refused at `dup2` before anything is made, so no
descriptor made here can take its number. A child whose setup or exec failed is
reaped before this returns. With `ctty`, the child is started through the helper
`cttyHelperName` next to `IO.appPath`. With `keep` some descriptors, each above
2 and below 2^31, which the caller makes sure of as for the three streams
(`trySpawn` throws otherwise), and open (one that is not is refused at `dup2`
like a source), the child has
its 0, 1 and 2 and those only; `none` leaves it every descriptor the parent has
without close-on-exec. -/
def spawnRaw (paths argv env : @& Array String) (stdin stdout stderr : UInt32) (setsid ctty : Bool)
    (keep : Option (Array UInt32) := none) : IO UInt64 := do
  spawnC paths argv env stdin stdout stderr setsid ctty keep.isSome (keep.getD #[])
    (← if ctty then cttyHelperPath else pure "")

/-- The paths `execvp` would try for `name`, from `path`, the value of PATH. -/
def candidates (name : String) (path : Option String) : Array String :=
  if name.isEmpty then #[]
  else if name.contains '/' then #[name]
  else ((path.getD "/usr/bin:/bin").splitOn ":").toArray.map fun d =>
    (if d.isEmpty then "." else d) ++ "/" ++ name

/-- Why `spawn` started no program: what failed, and its errno. -/
structure SpawnFailure where
  /-- `exec` when the program could not be executed, or `posix_spawn` failed
  for it (macOS returns both as one errno); otherwise the step of the setup
  before it that failed: `open /dev/null`, `dup2`, `setsid`, `TIOCSCTTY`,
  `pipe`, `the result pipe` for a record cut short, or `ctty helper` when the
  helper of a `ctty` spawn could not be started (the errno of its
  `posix_spawn`, ENOENT when it is missing) or did not greet in this library's
  protocol version (EPROTONOSUPPORT: a helper of another version, or one that
  died first). `setsid` is said only with `ctty`: without it the session is made
  by `posix_spawn`, whose failure is said as `exec`. -/
  stage : String
  errno : UInt32
  deriving Repr, BEq

def SpawnFailure.ofStage : UInt32 → String
  | 0 => "exec"
  | 1 => "open /dev/null"
  | 2 => "dup2"
  | 3 => "setsid"
  | 4 => "pipe"
  | 7 => "TIOCSCTTY"
  | 8 => "ctty helper"
  | _ => "the result pipe"

/-- Starts `argv` (its first word the program, looked up on PATH as `execvp` does
unless it holds a `/`) with the parent's environment, `env`'s `NAME=value` entries
(of distinct names) replacing the entries of their names, an entry `NAME` without
`=` removing that name's, and `stdin`, `stdout` and `stderr` each a
descriptor above 2 that becomes the child's own, `inherit` or `devNull`; in a
session of its own, leading its process group, with `setsid`; with `ctty` too, its
stdin, which must then be a terminal no session controls, becomes its controlling
terminal (`TIOCSCTTY`), so it gets SIGWINCH when the terminal's size is set, as
`login_tty` does; such a spawn goes through the helper `cttyHelperName`, found
next to `IO.appPath`, and fails at `ctty helper` without it. The child's pid once
the program runs: the exec has succeeded by then. Or why no program runs, the child
being reaped already. The caller's descriptors stay open and its own: close the
child's ends after the spawn, whatever its result. The pid is the caller's to reap
(`waitpid`), once. Throws, starting nothing, when a descriptor is 0, 1 or 2, which
the child's own setup would overwrite.

With `keep := some fds`, the child gets its 0, 1 and 2 (`stdin`, `stdout` and
`stderr` as given; one given as `inherit` that the parent has closed stays
closed) and the descriptors `fds` at their own numbers, open across its exec,
and no other: none of the parent's, whether close-on-exec or not, and with
`ctty` none of the helper's. The parent's descriptors stay as they are, `fds`
close-on-exec ones included: nothing is copied, so nothing is left open on a
failure. Each of `fds` must be open, else the spawn fails at `dup2` with EBADF
before anything is made; the caller keeps them open until this returns. With
`keep := none`, the child also gets every descriptor the parent has open without
close-on-exec. Throws, starting nothing, when a kept descriptor is 0, 1 or 2 or
not below 2^31. -/
def trySpawn (argv : Array String) (env : Array String := #[]) (stdin stdout stderr : UInt32 := inherit)
    (setsid ctty := false) (keep : Option (Array UInt32) := none) : IO (Except SpawnFailure UInt32) := do
  for fd in [stdin, stdout, stderr] do
    unless fd == inherit || fd == devNull || fd > 2 do
      throw (IO.userError s!"Posix.spawn: descriptor {fd} is one of the child's 0, 1 and 2: give inherit")
  for fd in keep.getD #[] do
    unless fd > 2 && fd < 0x80000000 do
      throw (IO.userError s!"Posix.spawn: descriptor {fd} cannot be kept: it is one of the child's 0, 1 and 2, or no descriptor")
  let paths := candidates (argv[0]?.getD "") (← IO.getEnv "PATH")
  let r ← spawnLock.atomically do spawnRaw paths argv env stdin stdout stderr setsid ctty keep
  if r >>> 63 == 0 then return .ok r.toUInt32
  return .error { stage := SpawnFailure.ofStage ((r >>> 32) &&& 0xff).toUInt32, errno := r.toUInt32 }

/-- `trySpawn`, throwing why no program runs: `cannot execute NAME: REASON`, or
`cannot start NAME: STAGE: REASON` for a failure of the setup before the exec. -/
def spawn (argv : Array String) (env : Array String := #[]) (stdin stdout stderr : UInt32 := inherit)
    (setsid ctty := false) (keep : Option (Array UInt32) := none) : IO UInt32 := do
  match ← trySpawn argv env stdin stdout stderr setsid ctty keep with
  | .ok pid => return pid
  | .error f =>
    let name := argv[0]?.getD ""
    let why ← strerror f.errno
    throw (IO.userError (if f.stage == "exec" then s!"cannot execute {name}: {why}"
      else s!"cannot start {name}: {f.stage}: {why}"))

@[extern "lean_posix_pipe_raw"]
private opaque pipeRaw : IO UInt64

/-- A pipe, its read end and its write end, both close-on-exec: `spawn` makes the
one given to a child its own 0, 1 or 2. Under `spawn`'s lock, so no spawn here
leaks it. -/
def pipe : IO (UInt32 × UInt32) := do
  let r ← spawnLock.atomically do pipeRaw
  if r >>> 63 != 0 then throw (IO.userError s!"pipe: {← strerror r.toUInt32}")
  return (r.toUInt32, (r >>> 32).toUInt32)

/-- Waits for the child `pid` to exit and reaps it, past any EINTR: its exit status,
or 128 plus the signal that ended it, as Lean's `Child.wait` gives them. Throws when
`pid` is no child of this process to wait for. -/
@[extern "lean_posix_waitpid"]
opaque waitpid (pid : UInt32) : IO UInt32

/-- How a child ended: it exited with a code, or a signal ended it. Unlike
`waitpid`'s number, a child that exits with 130 and one that SIGINT ends are
told apart. -/
inductive ExitOutcome where
  | exited (code : UInt8)
  | signaled (sig : UInt8)
  deriving DecidableEq, Repr, Inhabited

/-- Decodes a wait status from `waitpid(2)`: low 7 bits 0 is an exit, its code
in bits 8 to 15 (WIFEXITED, WEXITSTATUS); otherwise the low 7 bits are the
signal (WTERMSIG), the core-dump bit 0x80 dropped. Assumes the status is no
stop report (low 7 bits 0x7f), which `waitOutcome` never passes on. -/
def ExitOutcome.ofStatus (s : UInt32) : ExitOutcome :=
  if s &&& 0x7f == 0 then .exited ((s >>> 8) &&& 0xff).toUInt8 else .signaled (s &&& 0x7f).toUInt8

/-- Every exit code decodes to itself, as an exit. -/
theorem ExitOutcome.ofStatus_exited (code : UInt8) :
    ExitOutcome.ofStatus (code.toUInt32 <<< 8) = .exited code := by
  have h1 : code.toUInt32 <<< 8 &&& 0x7f = 0 := by bv_decide
  have h2 : ((code.toUInt32 <<< 8 >>> 8) &&& 0xff).toUInt8 = code := by bv_decide
  simp [ofStatus, h1, h2]

/-- Every signal (1 to 0x7e) decodes to itself, as a signal, with or without
the core-dump bit, so it is never taken for an exit code. -/
theorem ExitOutcome.ofStatus_signaled (sig : UInt8) (core : Bool) (h0 : sig ≠ 0) (h : sig < 0x7f) :
    ExitOutcome.ofStatus (sig.toUInt32 ||| (if core then 0x80 else 0)) = .signaled sig := by
  have h1 : ((sig.toUInt32 ||| (if core then 0x80 else 0)) &&& 0x7f == 0) = false := by
    cases core <;> simp only [Bool.false_eq_true, ite_true, ite_false] <;> bv_decide
  have h2 : ((sig.toUInt32 ||| (if core then 0x80 else 0)) &&& 0x7f).toUInt8 = sig := by
    cases core <;> simp only [Bool.false_eq_true, ite_true, ite_false] <;> bv_decide
  simp only [ofStatus, h1, h2, Bool.false_eq_true, ite_false]

@[extern "lean_posix_wait_status"]
private opaque waitStatus (pid : UInt32) : IO UInt32

/-- Waits for the child `pid` to exit and reaps it, past any EINTR: whether it
exited, with its code, or a signal ended it, with the signal. Throws when `pid`
is no child of this process to wait for. `waitpid` gives the same end as one
number. A stop is reported without WUNTRACED only for a traced child; this wait
passes such a report by and resumes nothing, so it is not for a child this
process traces (one that called PT_TRACE_ME), which would stay stopped and the
wait blocked. -/
def waitOutcome (pid : UInt32) : IO ExitOutcome :=
  ExitOutcome.ofStatus <$> waitStatus pid

/-- Writes all of `bytes` to `fd`, past any EINTR and short write: 0, or the errno of
the write that failed (EPIPE when the reader is gone, as Lean ignores SIGPIPE). -/
@[extern "lean_posix_write_all"]
opaque writeAll (fd : UInt32) (bytes : @& ByteArray) : IO UInt32

end Posix
