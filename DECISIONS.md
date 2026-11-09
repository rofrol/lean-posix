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
