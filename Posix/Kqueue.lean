import Posix.Fd

/-!
# kqueue: file, process and signal events

Lean's library has no file watching and no process-exit event. These are the two
ways of waiting a program built on this library uses, each one blocking `kevent`:

- a process and its output pipe (`watchSession`, `nextEvent`): its end is the
  process exiting (EVFILT_PROC, NOTE_EXIT), not its output closing, which an orphan
  holding the pipe can put off for ever; and a directory, written to by others;
- stdin, the window size and files (`kqOpen`, `kqSetup`, `watch`, `kqWait`), for a
  full-screen program that wakes on events only;
- the exits of processes that need not be this program's children
  (`watchExits`, `ExitWatch.wait`), which nothing else in Lean or POSIX can wait
  for.

macOS's numbers: EVFILT_READ -1, EVFILT_VNODE -4, EVFILT_PROC -5, EVFILT_SIGNAL -6,
EV_ADD 1, EV_DELETE 2, EV_ONESHOT 0x10, EV_CLEAR 0x20, EV_EOF 0x8000, NOTE_DELETE 1,
NOTE_WRITE 2, NOTE_EXTEND 4, NOTE_RENAME 0x20, NOTE_EXIT 0x80000000, SIGWINCH 28,
F_SETFD 2, FD_CLOEXEC 1, F_GETFL 3, F_SETFL 4, O_NONBLOCK 4, O_EVTONLY 0x8000,
O_CLOEXEC 0x1000000, EINTR 4, ESRCH 3. `struct kevent` is declared in each expression as
macOS lays it out.
-/

namespace Posix

/-- A descriptor of `path` for its events only, which no child inherits; a large
number when it cannot be opened. -/
@[extern c inline "({ extern int open(const char*, int, ...); lean_io_result_mk_ok(lean_box_uint32((unsigned)open(lean_string_cstr(#1), 0x8000 | 0x1000000))); })"]
opaque openEvents (path : @& String) : IO UInt32

/-- A kqueue, which no child inherits, that reports `fd` readable, `pid`'s exit,
and a write to the directory `dir` (from `openEvents`; none when that failed);
`fd` is made non-blocking. With the high bit set, `pid` had exited already and
only `fd` and `dir` are watched. -/
@[extern c inline "({ extern int kqueue(void); extern int kevent(int, const void*, int, void*, int, const void*); extern int fcntl(int, int, ...); struct kev { unsigned long ident; short filter; unsigned short flags; unsigned fflags; long data; void* udata; }; int kq = kqueue(); fcntl(kq, 2, 1); int fd = (int)#2; fcntl(fd, 4, fcntl(fd, 3) | 4); struct kev r = { (unsigned long)fd, -1, 1, 0, 0, 0 }; kevent(kq, &r, 1, 0, 0, 0); if ((int)#3 >= 0) { struct kev d = { (unsigned long)#3, -4, 1 | 0x20, 2, 0, 0 }; kevent(kq, &d, 1, 0, 0, 0); } struct kev p = { (unsigned long)#1, -5, 1 | 0x10, 0x80000000u, 0, 0 }; unsigned gone = kevent(kq, &p, 1, 0, 0, 0) != 0 ? 0x80000000u : 0; lean_io_result_mk_ok(lean_box_uint32((unsigned)kq | gone)); })"]
opaque watchSession (pid fd dir : UInt32) : IO UInt32

/-- Blocks until the kqueue of `watchSession` has news: 0 the output is readable, 1
the output closed with nothing left in it, 2 the process exited (or the kqueue
failed, which ends the wait all the same), 3 the directory was written to. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); struct kev { unsigned long ident; short filter; unsigned short flags; unsigned fflags; long data; void* udata; } e; int n; do n = kevent((int)#1, 0, 0, &e, 1, 0); while (n < 0 && *__error() == 4); unsigned r = n != 1 || e.filter == -5 ? 2 : e.filter == -4 ? 3 : (e.flags & 0x8000) && e.data == 0 ? 1 : 0; lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque nextEvent (kq : UInt32) : IO UInt32

/-- Stops reporting `fd`, whose writers are all gone. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); struct kev { unsigned long ident; short filter; unsigned short flags; unsigned fflags; long data; void* udata; } r = { (unsigned long)#2, -1, 2, 0, 0, 0 }; kevent((int)#1, &r, 1, 0, 0, 0); lean_io_result_mk_ok(lean_box(0)); })"]
opaque unwatchRead (kq fd : UInt32) : IO Unit

/-- A kqueue that no child inherits. -/
@[extern c inline "({ extern int kqueue(void); extern int fcntl(int, int, ...); int k = kqueue(); fcntl(k, 2, 1); lean_io_result_mk_ok(lean_box_uint32((unsigned)k)); })"]
opaque kqOpen : IO UInt32

/-- Watches stdin for input and SIGWINCH, which is ignored by default and still
reaches the kqueue. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c[2] = {{0, -1, 1, 0, 0, 0}, {28, -6, 1, 0, 0, 0}}; kevent((int)#1, c, 2, 0, 0, 0); lean_io_result_mk_ok(lean_box(0)); })"]
opaque kqSetup (kq : UInt32) : IO Unit

/-- Opens `path` for events only and watches it for writes, growth, deletion and
renames, tagged with `tag` (0 or not: `kqWait` tells the two apart); the
descriptor, or 0x80000000 or-ed with the errno when it cannot be opened or
watched. Closing the descriptor ends the watch. -/
@[extern c inline "({ extern int open(const char*, int, ...); extern int kevent(int, const void*, int, void*, int, const void*); extern int close(int); extern int* __error(void); unsigned r; int fd = open(lean_string_cstr(#2), 0x8000 | 0x1000000); if (fd < 0) r = 0x80000000u | (unsigned)*__error(); else { struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c = {(unsigned long)fd, -4, 1 | 0x20, 1 | 2 | 4 | 0x20, 0, (void*)(unsigned long)#3}; if (kevent((int)#1, &c, 1, 0, 0, 0) != 0) { r = 0x80000000u | (unsigned)*__error(); close(fd); } else r = (unsigned)fd; } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque watch (kq : UInt32) (path : @& String) (tag : UInt32) : IO UInt32

/-- Waits until something happens, or with `poll` only looks at what has: 1 input,
2 a new window size, 4 a file watched with tag 0 changed, 8 one with another tag
changed, or-ed, 0x80000000 when the wait fails; and the descriptors of the files
of tag 0 that changed. At most 64 events a call; the rest wait for the next. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } e[64]; struct { long s; long ns; } zero = {0, 0}; int n; do n = kevent((int)#1, 0, 0, e, 64, #2 ? (const void*)&zero : 0); while (n < 0 && *__error() == 4); unsigned m = n < 0 ? 0x80000000u : 0; lean_object* fds = lean_mk_empty_array(); for (int i = 0; i < n; i++) { unsigned b = e[i].f == -1 ? 1 : e[i].f == -6 ? 2 : e[i].u ? 8 : 4; m |= b; if (b == 4) fds = lean_array_push(fds, lean_box_uint32((unsigned)e[i].id)); } lean_object* p = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p, 0, lean_box_uint32(m)); lean_ctor_set(p, 1, fds); lean_io_result_mk_ok(p); })"]
opaque kqWait (kq : UInt32) (poll : Bool) : IO (UInt32 × Array UInt32)

/-- Watches the exit of process `pid` on `kq` (from `kqOpen`), once: 0 when it is
watched, ESRCH (3) when no live process has that pid, one that exited and is not
reaped yet included, or the errno of another failure. The watch holds the process,
not its pid: a process that takes the pid after this one exited is not reported. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c = {(unsigned long)#2, -5, 1 | 0x10, 0x80000000u, 0, 0}; unsigned r = kevent((int)#1, &c, 1, 0, 0, 0) != 0 ? (unsigned)*__error() : 0; lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque watchExit (kq pid : UInt32) : IO UInt32

/-- Stops watching the exit of `pid` on `kq`. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } c = {(unsigned long)#2, -5, 2, 0, 0, 0}; kevent((int)#1, &c, 1, 0, 0, 0); lean_io_result_mk_ok(lean_box(0)); })"]
opaque unwatchExit (kq pid : UInt32) : IO Unit

/-- Blocks until `n` exits watched on `kq` have come: 0 then, or the errno of a
failed wait. `kq` holds exit watches only; every event it gives counts as one. -/
@[extern c inline "({ extern int kevent(int, const void*, int, void*, int, const void*); extern int* __error(void); struct { unsigned long id; short f; unsigned short fl; unsigned ff; long d; void* u; } e[64]; unsigned left = #2, r = 0; while (left > 0) { int n = kevent((int)#1, 0, 0, e, 64, 0); if (n < 0) { if (*__error() == 4) continue; r = (unsigned)*__error(); break; } left = (unsigned)n >= left ? 0 : left - (unsigned)n; } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
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
