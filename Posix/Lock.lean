/-!
# Locks and links

Exclusive `flock`s, and a hard link that fails on a taken name, so writers that
race never share a file, and a lock handed to the next program this process
executes. The C is `c/lock.c`, which takes `struct stat` and every constant from
the SDK's headers.
-/

namespace Posix

/-- Opens `path` (created if missing, mode 0644), which no child inherits, and
locks it: the descriptor, or the errno with the high bit set. Blocking (`block`
nonzero), it waits past EINTR until no other holder is left. -/
@[extern "lean_posix_lock_raw"]
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

@[extern "lean_posix_lock_handed_raw"]
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
@[extern "lean_posix_unlock"]
opaque unlock (fd : UInt32) : IO Unit

/-- An exclusive `flock` on the directory `path`, waited for past EINTR (a caught
signal whose handler lacks SA_RESTART) until no other holder is left, and held
until the process ends; no child inherits it. -1 (as a `UInt32`) when it cannot be
had. -/
@[extern "lean_posix_lock_dir"]
opaque lockDir (path : @& String) : IO UInt32

/-- A hard link `to` of `from`: 0, or the errno, EEXIST (17) when `to` is taken. -/
@[extern "lean_posix_link"]
opaque link (from_ to : @& String) : IO UInt32

end Posix
