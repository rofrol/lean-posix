lean-posix: confirm the two assumptions behind the lockDir EINTR test

Found while doing nhg7tl (commit "Make lockDir wait past EINTR as lockFile does"). The test `lockDirSignal` (`Tests/Main.lean`) rests on two things it does not prove, as its doc comment says; consult round 20261109-171345-4272 (sol) flagged both:

- Entry into the blocking `flock` is inferred from every thread of the waiter being in state S in `ps -M`; macOS `ps -o wchan` shows "-" for a `flock` waiter, so the wait channel is not observable. A sleep before `flock` would let the signal arrive early, and the unfixed `lockDir` would then pass.
- The holder is released after `pthread_kill` returns, assuming XNU marks the target thread's interruptible wait interrupted before `pthread_kill` returns, as it was seen to do for `kill` (a perl experiment with a single-threaded `flock` waiter). XNU's source (`bsd/kern/kern_sig.c`) was not read to confirm this for the thread-directed path.

Work: read XNU's `kern_sig.c` (`__pthread_kill`, `psignal_internal`, `thread_abort_safely`) and record whether the ordering holds; look for an observable sign of a thread waiting in `flock` (for example `proc_pidinfo` thread info) that would replace the S-state inference. Evidence so far: the unfixed `lockDir` failed the test with "gave up" in 5 runs of 5.

Consult round 20261109-172543-af7f split: sol keeps it as a bounded investigation (if no reliable observation of the flock wait exists, label the test as not deterministic in its doc rather than claim it); argon would close it, asserting XNU marks the thread interrupted before `__pthread_kill` returns, without a cited line. The owner leaned to keeping it (2026-11-09), so it stays: read the XNU source to confirm or refute argon's claim with the lines cited. No delays or resends.
