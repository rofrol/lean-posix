termCtl's signal handler is called through a cast function pointer type

Seen in oukmiz (consult round 20261109-170231-3f70, sol and argon): op 1001 installs `lean_posix_term_ops`, a `uint32_t (*)(uint32_t)` compiled from a Lean def, cast to `void (*)(int)`. Calling through an incompatible function pointer type is undefined in C (C11 6.3.2.3p8); it works with the macOS arm64 and x86_64 calling conventions, but would trap under `-fsanitize=function` or arm64e pointer authentication. The repository allows C only inside `@[extern c inline]` expressions, and a Lean function cannot return `void`, so a true `void handler(int)` cannot be written today (the previous handler, `lean_posix_term_ctl`, had the same cast). Decide whether to accept this, documented in `Posix/Term.lean`, or to allow a small C file (or another mechanism) for the handler.

Options: accept it as documented | allow a C handler outside an inline expression
