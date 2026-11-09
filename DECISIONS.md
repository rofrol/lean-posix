# Decisions

The owner's standing rulings for this repository (AGENTS.md, Rule 5).

## History and pin tags

- 2026-11-09, scope: this repository's history and the `pin/*` tags here that
  rr2 pins. lean-posix is the owner's own repository, so its history may be
  rewritten and rr2's `pin/*` tags here moved to the rewritten commits, an
  exception to AGENTS.md Rule 6 ("`pin/*` tags are never moved or deleted").
  rr2 then rewrites its own history too, so that its old commits pin the new
  lean-posix commits rather than keeping the old ones fetchable. The owner:
  "move them; lean-posix is my repo", and the old rr2 commits "are to be
  rewritten". Done once, in rr2's item j4kuy5. The ruling covers rr2's tags
  only: rr's `pin/*` tags here are not covered, nor are other consumers'
  (lean-tui), and Rule 6 holds for them.

## C files

- 2026-11-09, scope: where this library's C lives and what building it needs.
  The owner lifted the rule that lean-posix's C lives only in
  `@[extern c inline]` expressions and asked where C outside them is better.
  Consult round 20261109-174150-a3d1 answered: where compiler-checked system
  declarations pay, since every struct layout and constant in an expression is
  written by hand and two such mistakes were found that day. Approved by the
  owner: `termCtl`'s C moves to `c/term.c`, its signal handler a true
  `void handler(int)` instead of `lean_posix_term_ops` cast to one (the
  accepted debt of commit f2abbae), and `c/abi.c` asserts the expressions'
  numbers against the SDK's headers; Odin was rejected as a compiler every
  consumer would need. Decided by the owner the same day: the macOS SDK
  (Xcode or the Command Line Tools) is a build requirement of lean-posix and
  of every consumer (rr, rr2, lean-tui, ffprogress), and `README.md` says so.
  The other bindings stay inline expressions; moving one into `c/` is its own
  change.
