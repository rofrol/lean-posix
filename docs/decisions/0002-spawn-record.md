# How a spawned child publishes its own identity before its program runs

Status: settled with the models on 2026-11-14 in item qgxw6v, as the item
asked (consult rounds 20261114-191425-be0f and 20261114-191739-3362, sol and
argon, both accepting option B as written below).

## Context

rr2's item mjqrkj needs every child rr2 spawns (the agent, an audit round, a
resumed agent, each in a session of its own) to be recorded durably, with its
start time against pid reuse, so that the next rr2 ends what a SIGKILLed rr2
left. The owner decided so on 2026-11-09. A record the parent writes after
the spawn leaves a window in which the child runs unrecorded. Since item
53zc6j, `trySpawn` starts children with `posix_spawn`, so no code of the
caller's runs in the child before its exec, and the child cannot write the
record itself.

## Decision

Option B: `trySpawn ... (record := some fd)` starts the child through the
helper `lean-posix-ctty` (`helper/ctty.c`, protocol version 2), which already
exists for `ctty`. After the session (`setsid`) and the terminal (`ctty`), the
helper writes `PID SID START\n` to `fd` (its pid, which the program keeps; its
session; its start in microseconds as `processStart` gives it), `fsync`s and
closes its copy, and only then executes the program. A failure there runs no
program and fails the spawn at the stage `record`. `fd` is inherited by the
helper only (`posix_spawn_file_actions_addinherit_np`), never by the program.

The same descriptor is the publication barrier: the caller takes an exclusive
`flock` on the record file (`lockFile`) before the spawn and passes that
descriptor. The helper shares the open file description, and with it the
lock, until it closes its copy after the `fsync`. A recovering process
(another rr2) that opens the file itself and takes the lock once the caller
is gone finds the complete line when the program ran; when none ran it finds
nothing or, after a write that failed or was killed part-way, the start of a
line without its newline, which is no record (only a line that ends in its
newline is one). A helper scheduled late cannot publish after the recovery
read the file. No one
calls `LOCK_UN` on it, which would release the shared lock early. The file,
its name, the intent it stands for and the reconciliation are rr2's: the
library owns one line's format.

Durability: `fsync`, not `F_FULLFSYNC`: the line survives the caller's and the
child's crash and an OS crash short of a loss of the disk's own cache. The
file's directory entry is the caller's to make durable.

## Alternatives

- A. `POSIX_SPAWN_START_SUSPENDED`, the parent records, then SIGCONT (argon's
  final recommendation in the first round). Rejected by sol and, in the second
  round, by argon: a SIGKILL of the parent between the spawn and the record
  leaves a stopped, unrecorded process that only heuristics find; with `ctty`
  the helper has not made the session yet and `trySpawn` would wait on a
  helper that never runs.
- C. The consumer's own executable as the trampoline: needs the same barrier
  and its own result-pipe protocol, or the spawn no longer says whether the
  program's exec failed.
- D. A token in the child's environment, found later through
  `KERN_PROCARGS2`: not durable, and children may drop it.

## Consequences

- Every spawn with `record` needs the helper next to `IO.appPath`, as a
  `ctty` spawn does; without it the spawn fails at `ctty helper`.
- The helper's protocol is version 2 (`--lean-posix-ctty-v2`, greeting
  `lpctty2`): a library and a helper of different versions fail at
  `ctty helper` with EPROTONOSUPPORT, so a consumer installs the helper built
  from the same pin (`docs/decisions/0001-ctty-helper.md`).
- A record whose exec then fails names a process that ran nothing and is
  gone; the caller's reconciliation sees it gone.
- Not tested here: the barrier against a caller killed in the middle of the
  spawn, which needs a hook between the helper's start and its record. Its
  two parts are: a kept `flock` is held by the child's copy until it closes
  it (`kept` in `Tests/Main.lean`), and the helper closes its copy before the
  program runs (`records`).
