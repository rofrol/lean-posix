lean-posix: note for 53zc6j: trySpawn's fork kills children before exec in a multithreaded Lean process (tuvst2 result)

A note to add to 53zc6j, from the diagnostic tuvst2 (commit "Diagnose trySpawn's fork while other threads are inside libSystem (tuvst2)").

What was run: `lake exe spawnstress ROUNDS SPAWNS THREADS [KIND,...]` (`Diag/SpawnStress.lean`, a labelled diagnostic stress run, not in `lake test`). Each round is a fresh worker process whose dedicated Lean threads call into libSystem from the start (libnotify `notify_register_check`/`notify_post`/`notify_check`/`notify_cancel`, `getaddrinfo("localhost")`, `getpwuid_r`, libdispatch group of 8 blocks), while its main thread starts children one at a time with today's `Posix.trySpawn`, each `/bin/echo ack` with the ack read back from a pipe, then reaped with `waitOutcome`. macOS 27.2 (26B123), arm64, Lean nightly-2026-10-25, 2026-11-09.

Counts:
- Control, 200 workers x 20 spawns, no other threads: 4000/4000 reached exec and exited 0.
- 200 x 20, 2 threads per kind (all four kinds): 22/4000 children killed by SIGKILL with no ack; every one at a worker's first spawn (index 0). No setup failures, no hangs.
- Per kind alone, 100 x 20 x 2: notify 9, getaddrinfo 11, getpwuid_r 8, dispatch 0 kills of 2000 each. getaddrinfo and getpwuid_r reach libnotify themselves.
- Earlier runs: 2/200 (10 x 20 x 2) and 9/2000 (100 x 20 x 2), all at spawn index 0 to 2.

Did any child die before exec: yes. Every crash report saved (26; osanalyticshelper stopped at its limit of 25, and lost some to name collisions within one second, as its log says for the rest) shows the child's thread at `fork < libSystem_atfork_child < _notify_fork_child < _os_alloc_once < _os_once < _os_once_gate_wait < _os_once_gate_corruption_abort`, "BUG IN CLIENT OF LIBPLATFORM: os_once_t is corrupt", "crashed on child side of fork pre-exec", EXC_BREAKPOINT delivered as SIGKILL. The kill is inside `fork` itself, in libSystem's atfork child handler, before any of trySpawn's child code runs, so no care in that code avoids it. trySpawn reports such a child as started (`.ok pid`): its result pipe ends with no record, as after an exec; the caller only sees the child end by SIGKILL.

Exposure: the window is a process's first use of libnotify (directly, or through getaddrinfo, getpwuid_r and other libinfo calls) on another thread while a fork runs; once initialized, later forks in the same worker did not fail. A consumer whose threads touch those calls near startup (rr2, rr, lean-tui) can lose a child this way. Lean's own `IO.Process.spawn` calls the same libSystem `fork`, so its atfork handlers run there too (not measured). Re-run the same diagnostic after the posix_spawn migration as the before/after check.
