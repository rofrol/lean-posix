lean-posix: three bindings rr2 needs, in one pin: a session kill, a one-descriptor append, and a spawn that hands chosen descriptors to the child only

Asked by rr2's queue on 2026-11-14 for its approved items mjqrkj, 5oxuhv and c47ldg. The owner decided on 2026-11-09 (rr2's mjqrkj) that one lean-posix bump, through this repository's own queue and rules, adds the bindings rr2 needs; c47ldg's step 3 (approved design) needs a third. Placed after 53zc6j by consult rounds of 2026-11-14 (sol, and argon over this repository): written once against the C files and posix_spawn, not first in the fork-based Spawn that atn2r3 to 53zc6j replace.

- Session kill (rr2 mjqrkj): end every process whose session is a given one (macOS has no `pkill -s`: the pids from `proc_listallpids` whose `getsid` matches, signalled until none is left, bounded, reporting what is left); tested against concurrent exits and forks, pid reuse, permission failures and an exited session leader. Also what mjqrkj needs for a child to publish its own identity (pid, session, start time) durably before exec, if posix_spawn leaves no other way (to settle in this item's design round).
- One-descriptor append (rr2 5oxuhv): open for append, fstat, pread of the last byte, write, on one descriptor.
- Inherited descriptors (rr2 c47ldg step 3): a spawn option naming descriptors the child inherits (with posix_spawn and POSIX_SPAWN_CLOEXEC_DEFAULT, `posix_spawn_file_actions_addinherit_np`), the parent's own staying close-on-exec, every temporary duplicate closed on each failure path.

Three commits, each with its tests; then the pin tag `pin/<sha12>` pushed and verified (`git ls-remote`) before rr2 pins it.
