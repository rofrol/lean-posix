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
