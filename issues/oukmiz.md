termCtl's signal path allocates after raise: make the handler async-signal-safe

Seen in lean-posix's gmh7qf diff review (consult round 20261109-044401-6cd1, sol)
and checked against the toolchain: `termCtl` is the signal handler op 1001
installs (`Posix/Term.lean:17`), and its C expression ends with
`lean_io_result_mk_ok(lean_box_uint32(r))` on every path, also after
`raise((int)op)` on a signal. In nightly-2026-10-25's `lean.h:3246-3249`,
`lean_io_result_mk_ok` calls `lean_alloc_ctor(0, 1, 0)`, which is not
async-signal-safe. With SA_RESETHAND the re-raised signal is normally held
until the handler returns (it is blocked while the handler runs, unless the
system treats SA_RESETHAND as SA_NODEFER), so the handler reaches the
allocation first. A signal arriving inside Lean's allocator could then
corrupt or deadlock it before the process dies. The terminal is already
restored by then, so what is lost is a clean death, not the restored screen.

Possible direction: install a plain C handler (a static function in the same
expression) that writes the leave string, restores termios and re-raises,
and never returns into Lean. That function would also have to reach the
statics `saved` and `on`, so the handler and the statics would have to be
restructured. Needs a test that a signal still leaves the screen.
