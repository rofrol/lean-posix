/-!
# Processes: exec, killing a process or a group, signals, start times, resources

Lean's `IO.Process` spawns and waits; it cannot become another program in the same
process, kill a process group, or put signals back to their defaults. The numbers
are macOS's: ESRCH 3, EPERM 1, EINVAL 22. The C is `c/process.c`, which takes
`struct proc_bsdinfo`, `struct rusage` and every constant from the SDK's headers.
-/

namespace Posix

/-- Becomes the command `argv` (looked up on `PATH`, `argv[0]` its name), in this
process with this environment. Should that fail it says why after `what` on
stderr, and returns. -/
@[extern "lean_posix_exec"]
opaque exec (argv : @& Array String) (what : @& String) : IO Unit

/-- Executes `path` as `path --resume`, in this process, with this environment;
returns only when that fails, with the errno. -/
@[extern "lean_posix_exec_resume"]
opaque execResume (path : @& String) : IO UInt32

/-- SIGKILL to `pid`; `pid` negative is a process group. -/
@[extern "lean_posix_kill_now"]
opaque killNow (pid : Int32) : IO Unit

/-- Sends signal `sig` to `pid` (`pid` below -1 is the process group `-pid`, 0 the
caller's group, -1 every process the caller may signal, as macOS's `kill(2)` says;
`sig` 0 only checks that the process can be signalled): 0 when it was sent,
or the errno: ESRCH (3) when no process has that pid; EPERM (1) when it is not the
caller's to signal; EINVAL (22) for no such signal. A child that exited and is not
reaped yet still has its pid: the signal is "sent" (0) and does nothing (measured on
macOS 27), so ESRCH means the pid is free, and may already be another process's. -/
@[extern "lean_posix_kill"]
opaque kill (pid : Int32) (sig : UInt32) : IO UInt32

/-- SIGALRM after `seconds`, or none with zero. Its default ends the process. -/
@[extern "lean_posix_alarm"]
opaque alarm (seconds : UInt32) : IO Unit

/-- The defaults of SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM and SIGTSTP, for a child
before it executes its command: an ignored signal survives exec, Lean ignores SIGPIPE,
and `termCtl 1001` ignores SIGTSTP. -/
@[extern "lean_posix_default_signals"]
opaque defaultSignals : IO Unit

/-- The default of SIGPIPE alone, for a process about to execute another program in
its place that keeps every other signal as its parent gave it: Lean ignores SIGPIPE
in every program it builds, and an ignored signal survives exec, while a signal its
parent ignored, such as SIGINT and SIGQUIT in a shell's `&` job, stays ignored. -/
@[extern "lean_posix_default_pipe"]
opaque defaultPipe : IO Unit

/-- When process `pid` started, in microseconds since the Unix epoch, as macOS's
`proc_pidinfo` (`PROC_PIDTBSDINFO`) gives it, with the high bit clear; or the high
bit or-ed with the errno when it cannot be read (ESRCH: no live process has that
pid). `processStart` gives the two apart. -/
@[extern "lean_posix_process_start_raw"]
opaque processStartRaw (pid : UInt32) : IO UInt64

/-- When process `pid` started, in microseconds since the Unix epoch: a process and
the pid it holds are told from a later one that took the pid by this, as two
processes that held one pid in turn started at different times. The time is set
once, when the process is made, and does not follow the clock after. The errno
when it cannot be read: ESRCH (3) when no live process has the pid, a process that
exited and is not reaped yet included (measured on macOS 27); another one, such as
EPERM, says nothing of whether it lives. -/
def processStart (pid : UInt32) : IO (Except UInt32 Nat) := do
  let r ← processStartRaw pid
  return if r &&& ((1 : UInt64) <<< 63) == 0 then .ok r.toNat else .error (r &&& 0xffffffff).toUInt32

/-- The process's peak resident set, in bytes, as macOS's `getrusage` gives it. -/
@[extern "lean_posix_peak_rss"]
opaque peakRss : IO USize

end Posix
