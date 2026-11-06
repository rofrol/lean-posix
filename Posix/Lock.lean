/-!
# Locks and links

Exclusive `flock`s, and a hard link that fails on a taken name, so writers that
race never share a file, and a lock handed to the next program this process
executes. The numbers are macOS's: O_RDWR 2, O_CREAT 0x200, O_DIRECTORY 0x100000,
O_CLOEXEC 0x1000000, LOCK_EX 2, LOCK_NB 4, F_SETFD 2, FD_CLOEXEC 1, EINTR 4,
EEXIST 17, EWOULDBLOCK 35; `struct stat64`, the same on arm64 and x86_64, has
`st_dev` (32 bits) at 0 and `st_ino` (64 bits) at 8, in 144 bytes.
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

/-- What `lockHanded` gives when the descriptor is open on another file than the
path names: above every errno. -/
def lockElsewhere : UInt32 := 0x10000

@[extern c inline "({ extern int fstat64(int, void*); extern int stat64(const char*, void*); extern int flock(int, int); extern int fcntl(int, int, ...); extern int* __error(void); unsigned long long a[32], b[32]; unsigned r; int fd = (int)#2; if (fstat64(fd, a) != 0 || stat64(lean_string_cstr(#1), b) != 0) r = (unsigned)*__error(); else if (((int*)a)[0] != ((int*)b)[0] || a[1] != b[1]) r = 0x10000u; else { int k; do k = flock(fd, 2 | 4); while (k != 0 && *__error() == 4); if (k != 0) r = (unsigned)*__error(); else r = fcntl(fd, 2, 1) == 0 ? 0u : (unsigned)*__error(); } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
private opaque lockHandedRaw (path : @& String) (fd : UInt32) : IO UInt32

/-- Takes over the lock of the file `path` that the program this process was before
an exec handed it on the descriptor `fd` (one without close-on-exec, which the exec
kept open, and with it its open file and that file's `flock`, so the lock is never
let go of): `fd` once it is open on the file `path` names now (the same device and
inode) and holds its exclusive `flock`, asked for again without waiting, which the
open file that holds it is granted at once; `fd` is then closed on exec again, so
no child inherits it, and holds the lock as one `lockFile` gave. Else the errno
(EBADF when `fd` is not open, ENOENT when `path` is not there), `lockHeld` when
another open file holds the lock, or `lockElsewhere` when `fd` is open on another
file; `fd` is then left as it was. An `fd` open on `path` that holds no lock takes
it when no other holds it. -/
def lockHanded (path : System.FilePath) (fd : UInt32) : IO (Except UInt32 UInt32) := do
  let r ← lockHandedRaw path.toString fd
  return if r == 0 then .ok fd else .error r

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
