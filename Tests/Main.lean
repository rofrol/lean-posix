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
  let pid ← spawn #[(← IO.appPath).toString, "winch"] #[] s s s (setsid := true) (ctty := true)
  let first ← linesOf m 1
  t.check "with setsid and ctty, the pty is the child's controlling terminal, of the size set" (first == "33 77\n") first.quote
  t.check "setWinSize on the master" ((← setWinSize m 40 120) == 0)
  let second ← linesOf m 1
  t.check "a size set on the master reaches the child as SIGWINCH" (second == "40 120\n") second.quote
  t.check "and the child exits" ((← waitpid pid) == 0)
  close s
  close m

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
  let evs ← eventsUntil k 1 8
  t.check "nextEvent: the output closed" (evs.getLast? == some 1) s!"{evs}"
  unwatchRead k out
  let e ← nextEvent k
  t.check "nextEvent: once the output is unwatched, the process exited" (e == 2) s!"{e}"
  discard child.wait
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

/-- The output on the pty's master of `tests ARG` run with the slave as its stdio. -/
def onPty (arg : String) : IO (String × UInt32) := do
  let (m, s) ← openPty
  let self := (← IO.appPath).toString
  -- The slave is inherited, as only the master is kept from children.
  let child ← IO.Process.spawn { cmd := "/bin/sh", args := #["-c", s!"exec \"$0\" {arg} <&{s} >&{s}", self] }
  let code ← child.wait
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
    (code == 0 && contains out s!"{enter}" && contains out "inside" && contains out leave) s!"{code} {out.quote}"
  let (out, code) ← onPty "term-signal"
  t.check "a signal leaves the full screen and ends the process"
    (code != 0 && contains out enter && contains out leave && !contains out "survived") s!"{code} {out.quote}"

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
  | ["path-eacces"] =>
    match ← trySpawn #["lean-posix-echo"] with
    | .ok pid => return (← waitpid pid)
    | .error f => IO.println s!"{f.stage} {f.errno}"; return 0
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
  | ["term"] =>
    if (← termCtl 0) != 0 then return 3
    IO.print "inside"
    (← IO.getStdout).flush
    discard <| termCtl 1000
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
    pty t
    locks t dir
    kq t dir
    exits t
    kqView t dir
    starts t
    processes t
    spawns t dir
    term t
  finally
    IO.FS.removeDirAll dir
  return (← t.bad.get).toUInt32
