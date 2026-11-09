termCtl op 1001 ignores SIGTSTP (18), while its doc says SIGCONT

Seen in oukmiz (consult round 20261109-170231-3f70, sol): `Posix/Term.lean`'s op 1001 calls `signal(18, SIG_IGN)`, and the doc comment of `termCtl` says it "ignores SIGCONT". On macOS (`<sys/signal.h>`: SIGTSTP 18, SIGCONT 19) signal 18 is SIGTSTP. oukmiz only noted the mismatch in `termOpsRaw`'s private comment. Decide which is intended: keep ignoring SIGTSTP (a raw-mode program has no Ctrl-Z anyway, but a `kill -TSTP` would otherwise stop it with the screen in raw mode) and correct the public doc, or change the code to what the doc says. Either changes the documented contract consumers (rr, rr2, lean-tui) read.

Options: correct the doc to SIGTSTP | ignore SIGCONT (19) as documented | ignore both
