lean-posix: note for 53zc6j: the ctty helper's packaging waits on the owner's choice in docs/decisions/0001-ctty-helper.md (quboep result)

A note to add to 53zc6j, from the design item quboep (2026-11-14; consult rounds 20261114-183728-d76a and 20261114-183940-9f5d, with sol and argon).

Checked by prototype on macOS 27.2, arm64: `posix_spawn` with `POSIX_SPAWN_SETSID` gives no controlling terminal. This holds whether the pty slave goes in by `adddup2` or by `addopen` of its path, so `ctty` does need the helper. (`/bin/sh` as the child takes the terminal by itself: that is bash 3.2's own behavior, not something lean-posix can rely on.)

How the helper is built, shipped and found is an open question for the owner, between two options; `docs/decisions/0001-ctty-helper.md` gives the evidence and the consequences of each:
- A (sol): a separate small C helper executable, which every consumer that spawns with `ctty` builds, installs next to its own executables and points the library to.
- D (argon): the consumer's own executable is the helper. A constructor in `c/spawn.c` takes over when `argv[1]` is a versioned marker. The executable is spawned with `POSIX_SPAWN_START_SUSPENDED` and resumed only once the child is checked to map the vnode that holds the constructor. Consumers then build, ship and pass nothing.

Option B (a path into the package's build directory) is rejected: rr2's install deletes its staging tree. Option C (the helper's bytes written out at run time) was recommended by neither model.

Under either option, `SpawnFailure` gets a new stage for the helper, a public contract change. This item does not start until the owner has chosen.
