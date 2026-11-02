/-!
# Locks and links

Exclusive `flock`s, and a hard link that fails on a taken name, so writers that
race never share a file. The numbers are macOS's: O_RDWR 2, O_CREAT 0x200,
O_DIRECTORY 0x100000, O_CLOEXEC 0x1000000, LOCK_EX 2, LOCK_NB 4, EINTR 4,
EEXIST 17, EWOULDBLOCK 35.
-/

namespace Posix

/-- Opens `path` (created if missing, mode 0644), which no child inherits, and
locks it: the descriptor, or the errno with the high bit set. Blocking (`block`
nonzero), it waits past EINTR until no other holder is left. -/
@[extern c inline "({ extern int open(const char*, int, ...); extern int flock(int, int); extern int close(int); extern int* __error(void); unsigned r; int fd = open(lean_string_cstr(#1), 0x2 | 0x200 | 0x1000000, 0644); if (fd < 0) r = 0x80000000u | (unsigned)*__error(); else { int k; do k = flock(fd, #2 ? 2 : 2 | 4); while (k != 0 && *__error() == 4); if (k == 0) r = (unsigned)fd; else { r = 0x80000000u | (unsigned)*__error(); close(fd); } } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
opaque lockRaw (path : @& String) (block : UInt8) : IO UInt32

/-- macOS's EWOULDBLOCK: another open file holds the lock. -/
def lockHeld : UInt32 := 35

/-- An exclusive `flock` on the file `path`, created if missing: its descriptor, or
the errno, `lockHeld` when another holds it and `block` is false. The lock is held
until `unlock` or the process's end, whichever comes first, as only this
descriptor holds it. -/
def lockFile (path : System.FilePath) (block : Bool) : IO (Except UInt32 UInt32) := do
  let r ← lockRaw path.toString (if block then 1 else 0)
  return if r &&& 0x80000000 == 0 then .ok r else .error (r &&& 0x7fffffff)

/-- Lets go of a lock `lockFile` took. -/
@[extern c inline "({ extern int close(int); close((int)#1); lean_io_result_mk_ok(lean_box(0)); })"]
opaque unlock (fd : UInt32) : IO Unit

/-- An exclusive `flock` on the directory `path`, waited for and held until the
process ends; no child inherits it. -1 (as a `UInt32`) when it cannot be had. -/
@[extern c inline "({ extern int open(const char*, int, ...); extern int flock(int, int); extern int close(int); int fd = open(lean_string_cstr(#1), 0x100000 | 0x1000000); if (fd >= 0 && flock(fd, 2) != 0) { close(fd); fd = -1; } lean_io_result_mk_ok(lean_box_uint32((unsigned)fd)); })"]
opaque lockDir (path : @& String) : IO UInt32

/-- A hard link `to` of `from`: 0, or the errno, EEXIST (17) when `to` is taken. -/
@[extern c inline "({ extern int link(const char*, const char*); extern int* __error(void); int r = link(lean_string_cstr(#1), lean_string_cstr(#2)); lean_io_result_mk_ok(lean_box_uint32(r == 0 ? 0u : (unsigned)*__error())); })"]
opaque link (from_ to : @& String) : IO UInt32

end Posix
