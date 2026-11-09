termEnter: any-motion mouse reports, and leaving the screen resets them and the pointer shape

For rr2's tkfkgm (rr2-view: the pointer takes a resize shape over the
Times separator), approved by the owner on 2026-11-09: "oraz wskaźnik
myszy ma się zmieniać jak nad separatorem" (and the mouse pointer is to
change when over the separator).

rr2-view needs to know when the pointer is over a row without a button
held, so it needs any-motion reports (`?1003h`, with SGR `?1006h`).
lean-posix owns the terminal modes (`termCtl` leaves the screen also on a
signal), so:
- `termEnter` gains a way to ask for any-motion reports (beside the
  existing click reports); the default stays as it is for current callers.
- The leave string (normal exit and the signal path) resets `?1003l` when
  it was asked for, and resets the pointer shape to the default with OSC 22
  (`ESC ] 22 ; ST`, or the default the OSC 22 documentation names; link
  and quote the passage, e.g. kitty's pointer-shapes protocol, next to the
  code), so a shape a program set never outlives it.
- A pty test: entering with any-motion writes `?1003h`; leaving, also on a
  signal, writes `?1003l` and the pointer reset.
No push: the rr2 item that adopts this commit pushes its `pin/<sha12>` tag.
