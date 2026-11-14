/-!
# File descriptors

A file descriptor is a `UInt32`; a negative result of libc arrives as a large one.
The C is `c/fd.c`, which takes `struct stat`, `struct timeval` and every constant
from the SDK's headers.
-/

namespace Posix

/-- Makes `to` a copy of `from`. -/
@[extern "lean_posix_dup2"]
opaque dup2 (from_ to : UInt32) : IO Unit

/-- A copy of `fd` that no child inherits. -/
@[extern "lean_posix_dup_private"]
opaque dupPrivate (fd : UInt32) : IO UInt32

@[extern "lean_posix_close"]
opaque close (fd : UInt32) : IO Unit

/-- At most `n` bytes, past any EINTR; none at the end of the input, or on an error
(the one a closed terminal gives too). -/
@[extern "lean_posix_read"]
opaque read (fd : UInt32) (n : USize) : IO ByteArray

/-- At most `n` bytes of `path` from `offset`; none past its end or with no file.
The file is opened and closed again, so nothing stays open between reads. -/
@[extern "lean_posix_read_at"]
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

@[extern "lean_posix_read_file_at_raw"]
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

@[extern "lean_posix_append_line"]
private opaque appendLineRaw (path : @& String) (bytes : @& ByteArray) : IO (Except UInt32 Bool)

/-- Appends `bytes` to the regular file at `path` so that they start a line of
their own, all on one descriptor: opens it once (read and append, made with mode
0666 less the umask when missing, no child inherits it), `fstat`s it, `pread`s its
last byte when it is not empty, and writes a newline first when that byte is not
one (the file ended in a cut line), then `bytes`, as one buffer, past any EINTR
and short write; then closes it. The check and the write are of the one file the
open found, even when the path is renamed over meanwhile; whoever replaces the
file holds the caller's lock while doing so for the append to reach the new one.
The caller ends `bytes` with its own newline. `.ok true` when a newline was put
before `bytes`, `.ok false` when none was, and for empty `bytes`, which open
nothing. Else the errno of the open, `fstat`, `pread`, write or close: EFTYPE (79) for
what is not a regular file (EISDIR, 21, for a directory, from the open); EIO when
the file shrank between the `fstat` and the `pread`. A write that fails part-way
leaves what it wrote, a cut line that the next `appendLine` ends with its newline.
Several writers' appends are whole lines only under a lock they share: `O_APPEND`
makes each write land at the end, but a short write's rest is another write. -/
def appendLine (path : System.FilePath) (bytes : ByteArray) : IO (Except UInt32 Bool) :=
  appendLineRaw path.toString bytes

/-- What the pipe at `fd` holds now, and no more: it never waits for a writer.
It asks FIONREAD, which on macOS says 0 for a pty's master: for pipes only. -/
@[extern "lean_posix_drain_now"]
opaque drainNow (fd : UInt32) : IO ByteArray

/-- The descriptor under a Lean handle, a C `FILE*`. Reading it skips the handle's
buffer, so nothing may read through the handle as well. The descriptor is the
handle's: it is closed when the handle's last reference goes, so keep the handle. -/
@[extern "lean_posix_handle_fd"]
opaque handleFd (h : @& IO.FS.Handle) : IO UInt32

@[extern "lean_posix_isatty"]
opaque isatty (fd : UInt32) : IO Bool

/-- What an errno means, as libc says it. -/
@[extern "lean_posix_strerror"]
opaque strerror (errno : UInt32) : IO String

/-- Sets the access and modification times of the file at `path` to `ms`
milliseconds since the epoch (`utimes`): 0, or the errno. -/
@[extern "lean_posix_set_times"]
opaque setTimes (path : @& String) (ms : UInt64) : IO UInt32

end Posix
