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
  let (m, changed) ← kqWait k true
  t.check "kqWait: a file of tag 0 and one of another tag" (m == 4 ||| 8) s!"{m}"
  t.check "kqWait gives the descriptors of tag 0" (changed == #[fd]) s!"{changed}"
  let r ← watch k (dir / "none").toString 0
  t.check "watch of no file gives ENOENT" (r == 0x80000000 ||| 2) s!"{r}"
  close fd
  close fd2
  close k

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
  alarm 0
  t.check "peakRss is positive" ((← peakRss) > 0)

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
    kqView t dir
    processes t
    term t
  finally
    IO.FS.removeDirAll dir
  return (← t.bad.get).toUInt32
