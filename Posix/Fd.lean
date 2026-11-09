/-!
# File descriptors

A file descriptor is a `UInt32`; a negative result of libc arrives as a large one.
Each binding is a C expression that declares what it calls, so no header and no C
file is needed. The numbers are macOS's: F_SETFD 2, FD_CLOEXEC 1, F_GETFL 3,
F_SETFL 4, O_NONBLOCK 4, O_CLOEXEC 0x1000000, EINTR 4, FIONREAD 0x4004667f,
ENOENT 2; `struct stat64` (`struct stat` on arm64), the same on arm64 and x86_64,
has `st_dev` (32 bits) at 0, `st_ino` (64 bits) at 8 and `st_size` (64 bits) at 96,
in 144 bytes.
-/

namespace Posix

/-- Makes `to` a copy of `from`. -/
@[extern c inline "({ extern int dup2(int, int); dup2((int)#1, (int)#2); lean_io_result_mk_ok(lean_box(0)); })"]
opaque dup2 (from_ to : UInt32) : IO Unit

/-- A copy of `fd` that no child inherits. -/
@[extern c inline "({ extern int dup(int); extern int fcntl(int, int, ...); int d = dup((int)#1); fcntl(d, 2, 1); lean_io_result_mk_ok(lean_box_uint32((unsigned)d)); })"]
opaque dupPrivate (fd : UInt32) : IO UInt32

@[extern c inline "({ extern int close(int); close((int)#1); lean_io_result_mk_ok(lean_box(0)); })"]
opaque close (fd : UInt32) : IO Unit

/-- At most `n` bytes, past any EINTR; none at the end of the input, or on an error
(the one a closed terminal gives too). -/
@[extern c inline "({ extern long read(int, void*, unsigned long); lean_object* b = lean_alloc_sarray(1, 0, #2); extern int* __error(void); long r; do r = read((int)#1, lean_sarray_cptr(b), #2); while (r < 0 && *__error() == 4); lean_sarray_set_size(b, r > 0 ? r : 0); lean_io_result_mk_ok(b); })"]
opaque read (fd : UInt32) (n : USize) : IO ByteArray

/-- At most `n` bytes of `path` from `offset`; none past its end or with no file.
The file is opened and closed again, so nothing stays open between reads. -/
@[extern c inline "({ extern int open(const char*, int, ...); extern long pread(int, void*, unsigned long, long long); extern int close(int); lean_object* b = lean_alloc_sarray(1, 0, #3); long r = -1; int fd = open(lean_string_cstr(#1), 0x1000000); if (fd >= 0) { r = pread(fd, lean_sarray_cptr(b), #3, (long long)#2); close(fd); } lean_sarray_set_size(b, r > 0 ? r : 0); lean_io_result_mk_ok(b); })"]
opaque readAt (path : @& String) (offset : UInt64) (n : USize) : IO ByteArray

/-- A file as `readFileAt` found it: its device and inode, its size and the bytes
read from it, all from one open descriptor. -/
structure FileAt where
  dev : UInt32
  ino : UInt64
  size : UInt64
  bytes : ByteArray

/-- macOS's ENOENT: no file at the path. -/
def noSuchFile : UInt32 := 2

@[extern c inline "({ extern int open(const char*, int, ...); extern int fstat64(int, void*); extern long pread(int, void*, unsigned long, long long); extern int close(int); extern int* __error(void); unsigned long long st[18]; lean_object* res = 0; unsigned e = 0; int fd = open(lean_string_cstr(#1), 0x1000000); if (fd < 0) e = (unsigned)*__error(); else if (fstat64(fd, st) != 0) { e = (unsigned)*__error(); close(fd); } else { lean_object* b = lean_alloc_sarray(1, 0, #3); long r = pread(fd, lean_sarray_cptr(b), #3, (long long)#2); if (r < 0) { e = (unsigned)*__error(); lean_dec(b); } close(fd); if (r >= 0) { lean_sarray_set_size(b, (size_t)r); unsigned dev; __builtin_memcpy(&dev, st, 4); lean_object* p3 = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p3, 0, lean_box_uint64(st[12])); lean_ctor_set(p3, 1, b); lean_object* p2 = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p2, 0, lean_box_uint64(st[1])); lean_ctor_set(p2, 1, p3); lean_object* p1 = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p1, 0, lean_box_uint32(dev)); lean_ctor_set(p1, 1, p2); res = lean_alloc_ctor(1, 1, 0); lean_ctor_set(res, 0, p1); } } if (res == 0) { res = lean_alloc_ctor(0, 1, 0); lean_ctor_set(res, 0, lean_box_uint32(e)); } lean_io_result_mk_ok(res); })"]
private opaque readFileAtRaw (path : @& String) (offset : UInt64) (n : USize) :
    IO (Except UInt32 (UInt32 × UInt64 × UInt64 × ByteArray))

/-- Opens `path` once (no child inherits the descriptor), `fstat`s that descriptor
for the file's device, inode and size, `pread`s at most `n` bytes from `offset` on
it and closes it, so all four are of the one file the open found, even when the
path is renamed over or the file truncated meanwhile. Bytes past the end are none;
the size is the one `fstat` gave just before the read, so a file that grows or
shrinks in between gives more or fewer bytes than it implies. Else the errno of the
open, `fstat` or `pread`: `noSuchFile` when nothing is at `path`, EISDIR (21) for a
directory. -/
def readFileAt (path : System.FilePath) (offset : UInt64) (n : USize) :
    IO (Except UInt32 FileAt) := do
  return (← readFileAtRaw path.toString offset n).map fun (dev, ino, size, bytes) =>
    { dev, ino, size, bytes }

/-- What the pipe at `fd` holds now, and no more: it never waits for a writer.
It asks FIONREAD, which on macOS says 0 for a pty's master: for pipes only. -/
@[extern c inline "({ extern int ioctl(int, unsigned long, ...); extern long read(int, void*, unsigned long); extern int* __error(void); int n = 0; if (ioctl((int)#1, 0x4004667fUL, &n) != 0 || n < 0) n = 0; lean_object* b = lean_alloc_sarray(1, 0, (size_t)n); long got = 0; while (got < n) { long r = read((int)#1, lean_sarray_cptr(b) + got, (unsigned long)(n - got)); if (r > 0) got += r; else if (r < 0 && *__error() == 4) continue; else break; } lean_sarray_set_size(b, (size_t)got); lean_io_result_mk_ok(b); })"]
opaque drainNow (fd : UInt32) : IO ByteArray

/-- The descriptor under a Lean handle, a C `FILE*`. Reading it skips the handle's
buffer, so nothing may read through the handle as well. The descriptor is the
handle's: it is closed when the handle's last reference goes, so keep the handle. -/
@[extern c inline "({ extern int fileno(void*); lean_io_result_mk_ok(lean_box_uint32((unsigned)fileno(lean_get_external_data(#1)))); })"]
opaque handleFd (h : @& IO.FS.Handle) : IO UInt32

@[extern c inline "({ extern int isatty(int); lean_io_result_mk_ok(lean_box(isatty((int)#1) == 1)); })"]
opaque isatty (fd : UInt32) : IO Bool

/-- What an errno means, as libc says it. -/
@[extern c inline "({ extern char* strerror(int); lean_io_result_mk_ok(lean_mk_string(strerror((int)#1))); })"]
opaque strerror (errno : UInt32) : IO String

/-- Sets the access and modification times of the file at `path` to `ms`
milliseconds since the epoch (`utimes`; macOS's `struct timeval` is a `long` and an
`int`): 0, or the errno. -/
@[extern c inline "({ extern int utimes(const char*, const void*); extern int* __error(void); uint64_t ms = #2; struct { long s; int us; } v[2] = {{(long)(ms / 1000), (int)(ms % 1000) * 1000}, {(long)(ms / 1000), (int)(ms % 1000) * 1000}}; lean_io_result_mk_ok(lean_box_uint32(utimes(lean_string_cstr(#1), v) == 0 ? 0u : (unsigned)*__error())); })"]
opaque setTimes (path : @& String) (ms : UInt64) : IO UInt32

end Posix
