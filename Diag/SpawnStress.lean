import Posix
import Std.Data.HashMap

/-!
# spawnstress: does `trySpawn` fail while other threads are inside libSystem?

A diagnostic stress run, not a test (AGENTS.md Rule 10 allows a labelled stress
loop as a diagnostic, never as a regression test); `lake test` does not run it.

On macOS `fork` runs libSystem's atfork handlers before the child's own code,
and in an Odin program a fork while another thread was inside libnotify's
`os_once` killed the child before its exec. This program asked whether
`Posix.trySpawn`, when it forked, met that in a multithreaded Lean process: it
did (item tuvst2), and `trySpawn` moved to `posix_spawn` (item 53zc6j). With
`200 20 2` on macOS 27.2 arm64, 30 of 4000 children were killed by SIGKILL
before that change, none after it.

`lake exe spawnstress ROUNDS SPAWNS THREADS [KIND,...]` runs ROUNDS fresh worker processes
(this program with `worker`), one after another. A fresh process because an
`os_once` initializer runs only on its first call in a process: each worker
starts THREADS dedicated Lean threads per kind of libSystem call below, each
calling it in a loop from the start, and its main thread at once starts SPAWNS
children with `trySpawn`, one at a time, each `/bin/echo ack` with its stdout on
a pipe. The `ack` it reads back says the child reached its exec and ran; the
child is then reaped with `waitOutcome`. Every spawn's outcome is counted:

- `exec reached, exited 0`: the `ack` came back and echo exited 0.
- `no ack, signal N` (or `no ack, exit N`): `trySpawn` returned a pid but no
  `ack` came back. The count alone does not say whether the child died before
  echo wrote or where; its crash report (`~/Library/Logs/DiagnosticReports`)
  says where.
- `setup failure: STAGE errno N`: `trySpawn` reported a failed stage.

THREADS 0 is the control: the same spawns with no other thread calling in.
KIND,... limits the threads to those kinds of call (`notify`, `getaddrinfo`,
`getpwuid_r`, `dispatch`).
A worker or child that hangs hangs the run; that is a finding too, seen as
the run going quiet.

The kinds of call, each into libSystem and each with process-wide state set up
once on first use: libnotify (`notify_register_check`, `notify_post`,
`notify_check`, `notify_cancel` on a name of this program's), libinfo's
`getaddrinfo` for `localhost`, `getpwuid_r` for the process's own uid
(opendirectoryd through XPC), and libdispatch (eight blocks on a global queue
in a group, waited for).
-/

open Posix

@[extern c inline "({ extern unsigned notify_register_check(const char*, int*); extern unsigned notify_check(int, int*); extern unsigned notify_post(const char*); extern unsigned notify_cancel(int); const char* n = \"org.rofrol.lean-posix.spawnstress\"; int t = 0, c = 0; unsigned r = notify_register_check(n, &t); if (r == 0) { r = notify_post(n); if (r == 0) r = notify_check(t, &c); notify_cancel(t); } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque notifyRound : IO UInt32

@[extern c inline "({ extern int getaddrinfo(const char*, const char*, const void*, void**); extern void freeaddrinfo(void*); void* res = 0; int r = getaddrinfo(\"localhost\", \"80\", 0, &res); if (r == 0) freeaddrinfo(res); lean_io_result_mk_ok(lean_box_uint32((unsigned)r)); })"]
opaque lookupLocalhost : IO UInt32

@[extern c inline "({ extern unsigned getuid(void); extern int getpwuid_r(unsigned, void*, char*, unsigned long, void**); unsigned long long pw[32]; char buf[4096]; void* out = 0; int r = getpwuid_r(getuid(), pw, buf, sizeof buf, &out); lean_io_result_mk_ok(lean_box_uint32(r ? (unsigned)r : out ? 0u : 0xffffu)); })"]
opaque passwdOfSelf : IO UInt32

@[extern c inline "({ extern void* dispatch_get_global_queue(long, unsigned long); extern void* dispatch_group_create(void); extern void dispatch_group_async_f(void*, void*, void*, void (*)(void*)); extern long dispatch_group_wait(void*, unsigned long long); extern void dispatch_release(void*); extern void* malloc(unsigned long); extern void free(void*); void* g = dispatch_group_create(); void* q = dispatch_get_global_queue(0, 0); for (int i = 0; i < 8; i++) dispatch_group_async_f(g, q, malloc(16), free); long r = dispatch_group_wait(g, ~0ULL); dispatch_release(g); lean_io_result_mk_ok(lean_box_uint32((unsigned)r)); })"]
opaque dispatchBurst : IO UInt32

def kinds : Array (String × IO UInt32) :=
  #[("notify", notifyRound), ("getaddrinfo", lookupLocalhost), ("getpwuid_r", passwdOfSelf),
    ("dispatch", dispatchBurst)]

/-- Calls `f` until `stop` is set: the number of calls, and of calls that
returned non-zero. -/
partial def callLoop (stop : IO.Ref Bool) (f : IO UInt32) (n errs : Nat) : IO (Nat × Nat) := do
  if ← stop.get then return (n, errs)
  let r ← f
  callLoop stop f (n + 1) (if r == 0 then errs else errs + 1)

partial def readAll (fd : UInt32) (acc : ByteArray := .empty) : IO ByteArray := do
  let b ← Posix.read fd 4096
  if b.isEmpty then return acc else readAll fd (acc ++ b)

abbrev Counts := Std.HashMap String Nat

def Counts.add (c : Counts) (k : String) (n : Nat := 1) : Counts := c.insert k (c.getD k 0 + n)

/-- One `trySpawn` of `/bin/echo ack`, classified, with the child's pid (0 when none). -/
def oneSpawn : IO (String × UInt32) := do
  let (r, w) ← Posix.pipe
  let res ← Posix.trySpawn #["/bin/echo", "ack"] (stdout := w)
  Posix.close w
  match res with
  | .error f => Posix.close r; return (s!"setup failure: {f.stage} errno {f.errno}", 0)
  | .ok pid =>
    let out ← readAll r
    Posix.close r
    let ack := out == "ack\n".toUTF8
    let k := match ack, ← Posix.waitOutcome pid with
      | true, .exited 0 => "exec reached, exited 0"
      | true, .exited c => s!"exec reached, exit {c}"
      | true, .signaled s => s!"exec reached, signal {s}"
      | false, .exited c => s!"no ack, exit {c}"
      | false, .signaled s => s!"no ack, signal {s}"
    return (k, pid)

/-- A worker: the threads start, the spawns begin at once; prints `COUNT<TAB>KEY` lines,
and to stderr each spawn that did not exit 0 after its ack, with its index and pid. -/
def worker (spawns perKind : Nat) (only : List String) : IO Unit := do
  let stop ← IO.mkRef false
  let mut tasks := #[]
  for (name, f) in kinds do
    unless only.isEmpty || only.contains name do continue
    for _ in [0:perKind] do
      tasks := tasks.push (name, ← IO.asTask (prio := .dedicated) (callLoop stop f 0 0))
  let mut counts : Counts := {}
  for i in [0:spawns] do
    let (k, pid) ← oneSpawn
    unless k == "exec reached, exited 0" do
      IO.eprintln s!"spawnstress: worker {← IO.Process.getPID} spawn {i} pid {pid}: {k}"
    counts := counts.add k
  stop.set true
  for (name, t) in tasks do
    match ← IO.wait t with
    | .ok (n, e) => counts := (counts.add s!"calls {name}" n).add s!"calls {name} non-zero" e
    | .error err => counts := counts.add s!"thread error {name}: {err}"
  for (k, n) in counts do
    IO.println s!"{n}\t{k}"

def render (c : Counts) : String :=
  let rows := c.toArray.qsort (fun a b => a.1 < b.1)
  "\n".intercalate (rows.map (fun (k, n) => s!"  {n}\t{k}")).toList

def driver (rounds spawns perKind : Nat) (only : List String) : IO UInt32 := do
  let exe := (← IO.appPath).toString
  IO.println s!"spawnstress: {rounds} workers, {spawns} spawns each, {perKind} threads per kind of call{if only.isEmpty then "" else s!" ({",".intercalate only})"}"
  let mut total : Counts := {}
  for i in [0:rounds] do
    let (r, w) ← Posix.pipe
    match ← Posix.trySpawn #[exe, "worker", toString spawns, toString perKind, ",".intercalate only] (stdout := w) with
    | .error f =>
      Posix.close w; Posix.close r
      total := total.add s!"worker not started: {f.stage} errno {f.errno}"
    | .ok pid =>
      Posix.close w
      let out ← readAll r
      Posix.close r
      let o ← Posix.waitOutcome pid
      unless o == .exited 0 do total := total.add s!"worker ended {repr o}"
      for line in (String.fromUTF8! out).splitOn "\n" do
        match line.splitOn "\t" with
        | [n, k] => total := total.add k n.toNat!
        | _ => pure ()
    if (i + 1) % 10 == 0 || i + 1 == rounds then
      let spawnsSeen := total.fold (fun s k n =>
        if ["exec", "no ack", "setup failure"].any (fun (pre : String) => k.startsWith pre) then s + n else s) 0
      IO.println s!"round {i + 1}/{rounds}: {spawnsSeen} spawn outcomes counted"
  IO.println s!"totals:\n{render total}"
  let bad := total.fold (fun s k n => if k.startsWith "calls" || k == "exec reached, exited 0" then s else s + n) 0
  return if bad == 0 then 0 else 1

def kindsOf (o : String) : List String := (o.splitOn ",").filter (!·.isEmpty)

def main (args : List String) : IO UInt32 := do
  match args with
  | ["worker", s, k, o] => worker s.toNat! k.toNat! (kindsOf o); return 0
  | [r, s, k] => driver r.toNat! s.toNat! k.toNat! []
  | [r, s, k, o] =>
    match (kindsOf o).find? (fun n => !kinds.any (·.1 == n)) with
    | some n => IO.eprintln s!"spawnstress: no kind of call {n}"; return 2
    | none => driver r.toNat! s.toNat! k.toNat! (kindsOf o)
  | _ => IO.eprintln "usage: spawnstress ROUNDS SPAWNS THREADS [KIND,...]"; return 2
