import Posix

/-!
# `lake test`

Each binding against the system it binds, in a temporary directory. A failure
prints what was expected and what came; the exit status is the number of failures.
`tests term` and `tests term-signal` are the children the terminal tests start on
a pty.
-/

open Posix

structure T where
  bad : IO.Ref Nat

def T.check (t : T) (name : String) (ok : Bool) (detail : String := "") : IO Unit := do
  if ok then IO.println s!"ok   {name}"
  else
    IO.println s!"FAIL {name}{if detail.isEmpty then "" else s!": {detail}"}"
    t.bad.modify (· + 1)

def bytes (s : String) : ByteArray := s.toUTF8

def text (b : ByteArray) : String := (String.fromUTF8? b).getD s!"{b.toList}"

def contains (hay needle : String) : Bool := (hay.splitOn needle).length > 1

/-- Up to `n` events of the kqueue of `watchSession`, until `stop` is one. -/
def eventsUntil (kq : UInt32) (stop : UInt32) : Nat → IO (List UInt32)
  | 0 => return []
  | n + 1 => do
    let e ← nextEvent kq
    if e == stop then return [e] else return e :: (← eventsUntil kq stop n)

def fds (t : T) (dir : System.FilePath) : IO Unit := do
  let file := dir / "f"
  IO.FS.writeFile file "0123456789"
  t.check "readAt reads from an offset" (text (← readAt file.toString 2 3) == "234")
  t.check "readAt past the end is empty" ((← readAt file.toString 20 3).size == 0)
  t.check "readAt of no file is empty" ((← readAt (dir / "none").toString 0 3).size == 0)
  let h ← IO.FS.Handle.mk file .read
  let fd ← handleFd h
  let r1 := text (← read fd 4)
  t.check "read reads at most n bytes" (r1 == "0123") r1.quote
  let d ← dupPrivate fd
  let r2 := text (← read d 2)
  t.check "dupPrivate shares the offset" (r2 == "45") r2.quote
  close d
  t.check "read of a closed descriptor is empty" ((← read d 2).size == 0)
  t.check "isatty of a file is false" (!(← isatty fd))
  -- The handle's last reference closes its descriptor: it is kept until here.
  discard h.isTty
  t.check "strerror says what ENOENT means" ((← strerror 2) == "No such file or directory")
  t.check "setTimes sets a file's times" ((← setTimes file.toString 1700000000123) == 0)
  let mt := (← file.metadata).modified
  t.check "to the millisecond" (mt.sec == 1700000000 && mt.nsec == 123000000) s!"{mt.sec} {mt.nsec}"
  t.check "setTimes of no file is its errno" ((← setTimes (dir / "none").toString 0) == 2)

/-- The device and inode of `path` as `stat(1)` says them. -/
def statId (path : System.FilePath) : IO (UInt32 × UInt64) := do
  let out ← IO.Process.output { cmd := "/usr/bin/stat", args := #["-f", "%d %i", path.toString] }
  match (out.stdout.trimAscii.toString.splitOn " ").map String.toNat? with
  | [some d, some i] => return (d.toUInt32, i.toUInt64)
  | _ => throw (IO.userError s!"stat said {out.stdout.quote}")

def fileAt (t : T) (dir : System.FilePath) : IO Unit := do
  let file := dir / "log"
  IO.FS.writeFile file "0123456789"
  let id0 ← statId file
  let some a := (← readFileAt file 2 3).toOption
    | t.check "readFileAt of a file reads it" false
  t.check "readFileAt reads from an offset" (text a.bytes == "234") (text a.bytes).quote
  t.check "with the file's size" (a.size == 10) s!"{a.size}"
  t.check "with its device and inode" ((a.dev, a.ino) == id0) s!"{(a.dev, a.ino)} {id0}"
  let h ← IO.FS.Handle.mk file .append
  h.putStr "abc"
  h.flush
  let some b := (← readFileAt file 10 100).toOption
    | t.check "readFileAt of an appended file reads it" false
  t.check "appended: the same file, grown, its new bytes"
    ((b.dev, b.ino) == id0 && b.size == 13 && text b.bytes == "abc") s!"{b.size} {text b.bytes}"
  IO.FS.writeFile file "01"
  let some c := (← readFileAt file 10 100).toOption
    | t.check "readFileAt of a truncated file reads it" false
  t.check "truncated in place: the same file, smaller than the offset, no bytes"
    ((c.dev, c.ino) == id0 && c.size == 2 && c.bytes.size == 0) s!"{c.size} {c.bytes.size}"
  let other := dir / "log.new"
  IO.FS.writeFile other "replaced, longer"
  let id1 ← statId other
  IO.FS.rename other file
  let some d := (← readFileAt file 0 8).toOption
    | t.check "readFileAt of a replaced file reads it" false
  t.check "replaced by rename: another inode, the new file's size and bytes"
    (d.ino != a.ino && (d.dev, d.ino) == id1 && d.size == 16 && text d.bytes == "replaced")
    s!"{(d.dev, d.ino)} {id1} {d.size} {text d.bytes}"
  let none_ ← readFileAt (dir / "none") 0 3
  t.check "readFileAt of no file is noSuchFile"
    (match none_ with | .error e => e == noSuchFile | .ok _ => false)
  let isDir ← readFileAt dir 0 3
  t.check "readFileAt of a directory is EISDIR"
    (match isDir with | .error e => e == 21 | .ok _ => false)

/-- What `fd` gives until it holds `n` lines or ends, in at most 100 reads. -/
def linesOf (fd : UInt32) (n : Nat) : IO String := do
  let mut acc := ByteArray.empty
  for _ in [0:100] do
    if (text acc).foldl (fun k c => if c == '\n' then k + 1 else k) 0 ≥ n then break
    let b ← read fd 256
    if b.size == 0 then break
    acc := acc ++ b
  return text acc

def pty (t : T) : IO Unit := do
  let (m, s) ← openPty
  t.check "openPty gives two descriptors" (m < 0x80000000 && s < 0x80000000)
  t.check "the slave is a terminal" (← isatty s)
  -- A tty opened again through its descriptor, to write as a child would.
  let w ← IO.FS.Handle.mk s!"/dev/fd/{s}" .write
  w.putStr "a\nb\n"
  w.flush
  t.check "the pty is raw: \\n stays \\n, nothing echoed" (text (← read m 64) == "a\nb\n")
  let d ← dupPrivate s
  dup2 m d
  let w2 ← IO.FS.Handle.mk s!"/dev/fd/{d}" .write
  w2.putStr "z"
  w2.flush
  t.check "dup2 makes a copy: a write to the master's copy reaches the slave" (text (← read s 8) == "z")
  close d
  close s
  close m
  let (rows, cols) ← winSize
  t.check "winSize is positive" (rows > 0 && cols > 0)
  -- A child on a pty that its session controls: the size set before it starts, and
  -- again while it runs, which it hears as SIGWINCH (`tests winch`, which watches
  -- for it on a kqueue before it prints the first size, so none is missed).
  let (m, s) ← openPty
  let r ← trySpawn #["true"] #[] s s s (ctty := true)
  let refused := match r with | .error f => f == { stage := "TIOCSCTTY", errno := 1 } | .ok _ => false
  t.check "ctty outside a session of its own fails at TIOCSCTTY with EPERM" refused s!"{repr r}"
  t.check "setWinSize sets a pty's size" ((← setWinSize s 33 77) == 0)
  let sz ← winSizeOf s
  let szm ← winSizeOf m
  t.check "winSizeOf a pty's slave and master gives the size set"
    (sz.toOption == some (33, 77) && szm.toOption == some (33, 77)) s!"{sz.toOption} {szm.toOption}"
  let (pr, pw) ← Posix.pipe
  let np ← winSizeOf pr
  t.check "winSizeOf a pipe is ENOTTY" (match np with | .error e => e == 25 | .ok _ => false) s!"{np.toOption}"
  close pr; close pw
  let pid ← spawn #[(← IO.appPath).toString, "winch"] #[] s s s (setsid := true) (ctty := true)
  let first ← linesOf m 1
  t.check "with setsid and ctty, the pty is the child's controlling terminal, of the size set" (first == "33 77\n") first.quote
  t.check "setWinSize on the master" ((← setWinSize m 40 120) == 0)
  let second ← linesOf m 1
  t.check "a size set on the master reaches the child as SIGWINCH" (second == "40 120\n") second.quote
  t.check "and the child exits" ((← waitpid pid) == 0)
  close s
  close m

/-- A copy of this program in `dir`, run as `tests ctty-spawn`: what its `ctty`
spawn said. -/
def cttySpawnFrom (dir : System.FilePath) : IO String := do
  IO.FS.createDirAll dir
  let copy := dir / "tests"
  discard <| IO.Process.output { cmd := "/bin/cp", args := #[(← IO.appPath).toString, copy.toString] }
  return (← IO.Process.output { cmd := copy.toString, args := #["ctty-spawn"] }).stdout

/-- A `ctty` spawn goes through the helper `lean-posix-ctty` next to
`IO.appPath`, which Lake builds next to these tests: an exec that fails there
comes back with its errno, as without `ctty`. The helper refuses a call of
another protocol version. A copy of this program in a directory without the
helper, or with one that speaks no protocol, fails its `ctty` spawn at
`ctty helper`. -/
def cttyHelper (t : T) (dir : System.FilePath) : IO Unit := do
  let (m, s) ← openPty
  let r ← trySpawn #[(dir / "missing").toString] #[] s s s (setsid := true) (ctty := true)
  let failed := match r with | .error f => f == { stage := "exec", errno := 2 } | .ok _ => false
  t.check "a ctty spawn whose exec fails says so, with its errno" failed s!"{repr r}"
  close s; close m
  let helper := ((← IO.appPath).parent.getD ".") / cttyHelperName
  let out ← IO.Process.output { cmd := helper.toString, args := #["--lean-posix-ctty-v2", "3", "0", "0"] }
  t.check "the helper refuses another protocol version, with exit status 127"
    (out.exitCode == 127 && contains out.stderr "protocol --lean-posix-ctty-v1") s!"{out.exitCode} {out.stderr.quote}"
  let alone ← cttySpawnFrom (dir / "alone")
  t.check "without the helper next to the program, a ctty spawn fails at ctty helper with ENOENT"
    (alone == "ctty helper 2\n") alone.quote
  let foreign := dir / "foreign"
  IO.FS.createDirAll foreign
  IO.FS.writeFile (foreign / cttyHelperName) "#!/bin/sh\nexit 0\n"
  discard <| IO.Process.output { cmd := "chmod", args := #["+x", (foreign / cttyHelperName).toString] }
  let said ← cttySpawnFrom foreign
  t.check "with a helper that does not greet, it fails at ctty helper with EPROTONOSUPPORT"
    (said == "ctty helper 43\n") said.quote

/-- The descriptors below `limit` open in a child, `tests open-fds LIMIT` with a
pipe as its stdout, which it reports as 1. -/
def childFds (limit : Nat) : IO (List Nat) := do
  let (r, w) ← Posix.pipe
  let pid ← spawn #[(← IO.appPath).toString, "open-fds", toString limit] #[] inherit w inherit
  close w
  let out ← linesOf r 1
  close r
  discard <| waitpid pid
  return (out.trimAscii.toString.splitOn " ").filterMap String.toNat?

/-- What a child inherits of the descriptors made here: none, neither
`openPty`'s master nor its slave, a kqueue, a lock's descriptor or a pipe.
Descriptors this process got from whoever started it do not count. A copy of
the slave with close-on-exec cleared, as `dup2` makes, shows that the child
reports what it inherits. -/
def inherited (t : T) (dir : System.FilePath) : IO Unit := do
  let (m, s) ← openPty
  let k ← kqOpen
  let (pr, pw) ← Posix.pipe
  let d ← dupPrivate s
  dup2 s d
  match ← lockFile (dir / "inherited") false with
  | .error e => t.check "lockFile takes a lock" false s!"{e}"; close d
  | .ok lk =>
    let ours := [m, s, k, lk, pr, pw].map (·.toNat)
    let limit := (d :: [m, s, k, lk, pr, pw]).foldl (fun a x => max a x.toNat) 0 + 1
    let after ← childFds limit
    -- The baseline: a child started once the inheritable copy is closed, which has
    -- what this process got from whoever started it, and any of ours that leaked.
    close d
    let without ← childFds limit
    t.check "a child inherits none of openPty's master and slave, a kqueue, a lock or a pipe, but a copy dup2 made"
      (after.contains d.toNat && !without.contains d.toNat
        && ours.all (!after.contains ·) && after.filter (· != d.toNat) == without)
      s!"with the copy {after}, without {without}; master {m} slave {s} copy {d} kqueue {k} lock {lk} pipe {pr} {pw}"
    unlock lk
  close s; close pr; close pw; close k; close m

/-- The exit status of `tests lock-handed PATH FD` with `fd`, and `open` (a shell
redirection) before it: 0 once it took over the lock, else the errno or 255. -/
def handedIn (path : System.FilePath) (fd : UInt32) (open_ : String := "") : IO UInt32 := do
  let child ← IO.Process.spawn { cmd := "/bin/sh", args := #["-c", s!"exec \"$0\" lock-handed \"$1\" {fd} {open_}", (← IO.appPath).toString, path.toString] }
  child.wait

/-- `lockHanded`: a lock kept across exec, taken over by the next program. -/
def handed (t : T) (dir : System.FilePath) : IO Unit := do
  let path := dir / "handed"
  let .ok fd ← lockFile path false | t.check "lockFile takes the lock to hand" false
  -- A copy with close-on-exec cleared, as a program hands it to its next build.
  let d ← dupPrivate fd
  dup2 fd d
  unlock fd
  -- The child's exec keeps it, as an exec of this process would.
  let code ← handedIn path d
  t.check "a program this process executes takes over the lock it is handed" (code == 0) s!"{code}"
  match ← lockHanded path d with
  | .ok got => t.check "lockHanded takes over the lock the descriptor holds" (got == d)
  | .error e => t.check "lockHanded takes over the lock the descriptor holds" false s!"{e}"
  let code ← handedIn path d
  t.check "and no child inherits it after" (code == 9) s!"{code}"
  match ← lockFile path false with
  | .error e => t.check "the lock stays held" (e == lockHeld) s!"errno {e}"
  | .ok _ => t.check "the lock stays held" false "it was taken again"
  let code ← handedIn path 9 s!"9<\"$1\""
  t.check "a descriptor of the file not holding a held lock gets lockHeld" (code == lockHeld) s!"{code}"
  let .ok other ← lockFile (dir / "other") false | t.check "lockFile takes another lock" false
  match ← lockHanded path other with
  | .error e => t.check "a descriptor of another file is refused with lockElsewhere" (e == lockElsewhere) s!"{e}"
  | .ok _ => t.check "a descriptor of another file is refused with lockElsewhere" false
  unlock other
  match ← lockHanded path 999 with
  | .error e => t.check "a descriptor not open gets EBADF" (e == 9) s!"{e}"
  | .ok _ => t.check "a descriptor not open gets EBADF" false
  match ← lockHanded (dir / "none") d with
  | .error e => t.check "a path not there gets ENOENT" (e == 2) s!"{e}"
  | .ok _ => t.check "a path not there gets ENOENT" false
  unlock d
  match ← lockFile path false with
  | .ok fd => t.check "closing the descriptor taken over lets the lock go" true; unlock fd
  | .error e => t.check "closing the descriptor taken over lets the lock go" false s!"errno {e}"

/-- Takes SA_RESTART (2) off the handler `sig` has, so a blocking call the signal
interrupts fails with EINTR: 0, or the errno. A test's own, as no binding installs
a handler that returns without SA_RESTART. `struct sigaction` as macOS lays it out
(handler, a 32-bit mask, flags). -/
@[extern c inline "({ extern int sigaction(int, const void*, void*); extern int* __error(void); struct { void (*h)(int); unsigned m; int f; } a; unsigned r = 0; if (sigaction((int)#1, 0, &a) != 0) r = (unsigned)*__error(); else { a.f &= ~2; if (sigaction((int)#1, &a, 0) != 0) r = (unsigned)*__error(); } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque noRestart (sig : UInt32) : IO UInt32

/-- `disposition`'s code: 0, 1 or 2, or 1000 plus the errno. -/
@[extern c inline "({ extern int sigaction(int, const void*, void*); extern int* __error(void); struct { void (*h)(int); unsigned m; int f; } a; uint32_t r; if (sigaction((int)#1, 0, &a) != 0) r = 1000u + (unsigned)*__error(); else r = a.h == (void (*)(int))0 ? 0u : a.h == (void (*)(int))1 ? 1u : 2u; lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque dispositionRaw (sig : UInt32) : IO UInt32

/-- What signal `sig` does in this process, as `sigaction` reads it: "dfl" for its
default (SIG_DFL, 0), "ign" when ignored (SIG_IGN, 1), "caught" for a handler, or
the errno. -/
def disposition (sig : UInt32) : IO String := do
  return match ← dispositionRaw sig with
    | 0 => "dfl" | 1 => "ign" | 2 => "caught" | e => s!"errno {e - 1000}"

/-- The calling thread's `pthread_t`, for `signalThread`. -/
@[extern c inline "({ extern void* pthread_self(void); lean_io_result_mk_ok(lean_box_uint64((uint64_t)pthread_self())); })"]
opaque thisThread : IO UInt64

/-- `pthread_kill`: the signal `sig` to the thread `thread` of this process, which
a signal sent to the process need not reach (any thread that does not block it
may take it; Lean runs `main` on a thread of its own): 0, or the errno. A kqueue's
EVFILT_SIGNAL does not see it. -/
@[extern c inline "({ extern int pthread_kill(void*, int); lean_io_result_mk_ok(lean_box_uint32((unsigned)pthread_kill((void*)#1, (int)#2))); })"]
opaque signalThread (thread : UInt64) (sig : UInt32) : IO UInt32

/-- Whether the thread `thread` (a `pthread_t`) of this process has entered the
`flock` system call and waits there in a wait that is not uninterruptible: 1 when
it does, 0 when it does not, and the high bit set with the Mach error when
`thread_get_state` or `thread_info` fails. arm64 only: elsewhere flavor 6 is
another, smaller register set, the buffers start zeroed, and the result is 0.

Two reads of the kernel's thread, in this order. `thread_get_state(ARM_THREAD_STATE64
= 6, 68 words)` gives the user registers saved on entry to the kernel, whose `x16`
holds the number of the system call the thread made, 131 for `flock`
(`bsd/kern/syscalls.master` 209; `libsystem_kernel`'s `flock` is `mov x16, #0x83`
then `svc #0x80`, as lldb disassembles it); so the thread has entered `flock`
(unless user code left 131 in `x16`, a scratch register, and then faulted into a
wait), and a caller that knows `flock` cannot have returned knows it is still
inside. Then
`thread_info(THREAD_BASIC_INFO = 3)` gives its `run_state`, which XNU sets to
`TH_STATE_WAITING` (3) only for a thread that waits, is not running and is not in
an uninterruptible wait (`osfmk/kern/thread.c` 2047-2057). It does not tell an
abort-safe wait from a merely interruptible one, nor name the wait channel, which
XNU does not export (no `wmesg` in `bsd/kern/kern_sysctl.c` or
`bsd/kern/proc_info.c`). Reading another thread's state holds and stops it but
leaves its wait as it is (`osfmk/kern/thread_act.c` `thread_get_state_internal`;
`thread_stop` and `thread_unstop` only set and clear `TH_SUSP`). -/
@[extern c inline "({ extern unsigned pthread_mach_thread_np(void*); extern int thread_info(unsigned, int, int*, unsigned*); extern int thread_get_state(unsigned, int, unsigned*, unsigned*); unsigned th = pthread_mach_thread_np((void*)#1); int info[10] = {0}; unsigned n = 10; unsigned long long st[34] = {0}; unsigned m = 68; int kr = thread_get_state(th, 6, (unsigned*)st, &m); if (kr == 0) kr = thread_info(th, 3, info, &n); lean_io_result_mk_ok(lean_box_uint32(kr != 0 ? 0x80000000u | (unsigned)kr : (st[16] == 131 && info[6] == 3) ? 1u : 0u)); })"]
opaque inFlock (thread : UInt64) : IO UInt32

/-- `inFlock thread`, read up to `n` times until it is not 0 (interval: none; each
read is the next pair of Mach calls, the kernel's thread state being the producer,
which sends no event): its last result. -/
def inFlockWithin (thread : UInt64) (n : Nat) : IO UInt32 := do
  let mut r := 0
  for _ in [0:n] do
    r ← inFlock thread
    if r != 0 then return r
  return r

/-- `lockDir` waits past a signal whose handler lacks SA_RESTART. A holder (`tests
lock-dir-hold`) takes the directory's lock; a waiter (`tests lock-dir-signal`)
catches SIGUSR1 (30) without SA_RESTART, says "ready" and blocks in `lockDir`.

On "go" the waiter's helper thread waits until `inFlock` sees its main thread
waiting in `flock` (`flock` cannot return before the holder ends, which comes
later), then sends it the signal with `pthread_kill` and says "sent"; the holder
ends only then. When the main thread is not seen there within the bound, the
helper says so and the test fails; it never signals early. By XNU's published
source (xnu-12377.1.9, commit f6217f891ac0 of apple-oss-distributions/xnu; the
running kernel's own source, xnu-13432, is not published):

- `__pthread_kill` calls `psignal_uthread` (`bsd/kern/kern_sig.c` 1141), whose
  `psignal_internal` finds the signal caught (2212), goes to `runlocked` (2313,
  2347) and calls `thread_abort_safely` (2560) before it returns.
- For a thread in an abort-safe wait (`at_safe_point`), `thread_abort_safely`
  calls `clear_wait_internal(thread, THREAD_INTERRUPTED)`
  (`osfmk/kern/thread_act.c` 566-567), which takes the thread off its wait queue
  and sets its wait result through `thread_go` (`osfmk/kern/sched_prim.c`
  1655-1659), all before `pthread_kill` returns; the holder's end can no longer
  wake it. `lf_setlock`'s sleep for a lock held elsewhere is such a wait: an
  `msleep` with PCATCH, "lockf:np" (`bsd/kern/kern_lockf.c` 547, 774), which
  `_sleep` makes THREAD_ABORTSAFE (`bsd/kern/kern_synch.c` 182-183). `_sleep` turns
  THREAD_INTERRUPTED with a pending signal whose handler lacks SA_RESTART into
  EINTR (`kern_synch.c` 292-299), and `lf_setlock` returns it (`kern_lockf.c`
  814-823).
- Not proven: that the wait `inFlock` sees is that one. `flock` reaches
  `lf_setlock` through the file system's `VNOP_ADVLOCK` (here APFS, whose source is
  not published), and `inFlock` cannot tell an abort-safe wait from another
  interruptible one. In another such wait `thread_abort_safely` only marks the
  thread aborted (`thread_act.c` 566-569), so its next abort-safe wait returns
  interrupted at once (`sched_prim.c` 1059-1062, 1090-1097); but if the holder
  ended before that, `lf_setlock` could take the lock without sleeping and the
  unfixed `lockDir` would pass.

The unfixed `lockDir` failed this test with "gave up" in 5 runs of 5, the main
thread seen in `flock` each time. -/
def lockDirSignal (t : T) (dir : System.FilePath) : IO Unit := do
  let d := dir / "dirlock"
  IO.FS.createDir d
  let self := (← IO.appPath).toString
  let holder ← IO.Process.spawn { cmd := self, args := #["lock-dir-hold", d.toString], stdin := .piped, stdout := .piped }
  let held ← holder.stdout.getLine
  t.check "a holder takes the directory's lock" (held == "held\n") held.quote
  let waiter ← IO.Process.spawn { cmd := self, args := #["lock-dir-signal", d.toString], stdin := .piped, stdout := .piped }
  let ready ← waiter.stdout.getLine
  t.check "the waiter catches SIGUSR1 without SA_RESTART" (ready == "ready\n") ready.quote
  t.check "inFlock says 0 for the calling thread, which runs" ((← inFlock (← thisThread)) == 0)
  waiter.stdin.putStrLn "go"
  waiter.stdin.flush
  let sent ← waiter.stdout.getLine
  t.check "the waiter's main thread is seen asleep in flock, and SIGUSR1 reaches it"
    (sent == "sent 0\n") sent.quote
  holder.stdin.putStrLn "go"
  holder.stdin.flush
  t.check "the holder ends" ((← holder.wait) == 0)
  let got ← waiter.stdout.getLine
  t.check "lockDir waits past EINTR and takes the lock once the holder ends"
    (got == "locked\n") got.quote
  t.check "the waiter ends" ((← waiter.wait) == 0)

def locks (t : T) (dir : System.FilePath) : IO Unit := do
  let path := dir / "lock"
  match ← lockFile path false with
  | .error e => t.check "lockFile takes a free lock" false s!"errno {e}"
  | .ok fd =>
    t.check "lockFile takes a free lock" true
    match ← lockFile path false with
    | .error e => t.check "a held lock is refused with lockHeld" (e == lockHeld) s!"errno {e}"
    | .ok _ => t.check "a held lock is refused with lockHeld" false "it was taken twice"
    unlock fd
    match ← lockFile path false with
    | .ok fd => t.check "an unlocked lock is free again" true; unlock fd
    | .error e => t.check "an unlocked lock is free again" false s!"errno {e}"
  match ← lockFile (dir / "no" / "lock") true with
  | .error e => t.check "lockFile with no directory gives ENOENT" (e == 2) s!"errno {e}"
  | .ok _ => t.check "lockFile with no directory gives ENOENT" false
  handed t dir
  t.check "lockDir locks a directory" ((← lockDir dir.toString) != 0xffffffff)
  t.check "lockDir of no directory fails" ((← lockDir (dir / "none").toString) == 0xffffffff)
  lockDirSignal t dir
  IO.FS.writeFile (dir / "a") "a"
  t.check "link links a free name" ((← link (dir / "a").toString (dir / "b").toString) == 0)
  t.check "link refuses a taken name with EEXIST" ((← link (dir / "a").toString (dir / "b").toString) == 17)

def kq (t : T) (dir : System.FilePath) : IO Unit := do
  -- A process and its output: `head` echoes the 3 bytes it is given, then exits.
  let child ← IO.Process.spawn { cmd := "head", args := #["-c", "3"], stdin := .piped, stdout := .piped }
  let out ← handleFd child.stdout
  let wakes := dir / "wakes"
  IO.FS.createDirAll wakes
  let d ← openEvents wakes.toString
  t.check "openEvents opens a directory" (d < 0x80000000)
  let k ← watchSession child.pid out d
  t.check "watchSession watches a live process" (k &&& 0x80000000 == 0)
  IO.FS.writeFile (wakes / "1") ""
  t.check "nextEvent: the directory was written to" ((← nextEvent k) == 3)
  let (stdin, child) ← child.takeStdin
  stdin.putStr "abc"
  stdin.flush
  t.check "nextEvent: the output is readable" ((← nextEvent k) == 0)
  t.check "drainNow takes what is there without waiting" (text (← drainNow out) == "abc")
  -- The kernel does not order the exit and the output's end: the exit may come first.
  let evs ← eventsUntil k 1 8
  t.check "nextEvent: the output closed" (evs.getLast? == some 1) s!"{evs}"
  unwatchRead k out
  let after ← if evs.contains 2 then pure [] else (·::[]) <$> nextEvent k
  t.check "nextEvent: the process exited, before or after its output closed"
    ((evs ++ after).contains 2) s!"{evs} then {after}"
  discard child.wait
  -- The exit first, made certain: this program holds the output's write end.
  let (inR, inW) ← Posix.pipe
  let (outR, outW) ← Posix.pipe
  let pid ← spawn #["cat"] (stdin := inR) (stdout := outW)
  close inR
  let k3 ← watchSession pid outR 0xffffffff
  t.check "watchSession watches a live cat" (k3 &&& 0x80000000 == 0)
  close inW
  t.check "nextEvent: the exit comes while the output is still open" ((← nextEvent k3) == 2)
  close outW
  t.check "nextEvent: then the output closes" ((← nextEvent k3) == 1)
  discard (waitpid pid)
  close k3
  close outR
  let k2 ← watchSession child.pid out 0xffffffff
  t.check "watchSession of an exited process sets the high bit" (k2 &&& 0x80000000 != 0)
  close k
  close (k2 &&& 0x7fffffff)
  close d

/-- A `cat` that lives until it is killed: its stdin stays open. -/
def waiter : IO (UInt32 × IO.Process.Child { stdin := .piped, stdout := .null }) := do
  let child ← IO.Process.spawn { cmd := "cat", stdin := .piped, stdout := .null }
  return (child.pid, child)

def exits (t : T) : IO Unit := do
  let end_ (pid : UInt32) := killNow pid.toInt32
  -- Live processes, watched, then ended: the wait returns once both have exited.
  let (a, ca) ← waiter
  let (b, cb) ← waiter
  -- Ended and reaped before it is watched.
  let (c, cc) ← waiter
  end_ c
  discard cc.wait
  let w ← watchExits #[a, b, a, c]
  t.check "watchExits watches live processes, each once" (w.watching == #[a, b]) s!"{w.watching}"
  t.check "watchExits: a reaped process is gone" (w.gone == #[c]) s!"{w.gone}"
  t.check "watchExits: nothing failed" w.failed.isEmpty s!"{w.failed}"
  end_ a
  end_ b
  t.check "ExitWatch.wait returns 0 once every watched process exited" ((← w.wait) == 0)
  -- Both have exited and neither is reaped: a zombie is gone too.
  let w2 ← watchExits #[a, b]
  t.check "watchExits: an exited process not yet reaped is gone"
    (w2.gone == #[a, b] && w2.watching.isEmpty) s!"{w2.watching} {w2.gone} {w2.failed}"
  t.check "ExitWatch.wait with nothing watched returns 0" ((← w2.wait) == 0)
  discard ca.wait
  discard cb.wait
  -- A process forgotten is not waited for: the wait returns while it lives.
  let (d, cd) ← waiter
  let (e, ce) ← waiter
  let w3 ← (← watchExits #[d, e]).forget d
  t.check "ExitWatch.forget drops the pid" (w3.watching == #[e]) s!"{w3.watching}"
  end_ e
  t.check "ExitWatch.wait waits for the watched only" ((← w3.wait) == 0)
  let w4 ← watchExits #[d]
  t.check "the forgotten process still lives" (w4.watching == #[d]) s!"{w4.gone}"
  end_ d
  t.check "and its exit ends a wait of its own" ((← w4.wait) == 0)
  discard cd.wait
  discard ce.wait
  -- A watch on a closed kqueue fails with EBADF.
  let k ← kqOpen
  close k
  t.check "watchExit on a closed kqueue gives EBADF" ((← watchExit k a) == 9)

def kqView (t : T) (dir : System.FilePath) : IO Unit := do
  let k ← kqOpen
  let file := dir / "watched"
  IO.FS.writeFile file ""
  let other := dir / "other"
  IO.FS.writeFile other ""
  let fd ← watch k file.toString 0
  t.check "watch watches a file" (fd &&& 0x80000000 == 0)
  let fd2 ← watch k other.toString 1
  let (none_, _) ← kqWait k true
  t.check "kqWait with poll and nothing new" (none_ == 0) s!"{none_}"
  -- A wait with a timeout and nothing to report returns 0 once the time has passed.
  let t0 ← IO.monoMsNow
  let (m, changed, exited) ← kqWaitFor k 50
  let took := (← IO.monoMsNow) - t0
  t.check "kqWaitFor with nothing new gives 0 and nothing"
    (m == 0 && changed.isEmpty && exited.isEmpty) s!"{m} {changed} {exited}"
  t.check "kqWaitFor waits its time out" (took >= 50) s!"{took} ms"
  -- An event that comes before the time is up is reported.
  IO.FS.withFile file .append (·.putStr "x")
  let (m, changed, _) ← kqWaitFor k 60000
  t.check "kqWaitFor reports an event that comes first" (m == 4 && changed == #[fd])
    s!"{m} {changed}"
  IO.FS.withFile file .append (·.putStr "x")
  IO.FS.withFile other .append (·.putStr "x")
  let (m, changed, exited) ← kqWait k true
  t.check "kqWait: a file of tag 0 and one of another tag" (m == 4 ||| 8) s!"{m}"
  t.check "kqWait gives the descriptors of tag 0" (changed == #[fd]) s!"{changed}"
  t.check "kqWait: no process exited" exited.isEmpty s!"{exited}"
  -- A process's exit, watched on the same kqueue: its own bit and its pid, no descriptor.
  let (a, ca) ← waiter
  t.check "watchExit on kqWait's kqueue" ((← watchExit k a) == 0)
  killNow a.toInt32
  let (m, changed, exited) ← kqWait k false
  t.check "kqWait: a watched process exited" (m == 16 && changed.isEmpty && exited == #[a])
    s!"{m} {changed} {exited}"
  discard ca.wait
  let r ← watch k (dir / "none").toString 0
  t.check "watch of no file gives ENOENT" (r == 0x80000000 ||| 2) s!"{r}"
  close fd
  close fd2
  close k

def starts (t : T) : IO Unit := do
  let me ← IO.Process.getPID
  let mine ← processStart me
  t.check "processStart of this process" (mine matches .ok _) s!"{repr mine}"
  let (a, ca) ← waiter
  let first ← processStart a
  let again ← processStart a
  t.check "processStart of a live child, the same each time"
    (first matches .ok _ && first.toOption == again.toOption) s!"{repr first} {repr again}"
  t.check "a child started after this process" (match mine, first with
    | .ok m, .ok f => m ≤ f
    | _, _ => false) s!"{repr mine} {repr first}"
  killNow a.toInt32
  -- Its exit, not reaped: a zombie, which has no start any more.
  let w ← watchExits #[a]
  discard w.wait
  let zombie ← processStart a
  t.check "processStart of an exited process not yet reaped is ESRCH" (zombie matches .error 3)
    s!"{repr zombie}"
  discard ca.wait
  let reaped ← processStart a
  t.check "processStart of a reaped process is ESRCH" (reaped matches .error 3) s!"{repr reaped}"

def processes (t : T) : IO Unit := do
  let child ← IO.Process.spawn { cmd := "sleep", args := #["60"] }
  killNow child.pid.toInt32
  let code ← child.wait
  t.check "killNow kills the process" (code != 0) s!"exit {code}"
  t.check "execResume of no file gives ENOENT" ((← execResume "/nonexistent/lean-posix") == 2)
  let out ← IO.Process.output { cmd := (← IO.appPath).toString, args := #["exec-fails"] }
  t.check "exec that fails returns and says why" (out.exitCode == 0 && contains out.stderr "lean-posix exec") out.stderr
  let out ← IO.Process.output { cmd := (← IO.appPath).toString, args := #["exec"] }
  t.check "exec becomes the command" (out.stdout == "became\n") out.stdout
  -- A shell ignores SIGINT for the program it executes; `defaultPipe` keeps that
  -- and puts back the SIGPIPE Lean ignores, so the command dies of SIGPIPE alone.
  let out ← IO.Process.output { cmd := "/bin/sh", args := #["-c", "trap '' INT; exec \"$0\" default-pipe", (← IO.appPath).toString] }
  t.check "defaultPipe keeps an ignored SIGINT and puts back SIGPIPE" (out.exitCode == 128 + 13 && out.stdout == "") s!"{out.exitCode} {out.stdout.quote}"
  alarm 0
  t.check "peakRss is positive" ((← peakRss) > 0)

instance [BEq ε] [BEq α] : BEq (Except ε α) where
  beq
    | .ok a, .ok b => a == b
    | .error a, .error b => a == b
    | _, _ => false

/-- What `fd` gives until its end, closing it. -/
partial def readAll (fd : UInt32) (acc : ByteArray := .empty) : IO ByteArray := do
  let b ← read fd 4096
  if b.size == 0 then close fd; return acc else readAll fd (acc ++ b)

/-- `killSession`: a session whose processes fork and exit while it is ended; a
session whose leader has exited, its member in a process group of its own; a
session of root's, every member refused; the sessions it refuses to name. Each
step waits for what a child says on a pipe or for an exit, never for a time. -/
def sessions (t : T) : IO Unit := do
  -- Forks and exits during the kill: the leader starts a `sleep` and a `true` per
  -- turn and says "started" after five turns, then keeps forking.
  let (r, w) ← Posix.pipe
  let loop := "i=0; while [ $i -lt 100 ]; do /bin/sleep 100 & /usr/bin/true & i=$((i+1)); \
    if [ $i -eq 5 ]; then echo started; fi; done; wait"
  let leader ← spawn #["/bin/sh", "-c", loop] (stdout := w) (setsid := true)
  close w
  let said ← linesOf r 1
  let before ← sessionMembers leader
  t.check "sessionMembers lists a forking session's processes"
    (said == "started\n" && match before with | .ok m => m.contains leader && m.size ≥ 2 | .error _ => false)
    s!"{said.quote} {repr before}"
  let k ← killSession leader
  t.check "killSession ends a session whose processes fork and exit meanwhile"
    (match k with | .ok k => k.killed ≥ 2 && k.refused.isEmpty && k.left.isEmpty | .error _ => false) s!"{repr k}"
  let after ← sessionMembers leader
  t.check "and no member is left" (after == .ok #[]) s!"{repr after}"
  let end_ ← waitOutcome leader
  t.check "the leader died of SIGKILL" (end_ == .signaled 9) s!"{repr end_}"
  t.check "every holder of the pipe's write end is gone" ((← readAll r).size == 0)
  -- An exited leader, not reaped: its job, in a process group of its own (`set -m`),
  -- keeps the session.
  let (r, w) ← Posix.pipe
  let leader ← spawn #["/bin/sh", "-c", "set -m; /bin/sleep 100 & echo $!"] (stdout := w) (setsid := true)
  close w
  let line ← linesOf r 1
  let job := (line.trimAscii.toString.toNat?.getD 0).toUInt32
  discard <| (← watchExits #[leader]).wait
  let members ← sessionMembers leader
  t.check "an exited leader not yet reaped is no member; its job in a group of its own is"
    (members == .ok #[job]) s!"{repr members} job {job}"
  let k ← killSession leader
  t.check "killSession ends the session of an exited leader"
    (k == .ok { killed := 1, refused := #[], left := #[] }) s!"{repr k}"
  let gone ← processStart job
  t.check "its job has exited" (gone matches .error 3) s!"{repr gone}"
  let end_ ← waitOutcome leader
  t.check "the leader had exited by itself" (end_ == .exited 0) s!"{repr end_}"
  close r
  -- A session of root's: notifyd, which launchd starts in a session of its own,
  -- leads one. Only when notifyd leads it and this process may signal none of its
  -- members (so not as root) is it asked to end it. A session gains members only
  -- by a member's fork (setsid makes a new one, setpgid stays in the caller's), and
  -- notifyd starts no programs, so the members checked are the ones killSession
  -- finds; a process of root's cannot become this user's to signal unless it
  -- gives up root itself.
  let out ← IO.Process.output { cmd := "/usr/bin/pgrep", args := #["-x", "notifyd"] }
  match out.stdout.trimAscii.toString.toNat? with
  | none => t.check "one notifyd runs, to try a session of root's" false out.stdout.quote
  | some n =>
    let sid := n.toUInt32
    let members ← sessionMembers sid
    let mine ← match members with
      | .ok m => do
        let any ← m.anyM fun p => return (← kill p.toInt32 0) != 1
        pure (any || !m.contains sid)
      | .error _ => pure true
    if mine then
      t.check "skipped: a member of notifyd's session may be signalled by this process" true s!"{repr members}"
    else
      let k ← killSession sid
      let want := members.toOption.getD #[] |>.map (·, (1 : UInt32))
      t.check "killSession of root's session refuses every member with EPERM, and kills none"
        (k == .ok { killed := 0, refused := want, left := #[] } && !want.isEmpty) s!"{repr k}"
  t.check "killSession refuses session 0 and launchd's"
    ((← killSession 0) == .error 22 && (← killSession 1) == .error 22)
  let (r, w) ← Posix.pipe
  let pid ← spawn #[(← IO.appPath).toString, "own-session"] (stdout := w) (setsid := true)
  close w
  let said := text (← readAll r)
  discard <| waitpid pid
  t.check "killSession refuses the caller's own session" (said == "22\n") said.quote

/-- `trySpawn argv` with stdout on a pipe: what it printed and its status. -/
def spawned (argv : Array String) (env : Array String := #[]) (stdin := inherit) (setsid := false) :
    IO (Except SpawnFailure (String × UInt32)) := do
  let (r, w) ← Posix.pipe
  let res ← trySpawn argv env stdin w inherit setsid
  close w
  match res with
  | .error f => close r; return .error f
  | .ok pid =>
    let out := text (← readAll r)
    return .ok (out, ← waitpid pid)

def spawns (t : T) (dir : System.FilePath) : IO Unit := do
  let r ← spawned #["echo", "hi"]
  t.check "spawn runs a program found on PATH, its stdout on a pipe" (r == .ok ("hi\n", 0)) s!"{repr r}"
  let r ← spawned #["/bin/sh", "-c", "echo \"$RRX\"; exit 3"] #["RRX=given"]
  t.check "spawn adds env's entries, and waitpid gives the exit status" (r == .ok ("given\n", 3)) s!"{repr r}"
  let home := (← IO.getEnv "HOME").getD ""
  let r ← spawned #["/bin/sh", "-c", "echo \"$HOME\""] #["HOME=replaced"]
  t.check "an entry of env replaces the parent's of its name" (r == .ok ("replaced\n", 0)) s!"{repr r} {home}"
  let r ← spawned #["/bin/sh", "-c", "echo \"${HOME-none}\""] #["HOME"]
  t.check "an entry of env without = removes the parent's of its name" (r == .ok ("none\n", 0)) s!"{repr r}"
  let r ← spawned #["/bin/sh", "-c", "kill -9 $$"]
  t.check "waitpid gives 128 plus the signal that ended the child" (r == .ok ("", 137)) s!"{repr r}"
  let r ← spawned #["cat"] (stdin := devNull)
  t.check "devNull puts a stream on /dev/null" (r == .ok ("", 0)) s!"{repr r}"
  let r ← spawned #["/bin/sh", "-c", "ps -o pgid= -p $$ | tr -d ' '; echo $$"] (setsid := true)
  let leads := match r with
    | .ok (out, 0) => match out.splitOn "\n" with | [g, p, ""] => g == p | _ => false
    | _ => false
  t.check "setsid makes the child lead its process group" leads s!"{repr r}"
  -- The failed execs Lean's spawn cannot tell from a death.
  let r ← spawned #[(dir / "missing").toString]
  t.check "a missing program fails its exec with ENOENT" (r == .error { stage := "exec", errno := 2 }) s!"{repr r}"
  let r ← spawned #["lean-posix-no-such-program"]
  t.check "and so does a name on no directory of PATH" (r == .error { stage := "exec", errno := 2 }) s!"{repr r}"
  IO.FS.writeFile (dir / "plain") "echo ran\n"
  let r ← spawned #[(dir / "plain").toString]
  t.check "a file without the execute bit fails its exec with EACCES" (r == .error { stage := "exec", errno := 13 }) s!"{repr r}"
  IO.FS.writeFile (dir / "orphan") "#!/nonexistent/interpreter\necho ran\n"
  discard <| IO.Process.output { cmd := "chmod", args := #["+x", (dir / "orphan").toString] }
  let r ← spawned #[(dir / "orphan").toString]
  t.check "a script whose interpreter is missing fails its exec with ENOENT" (r == .error { stage := "exec", errno := 2 }) s!"{repr r}"
  IO.FS.writeFile (dir / "headless") "echo ran\n"
  discard <| IO.Process.output { cmd := "chmod", args := #["+x", (dir / "headless").toString] }
  let r ← spawned #[(dir / "headless").toString]
  t.check "a script with no #! fails its exec with ENOEXEC, run by no shell" (r == .error { stage := "exec", errno := 8 }) s!"{repr r}"
  -- PATH: a directory whose program cannot be executed is passed for a later one, and
  -- EACCES is said when no directory has one that runs.
  let bin := dir / "bin"
  IO.FS.createDirAll bin
  IO.FS.writeFile (bin / "lean-posix-echo") "echo ran\n"
  t.check "candidates follow PATH, an empty entry the current directory"
    (candidates "x" (some "/a::/b") == #["/a/x", "./x", "/b/x"] && candidates "/a/x" (some "/b") == #["/a/x"]
      && candidates "x" none == #["/usr/bin/x", "/bin/x"] && candidates "" (some "/a") == #[])
  -- Looked up on the PATH of the process that spawns: the tests, run again with it.
  let r ← spawned #[(← IO.appPath).toString, "path-eacces"] #[s!"PATH={bin}"]
  t.check "a name found only without the execute bit fails with EACCES" (r == .ok ("exec 13\n", 0)) s!"{repr r}"
  IO.FS.writeFile (dir / "lean-posix-echo") "#!/bin/sh\necho ran\n"
  discard <| IO.Process.output { cmd := "chmod", args := #["+x", (dir / "lean-posix-echo").toString] }
  let r ← spawned #[(← IO.appPath).toString, "path-eacces"] #[s!"PATH={bin}:{dir}"]
  t.check "and is passed for a later directory's that runs" (r == .ok ("ran\n", 0)) s!"{repr r}"
  -- A setup step that fails before the exec is said with its step.
  let r ← trySpawn #["true"] #[] 999
  t.check "a descriptor that is not open fails the setup at dup2" (r == .error { stage := "dup2", errno := 9 }) s!"{repr r}"
  -- A source closed just before: the result pipe the spawn makes would take its number.
  let (cr, cw) ← Posix.pipe
  close cr
  let r ← trySpawn #["true"] #[] cr
  close cw
  t.check "a closed source is refused, not taken for a descriptor the spawn makes" (r == .error { stage := "dup2", errno := 9 }) s!"{repr r}"
  let r ← trySpawn #[]
  t.check "no program is ENOENT" (r == .error { stage := "exec", errno := 2 }) s!"{repr r}"
  let (rd, wr) ← Posix.pipe
  let res ← trySpawn #["/bin/sh", "-c", "echo out; echo err >&2"] #[] inherit wr wr
  close wr
  let both := text (← readAll rd)
  if let .ok pid := res then discard <| waitpid pid
  t.check "one descriptor can be stdout and stderr both" (both == "out\nerr\n") both.quote
  let refused ← (do discard <| trySpawn #["true"] #[] 1; pure false) <|> pure true
  t.check "a descriptor 0, 1 or 2 is refused before anything starts" refused
  match ← (spawn #[(dir / "plain").toString]).toBaseIO with
  | .error e => t.check "spawn throws why: cannot execute" (contains (toString e) "cannot execute" && contains (toString e) "Permission denied") (toString e)
  | .ok _ => t.check "spawn throws why: cannot execute" false
  -- writeAll: every byte through a pipe, and EPIPE once its reader is gone.
  let (r, w) ← Posix.pipe
  let (o, ow) ← Posix.pipe
  let pid ← spawn #["cat"] #[] r ow
  close r; close ow
  let big := String.ofList (List.replicate 200000 'x')
  let wrote ← IO.asTask (do let e ← writeAll w big.toUTF8; close w; pure e)
  let got ← readAll o
  t.check "writeAll writes every byte, past a full pipe" ((← IO.ofExcept wrote.get) == 0 && got.size == 200000) s!"{got.size}"
  discard <| waitpid pid
  let (r, w) ← Posix.pipe
  close r
  t.check "writeAll to a pipe with no reader gives EPIPE" ((← writeAll w "x".toUTF8) == 32)
  close w
  t.check "waitpid of no child throws" ((← (waitpid 1).toBaseIO) matches .error _)
  -- waitOutcome: an exit of 130 and an end by SIGINT, one number to waitpid, apart.
  let exited ← waitOutcome (← spawn #["/bin/sh", "-c", "exit 130"])
  let signaled ← waitOutcome (← spawn #["/bin/sh", "-c", "kill -s INT $$"])
  t.check "waitOutcome tells an exit of 130 from an end by SIGINT"
    (exited == .exited 130 && signaled == .signaled 2) s!"{repr exited} {repr signaled}"
  let a ← waitpid (← spawn #["/bin/sh", "-c", "exit 130"])
  let b ← waitpid (← spawn #["/bin/sh", "-c", "kill -s INT $$"])
  t.check "which waitpid gives as one number, 130" (a == 130 && b == 130) s!"{a} {b}"
  let r ← waitOutcome (← spawn #["/bin/sh", "-c", "exit 0"])
  t.check "waitOutcome gives an exit of 0" (r == .exited 0) s!"{repr r}"
  t.check "waitOutcome of no child throws" ((← (waitOutcome 1).toBaseIO) matches .error _)

/-- `kill` with any signal, and `catchSignals` in a child of its own (`tests
signals`), so this process keeps its own dispositions. -/
def signals (t : T) : IO Unit := do
  for sig in [(15 : UInt8), 1] do
    let pid ← spawn #["sleep", "100"]
    let sent ← kill pid.toInt32 sig.toUInt32
    let r ← waitOutcome pid
    t.check s!"kill {sig} ends a child with that signal" (sent == 0 && r == .signaled sig) s!"{sent} {repr r}"
    t.check s!"kill of the reaped child is ESRCH" ((← kill pid.toInt32 sig.toUInt32) == 3)
  t.check "kill 0 to this process checks it" ((← kill (← IO.Process.getPID).toInt32 0) == 0)
  t.check "kill of no such signal is EINVAL" ((← kill (← IO.Process.getPID).toInt32 99) == 22)
  let out ← IO.Process.output { cmd := (← IO.appPath).toString, args := #["signals"] }
  t.check "catchSignals reports SIGTERM then SIGHUP sent to the process, which lives on; a child spawned after it dies of SIGINT"
    (out.exitCode == 0 && out.stdout == "15 1 2\n") s!"{out.exitCode} {out.stdout.quote} {out.stderr.quote}"

/-- The output on the pty's master of `tests ARG` run with the slave as its stdio,
and how that process ended. -/
def onPty (arg : String) : IO (String × ExitOutcome) := do
  let (m, s) ← openPty
  let self := (← IO.appPath).toString
  let code ← waitOutcome (← spawn #[self, arg] (stdin := s) (stdout := s))
  -- Read while the slave is open: its last close drops what the master holds. Not
  -- `drainNow`: FIONREAD on a pty's master says 0 on macOS.
  let out ← read m 4096
  close s
  close m
  return (text out, code)

def term (t : T) : IO Unit := do
  t.check "termCtl 1002 with nothing handed over fails" ((← termCtl 1002) == 1)
  t.check "termCtl 1003 outside the full screen fails" ((← termCtl 1003) == 1)
  discard <| termCtl 1004
  let enter := "\x1b[?1049h"
  let leave := "\x1b[?1049l"
  let (out, code) ← onPty "term"
  t.check "termCtl 0 enters the full screen and 1000 leaves it"
    (code == .exited 0 && contains out s!"{enter}" && contains out "inside" && contains out leave) s!"{repr code} {out.quote}"
  let mouseOn := "\x1b[?1000h"
  let sgrOn := "\x1b[?1006h"
  t.check "termCtl 0 turns SGR mouse reports on" (contains out mouseOn && contains out sgrOn) out.quote
  let motionOn := "\x1b[?1003h"
  let motionOff := "\x1b[?1003l"
  let pointerReset := "\x1b]22;\x1b\\"
  -- The whole leave string, in its order: the pointer reset before the alternate
  -- screen is left, as each screen has a shape stack of its own.
  let leaveAll := s!"\x1b[?1006l{motionOff}\x1b[?1000l{pointerReset}\x1b[0m\x1b[?7h\x1b[?25h{leave}"
  t.check "termCtl 0 does not turn any-motion reports on, and leaving resets them and the pointer"
    (!contains out motionOn && contains out leaveAll) out.quote
  -- 256 hex digits, 128 bytes, as every build before `c/term.c` wrote and read
  -- them: a build hands the terminal to the next one across exec, which may be
  -- built from another version of this library.
  let (out, code) ← onPty "term-hand-over"
  t.check "termCtl 1003 hands the terminal over as 256 hex digits, 1004 takes it back, 1002 takes it"
    (code == .exited 0 && contains out "handed 0 256 true true took 0 true." && contains out leaveAll)
    s!"{repr code} {out.quote}"
  let (out, code) ← onPty "term-motion"
  t.check "termEnter (motion := true) turns SGR any-motion reports on"
    (code == .exited 0 && contains out enter && contains out motionOn && contains out sgrOn && !contains out mouseOn
      && contains out "inside") s!"{repr code} {out.quote}"
  t.check "and leaving turns them off and resets the pointer shape before leaving the alternate screen"
    (contains out leaveAll) s!"{repr code} {out.quote}"
  let (out, code) ← onPty "term-motion-no-mouse"
  t.check "termEnter (mouse := false) (motion := true) still turns any-motion reports on"
    (code == .exited 0 && contains out motionOn && contains out sgrOn && contains out leaveAll) s!"{repr code} {out.quote}"
  let (out, code) ← onPty "term-no-mouse"
  t.check "termEnter (mouse := false) enters the full screen without mouse reports"
    (code == .exited 0 && contains out enter && contains out "inside" && contains out leave
      && !contains out mouseOn && !contains out sgrOn) s!"{repr code} {out.quote}"
  let (out, code) ← onPty "term-signal"
  t.check "a signal leaves the full screen and ends the process by that signal"
    (code == .signaled 15 && contains out enter && contains out leave && !contains out "survived") s!"{repr code} {out.quote}"
  let (out, code) ← onPty "term-motion-signal"
  t.check "a signal leaves any-motion reports off and the pointer shape reset"
    (code == .signaled 15 && contains out motionOn && contains out leaveAll && !contains out "survived") s!"{repr code} {out.quote}"
  -- In a child, as op 1001 changes this process's signals. The child starts from
  -- SIGTSTP (18) at its default through `defaultSignals`, and SIGCONT (19) as it
  -- inherited it: op 1001 ignores SIGTSTP, catches SIGTERM (15) and leaves SIGCONT
  -- as it was; then `defaultSignals` puts SIGTSTP back, as an ignored signal
  -- survives exec into a command.
  let out ← IO.Process.output { cmd := (← IO.appPath).toString, args := #["term-dispositions"] }
  let ok := match out.stdout.splitOn "\n" with
    | [before, l1001, lDefault, ""] =>
      let c := before.drop "before 18 dfl 19 ".length |>.toString
      before == s!"before 18 dfl 19 {c}"
        && l1001 == s!"1001 18 ign 19 {c} 15 caught" && lDefault == s!"defaultSignals 18 dfl 19 {c}"
    | _ => false
  t.check "termCtl 1001 ignores SIGTSTP, leaves SIGCONT alone, and defaultSignals puts SIGTSTP back"
    (out.exitCode == 0 && ok) s!"{out.exitCode} {out.stdout.quote}"

def main (args : List String) : IO UInt32 := do
  match args with
  | ["exec-fails"] => exec #["/nonexistent/lean-posix"] "lean-posix exec"; return 0
  | ["exec"] => exec #["echo", "became"] "exec"; return 1
  | ["default-pipe"] =>
    defaultPipe
    exec #["/bin/sh", "-c", "kill -s INT $$; kill -s PIPE $$; echo survived"] "default-pipe"; return 1
  | ["lock-handed", path, fd] =>
    match ← lockHanded path (fd.toNat?.getD 0).toUInt32 with
    | .ok _ => return 0
    | .error e => return if e < 255 then e else 255
  | ["lock-dir-hold", path] =>
    if (← lockDir path) == 0xffffffff then return 1
    IO.println "held"
    (← IO.getStdout).flush
    discard <| (← IO.getStdin).getLine
    return 0
  | ["lock-dir-signal", path] =>
    let kq ← kqOpen
    if (← catchSignals kq #[30]) != 0 then return 2
    if (← noRestart 30) != 0 then return 3
    let main_ ← thisThread
    let stdin ← IO.getStdin
    let stdout ← IO.getStdout
    let _ ← IO.asTask (prio := .dedicated) do
      discard <| stdin.getLine
      let seen ← inFlockWithin main_ 1000000
      if seen == 1 then
        let r ← signalThread main_ 30
        stdout.putStrLn s!"sent {r}"
      else
        stdout.putStrLn s!"not seen in flock: {seen}"
      stdout.flush
    stdout.putStrLn "ready"
    stdout.flush
    let fd ← lockDir path
    stdout.putStrLn (if fd == 0xffffffff then "gave up" else "locked")
    stdout.flush
    return 0
  | ["path-eacces"] =>
    match ← trySpawn #["lean-posix-echo"] with
    | .ok pid => return (← waitpid pid)
    | .error f => IO.println s!"{f.stage} {f.errno}"; return 0
  | ["signals"] =>
    let kq ← kqOpen
    if (← catchSignals kq #[9]) != 22 then IO.println "SIGKILL caught"; return 1
    if (← catchSignals kq #[15, 1, 2]) != 0 then return 2
    let self := (← IO.Process.getPID).toInt32
    if (← kill self 15) != 0 || (← kill self 1) != 0 then return 3
    let a ← nextSignal kq
    let b ← nextSignal kq
    let child ← waitOutcome (← spawn #["/bin/sh", "-c", "kill -s INT $$; exit 7"])
    let say : Except UInt32 UInt32 → String
      | .ok s => toString s
      | .error e => s!"error {e}"
    let c := match child with | .signaled s => toString s | .exited e => s!"exit {e}"
    IO.println s!"{say a} {say b} {c}"
    return 0
  | ["own-session"] =>
    -- Started with `setsid`: the session's id is this process's pid.
    match ← killSession (← IO.Process.getPID) with
    | .error e => IO.println s!"{e}"
    | .ok k => IO.println s!"ran {repr k}"
    return 0
  | ["winch"] =>
    let kq ← kqOpen
    kqSetup kq
    let say : IO Unit := do
      let (rows, cols) ← winSize
      IO.print s!"{rows} {cols}\n"
      (← IO.getStdout).flush
    say
    for _ in [0:100] do
      let (m, _) ← kqWait kq false
      if m &&& 2 != 0 then say; return 0
    return 4
  | ["ctty-spawn"] =>
    let (m, s) ← openPty
    match ← trySpawn #["true"] #[] s s s (setsid := true) (ctty := true) with
    | .ok pid => discard <| waitpid pid; IO.println "ran"
    | .error f => IO.println s!"{f.stage} {f.errno}"
    close s; close m
    return 0
  | ["open-fds", limit] =>
    -- An ioctl on each number, which opens nothing: EBADF (9) when it is closed.
    let open_ ← (List.range (limit.toNat?.getD 0)).filterM fun fd => do
      return match ← winSizeOf fd.toUInt32 with | .error 9 => false | _ => true
    IO.print s!"{" ".intercalate (open_.map toString)}\n"
    return 0
  | ["term"] =>
    if (← termCtl 0) != 0 then return 3
    IO.print "inside"
    (← IO.getStdout).flush
    discard <| termCtl 1000
    return 0
  | ["term-hand-over"] =>
    if (← termCtl 0) != 0 then return 3
    let put ← termCtl 1003
    let h := (← IO.getEnv "LEAN_POSIX_TERMIOS").getD ""
    let hex := h.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')
    discard <| termCtl 1004
    let cancelled := (← IO.getEnv "LEAN_POSIX_TERMIOS").isNone
    discard <| termCtl 1003
    let took ← termCtl 1002
    let removed := (← IO.getEnv "LEAN_POSIX_TERMIOS").isNone
    IO.print s!"handed {put} {h.length} {hex} {cancelled} took {took} {removed}."
    (← IO.getStdout).flush
    discard <| termCtl 1000
    return 0
  | ["term-no-mouse"] =>
    if (← termEnter (mouse := false)) != 0 then return 3
    IO.print "inside"
    (← IO.getStdout).flush
    discard <| termCtl 1000
    return 0
  | ["term-motion"] =>
    if (← termEnter (motion := true)) != 0 then return 3
    IO.print "inside"
    (← IO.getStdout).flush
    discard <| termCtl 1000
    return 0
  | ["term-motion-no-mouse"] =>
    if (← termEnter (mouse := false) (motion := true)) != 0 then return 3
    discard <| termCtl 1000
    return 0
  | ["term-motion-signal"] =>
    discard <| termCtl 1001
    if (← termEnter (motion := true)) != 0 then return 3
    discard <| IO.Process.output { cmd := "kill", args := #["-TERM", toString (← IO.Process.getPID)] }
    IO.print "survived"
    return 0
  | ["term-dispositions"] =>
    defaultSignals
    IO.print s!"before 18 {← disposition 18} 19 {← disposition 19}\n"
    discard <| termCtl 1001
    IO.print s!"1001 18 {← disposition 18} 19 {← disposition 19} 15 {← disposition 15}\n"
    defaultSignals
    IO.print s!"defaultSignals 18 {← disposition 18} 19 {← disposition 19}\n"
    return 0
  | ["term-signal"] =>
    discard <| termCtl 1001
    if (← termCtl 0) != 0 then return 3
    discard <| IO.Process.output { cmd := "kill", args := #["-TERM", toString (← IO.Process.getPID)] }
    IO.print "survived"
    return 0
  | _ =>
  let t : T := { bad := ← IO.mkRef 0 }
  let dir ← IO.FS.createTempDir
  try
    fds t dir
    fileAt t dir
    pty t
    cttyHelper t dir
    inherited t dir
    locks t dir
    kq t dir
    exits t
    sessions t
    kqView t dir
    starts t
    processes t
    signals t
    spawns t dir
    term t
  finally
    IO.FS.removeDirAll dir
  return (← t.bad.get).toUInt32
