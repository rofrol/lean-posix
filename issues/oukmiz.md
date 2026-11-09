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

Merged with ldvclw (consult round 20261109-165501-ee87, sol and argon; decided with the models as the owner delegated on 2026-11-09). ldvclw: the doc comment of `termRaw` names its sigaction flags 0x14 "SA_RESTART | SA_RESETHAND", but on macOS (`<sys/signal.h>`: SA_RESTART 0x2, SA_RESETHAND 0x4, SA_NODEFER 0x10) 0x14 is SA_RESETHAND | SA_NODEFER. Correct the comment to the flags in use; keep the flags (adding SA_RESTART would change what interrupted calls do in consumers). This also corrects the premise above: with SA_NODEFER the re-raised signal is not blocked while the handler runs, so `raise` normally ends the process at once with the default action and the allocation after it is reached only when `raise` returns. Start by establishing which paths the handler can actually take, including the Lean-compiled `lean_posix_term_ctl` wrapper it enters, then make the handler a plain C function that touches no Lean object. Check: `tests term-signal` and `tests term-motion-signal` still pass, also checking that the process ends by the original signal; the handler's code calls no `lean_*` function.
