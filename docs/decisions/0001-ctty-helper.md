# How the ctty helper of `trySpawn` is built, shipped and found

Status: decided by the owner on 2026-11-14: option A (item quboep). The
models disagreed (sol A, argon D); the owner chose A on the coordinating
session's recommendation. Item 53zc6j implements it.

## Context

Item 53zc6j moves `trySpawn` (`Posix/Spawn.lean`) from `fork` to
`posix_spawn`, because a diagnostic run (item tuvst2, proposal 2kfkur)
measured children killed by SIGKILL inside `fork` itself. The run counted 22
of 4000 spawns, all while other threads were making their first calls into
libnotify. The owner approved this on 2026-11-09, "the helper executable
included".

`trySpawn ... (ctty := true)` promises that the child's stdin becomes its
controlling terminal (`TIOCSCTTY`), so it gets SIGWINCH when the terminal's
size is set. macOS's `posix_spawn` has `POSIX_SPAWN_SETSID` but no attribute
for a controlling terminal. The SDK's `<spawn.h>` and `<sys/spawn.h>` list
none, and a private `_np` SPI is not used. So a `ctty` spawn needs a process
that does `setsid`, `ioctl(0, TIOCSCTTY, 0)` and `execve`: a helper. An
`extern_lib` links C into consumers but ships no executable. This record
covers how that helper is built and shipped, and how consumers find it at run
time.

Consumers: rr, rr2, lean-tui (and lean-markdown through it) and ffprogress.
Only rr uses `ctty` (`Screens/Main.lean`, `Screens/Tui.lean`), and lean-posix's
own `tests` use it too. rr2 builds its installs in a staging tree that it
deletes afterwards. It moves only the executables it names
(`exes := ["rr2", "rr2-view"]`) into the immutable `<root>/<sha>/bin`. rr runs
its executables from its checkout's `.lake/build/bin`. Each executable is
about 108 MB.

### Evidence (prototypes outside the repository, macOS 27.2 arm64, Lean nightly-2026-10-25)

- `posix_spawn` with `POSIX_SPAWN_SETSID` does not give the child a
  controlling terminal. This holds whether the pty slave is handed over by
  `adddup2` or opened by path with `addopen` (no `O_NOCTTY`). A C probe child
  saw `tcgetsid(0) == -1` and `/dev/tty` would not open, and `TIOCSWINSZ`
  delivered no SIGWINCH. Running `/bin/sh -c probe` instead does give the
  terminal: bash 3.2, as a session leader, takes it itself. lean-posix cannot
  rely on that for an arbitrary program. So a helper is needed.
- A C constructor in an `extern_lib`, built the way `leanposixc` is, runs in
  a Lean executable before Lean's `main`. The executable then serves as its
  own helper: spawned by its `proc_pidpath` path with a marker argument, it
  does setsid, TIOCSCTTY and execve, and the target gets the terminal and
  SIGWINCH. Spawning the executable through `/dev/fd/N` fails with EACCES.
- The executable is spawned with `POSIX_SPAWN_START_SUSPENDED`. The man page
  says the child is "created as if it immediately received a SIGSTOP signal
  ... before it begins execution in user space". Before resuming the child,
  the parent compares two `(dev, ino)` pairs. The first is from the region of
  its own process that holds the constructor's code
  (`proc_pidinfo PROC_PIDREGIONPATHINFO`). The second is from the child's
  mapped regions. The parent then sends SIGCONT on a match and SIGKILL
  otherwise. A different program at the spawned path (a sentinel that
  creates a file when it runs) was killed before it ran: the file was not
  created, though the same sentinel run directly creates it.
- An executable overwritten in place (`cp` onto the running file) keeps its
  inode, so the check matches. The child then ended by SIGKILL on its own
  after SIGCONT, and the sentinel's bytes did not run. The kernel's reason
  was not found in the system log. Code-signature validation would explain
  it, but that is not confirmed.

## Decision

Option A: a separate small C helper executable, built by lean-posix as a
Lake target with the same toolchain clang and SDK setup as `leanposixc`,
speaking a versioned protocol and refusing any other version. A consumer
that spawns with `ctty` builds it and installs it next to its own
executables; the library finds it next to `IO.appPath` by default, so
`trySpawn`'s signature need not change (53zc6j settles the exact lookup and
its error). Option B is rejected on the evidence above; option C was
recommended by neither model.

Why A over D (the owner, 2026-11-14, on the coordinating session's
reasoning): only rr uses `ctty` today, so A's build and install work falls on
one consumer, not on all four; D's failure after an in-place rebuild hits
exactly rr, which runs from its checkout's `.lake/build/bin` and is rebuilt in
place; and D puts a constructor into every consumer executable and adds
suspended-process inspection, orphan and SIGHUP handling and an unmeasured
spawn-to-exec time, where A's helper is setsid, TIOCSCTTY and execve. A
missing helper is found at the first `ctty` spawn, with a clear failure.

## Alternatives

### A. A separate helper executable that consumers build, ship and point to

Sol recommends this option (consult rounds 20261114-183728-d76a and
20261114-183940-9f5d). It is a small C executable target in lean-posix,
compiled with the same toolchain clang and SDK setup as `leanposixc`. Each
consumer builds it, installs it next to its own executables (for rr2, in the
immutable `<sha>/bin`, added to `exes`), and tells the library where it is.
That could be a parameter, an environment variable, or "next to
`IO.appPath`", which still has to be settled. The helper and the library
speak a versioned protocol, and the helper refuses any other version.

- Sol's decisive reason: "lifecycle and initialization complexity". With A
  the operation runs in a tiny helper that never starts a consumer's process
  image, and there is no suspended-process inspection or orphan handling.
- Consequences: every consumer that may spawn with `ctty` changes its build,
  its install and its tests. A missing or stale helper is found only at the
  first `ctty` spawn. The helper and the library ship as separate files, so
  their versions can skew. If the path becomes a parameter, the signature
  changes too.

### D. The consumer's own executable is the helper

Argon recommends this option, in the same rounds. `c/spawn.c` holds a
constructor that checks whether `argv[1]` is a versioned marker
(`--lean-posix-ctty-v1`). If it is, the constructor does setsid, TIOCSCTTY
and `execve` along the candidate paths, writes `(stage, errno)` to the
close-on-exec report pipe on failure, and `_exit`s, never entering `main`. A
`ctty` spawn runs `posix_spawn` of `proc_pidpath(getpid())` with
`POSIX_SPAWN_START_SUSPENDED`. Before SIGCONT it checks that the child maps
the vnode that holds the constructor (evidence above). On a mismatch, or when
the inspection fails or exhausts its bound, it kills and reaps the child and
returns a `SpawnFailure` with a new stage.

- Argon's decisive reason: a low-level library should not push build,
  packaging, path-discovery and deployment work onto every consumer for one
  missing `posix_spawn` attribute. D fails closed on a replaced executable
  and on an interpreter host (a `lean` process that loads the library as a
  shared library).
- Consequences: consumers build, ship and pass nothing, and no signature
  changes. Every consumer executable carries a constructor that compares
  `argv[1]` once at startup. Suppose rr is rebuilt in place while an old rr
  keeps running: that old process's `ctty` spawns then fail with the new
  stage until it restarts. rr2's immutable builds are not affected.
- Open points for 53zc6j if D is chosen:
  - Force SIGHUP to `SIG_DFL` and unblock it in the helper's spawn
    attributes. Then a suspended child whose parent dies before SIGCONT,
    and whose process group the kernel resumes with SIGHUP and SIGCONT,
    dies instead of running unchecked (argon). A suspended child whose
    process group is not orphaned stays stopped and leaks, along with its
    descriptors (both models).
  - dyld and any initializers ordered before the constructor run in the
    helper with the target's environment (both models).
  - EOF on the report pipe without a record does not prove the exec
    happened: a child that dies first looks the same, as it does today
    (sol).
  - The time a 108 MB executable takes from spawn to the constructor's
    `execve` has not been measured.

### B. The helper's path resolved from the library's package directory

Rejected. The path would point into the consumer's build tree
(`.lake/packages/lean-posix/.lake/build/...`). rr2 builds its installs in a
staging tree that it deletes, so every installed rr2 would hold a dangling
path. A removed worktree or a `lake clean` breaks installed binaries the
same way.

### C. The helper's bytes embedded in `leanposixc`, written out at run time

Recommended by neither model. It needs a writable private directory and disk
space at run time. The written file can be removed by the system's
temporary-file cleaner, and rewriting it at that point is a retry. It adds a
build step that turns an executable into C. Whether the written file's
ad-hoc signature is accepted is unverified.

## Consequences

Both A and D add a `SpawnFailure` stage for the helper, and `stage` is a
`String`. That is a public contract change, which the owner approves with
53zc6j. The two options differ in what consumers must do:

- A: rr, rr2, lean-tui and ffprogress each build and install the helper and
  pass its path, each moving its pin through its own queue.
- D: nothing, beyond the restart after an in-place rebuild described under D.
