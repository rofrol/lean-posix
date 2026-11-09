/-!
# A full-screen terminal in raw mode, restored on every exit that can be caught

`termCtl` holds the terminal as found and the signal handlers in one place, so the
terminal is put back however the program ends: on its own, on an error, and on
every signal that ends a process and can be caught. A program can also hand the
terminal as found to the next build of itself that it executes in the same process
(`Posix.execResume`), through the environment variable `LEAN_POSIX_TERMIOS`.
-/

namespace Posix

/-- The terminal at stdin and stdout, by `op`:

- 0 enters the full screen (the alternate screen, no cursor, no autowrap, cleared)
  in raw mode with SGR mouse reports; 1 when stdin is no terminal;
- 1005 enters it the same way but does not turn mouse reports on, so the
  terminal's own text selection keeps working (not 2, which the last case reads as
  SIGINT);
- 1006 enters it the same way with SGR any-motion mouse reports (`?1003h`): the
  pointer moving is reported also with no button held, besides clicks;
- 1000 leaves it, turning both kinds of mouse reports off and putting the pointer
  shape back to the terminal's default whichever way it was entered (a build
  started by `execResume` does not know how its predecessor entered it), and puts
  the terminal back as found;
- 1001 installs a handler of every signal that ends a process and
  can be caught, and ignores SIGTSTP (so `kill -TSTP` cannot stop the program with
  the terminal raw); an ignored signal survives exec, so a child started after it
  inherits SIGTSTP ignored unless it calls `Posix.defaultSignals` first;
- 1003 puts the terminal as found into the environment, as `LEAN_POSIX_TERMIOS` in
  hex, for the next build `execResume` starts (1 when the full screen was not
  entered), and 1004 takes it out again when that build did not start;
- 1002, in that next build, takes the terminal as found from there and holds it as
  its own, the terminal being in the full screen already, so nothing is written and
  nothing cleared (1 when it is not there or not whole);
- any other `op` is a signal arriving: leave, then die of it, as the handler has
  reset itself. A signal arriving while the terminal is being restored restores it
  again before it ends the process.

Leaving resets the pointer shape a program may have set with OSC 22 by writing
`ESC ] 22 ; ESC \`, before leaving the alternate screen, whose shape stack is the
one a full-screen program sets. kitty's pointer-shapes protocol
(https://sw.kovidgoyal.net/kitty/pointer-shapes/) gives that string as its
example "Reset the pointer to default", and says "The terminal must maintain
separate shape stacks for the _main_ and _alternate_ screens".

The C is `lean_posix_term_ctl` in `c/term.c`, which keeps the terminal as found
and whether the full screen is entered in two statics, so the terminal state is
process-global. The handler op 1001 installs is a `void handler(int)` there,
with SA_RESETHAND, which resets it as the signal arrives, and SA_NODEFER, which
leaves the signal unblocked while it runs, so `raise` ends the process at once
with the default action. It is plain C that calls nothing of Lean's, only
`write`, `tcsetattr` and `raise`, which are async-signal-safe; `raise` returns
only when the signal is ignored or blocked by then (a direct call with a
signal's number, or another thread changing the signal), and errno is then put
back. -/
@[extern "lean_posix_term_ctl"]
opaque termCtl (op : UInt32) : IO UInt32

/-- Enters the full screen in raw mode, with SGR mouse reports when `mouse` (op 0
of `termCtl`) or without them (op 1005), and with any-motion reports, the pointer
moving with no button held, when `motion` (op 1006, which implies `mouse`); 1 when
stdin is no terminal. Leave it with `termCtl 1000`. -/
def termEnter (mouse : Bool := true) (motion : Bool := false) : IO UInt32 :=
  termCtl (if motion then 1006 else if mouse then 0 else 1005)

end Posix
