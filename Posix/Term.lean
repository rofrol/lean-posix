/-!
# A full-screen terminal in raw mode, restored on every exit that can be caught

`termCtl` holds the terminal as found and the signal handlers in one place, so the
terminal is put back however the program ends: on its own, on an error, and on
every signal that ends a process and can be caught. A program can also hand the
terminal as found to the next build of itself that it executes in the same process
(`Posix.execResume`), through the environment variable `LEAN_POSIX_TERMIOS`.
-/

namespace Posix

/-- The terminal's state and the signal handlers, as its two statics hold the
terminal as found: expanded only in `termCtl`, which is why it is private. The
numbers are macOS's: TCSANOW 0, SA_RESTART | SA_RESETHAND 0x14, SIGCONT 18 and
SIG_IGN 1, and the signals that end a process and can be caught. -/
@[extern c inline "({ extern int tcgetattr(int, void*); extern int tcsetattr(int, int, const void*); extern void cfmakeraw(void*); extern long write(int, const void*, unsigned long); extern int sigaction(int, const void*, void*); extern void (*signal(int, void (*)(int)))(int); extern int raise(int); extern lean_object* lean_posix_term_ctl(uint32_t); static unsigned long saved[16]; static volatile int on = 0; static const char enter[] = \"\\x1b[?1049h\\x1b[?25l\\x1b[?7l\\x1b[2J\"; static const char mouse[] = \"\\x1b[?1000h\\x1b[?1006h\"; static const char leave[] = \"\\x1b[?1006l\\x1b[?1000l\\x1b[0m\\x1b[?7h\\x1b[?25h\\x1b[?1049l\"; uint32_t op = #1; uint32_t r = 0; if (op == 0 || op == 1005) { if (tcgetattr(0, saved) != 0) r = 1; else { unsigned long t[16]; for (int i = 0; i < 16; i++) t[i] = saved[i]; cfmakeraw(t); on = 1; tcsetattr(0, 0, t); write(1, enter, sizeof enter - 1); if (op == 0) write(1, mouse, sizeof mouse - 1); } } else if (op == 1002) { extern char* getenv(const char*); extern int unsetenv(const char*); const char* h = getenv(\"LEAN_POSIX_TERMIOS\"); unsigned char* p = (unsigned char*)saved; int n = 0, bad = !h; r = 1; while (!bad && n < (int)sizeof saved) { int d[2]; for (int k = 0; k < 2; k++) { int c = h[2 * n + k]; d[k] = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1; if (d[k] < 0) bad = 1; } if (!bad) p[n++] = (unsigned char)(d[0] * 16 + d[1]); } if (!bad && !h[2 * n]) { on = 1; r = 0; } unsetenv(\"LEAN_POSIX_TERMIOS\"); } else if (op == 1003) { extern int setenv(const char*, const char*, int); static const char hex[] = \"0123456789abcdef\"; char h[sizeof saved * 2 + 1]; const unsigned char* p = (const unsigned char*)saved; for (int i = 0; i < (int)sizeof saved; i++) { h[2 * i] = hex[p[i] >> 4]; h[2 * i + 1] = hex[p[i] & 15]; } h[sizeof h - 1] = 0; r = on && setenv(\"LEAN_POSIX_TERMIOS\", h, 1) == 0 ? 0 : 1; } else if (op == 1004) { extern int unsetenv(const char*); unsetenv(\"LEAN_POSIX_TERMIOS\"); } else if (op == 1001) { struct { void (*h)(int); unsigned m; int f; } a = { (void (*)(int))lean_posix_term_ctl, 0, 0x14 }; int s[] = {1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 24, 25, 26, 27, 30, 31}; for (int i = 0; i < 20; i++) sigaction(s[i], &a, 0); signal(18, (void (*)(int))1); } else { if (on) { write(1, leave, sizeof leave - 1); tcsetattr(0, 0, saved); on = 0; } if (op != 1000) raise((int)op); } lean_io_result_mk_ok(lean_box_uint32(r)); })"]
private opaque termRaw (op : UInt32) : IO UInt32

/-- The terminal at stdin and stdout, by `op`:

- 0 enters the full screen (the alternate screen, no cursor, no autowrap, cleared)
  in raw mode with SGR mouse reports; 1 when stdin is no terminal;
- 1005 enters it the same way but does not turn mouse reports on, so the
  terminal's own text selection keeps working (not 2, which the last case reads as
  SIGINT);
- 1000 leaves it, turning mouse reports off whichever way it was entered, and puts
  the terminal back as found;
- 1001 installs `termCtl` as the handler of every signal that ends a process and
  can be caught, and ignores SIGCONT;
- 1003 puts the terminal as found into the environment, as `LEAN_POSIX_TERMIOS` in
  hex, for the next build `execResume` starts (1 when the full screen was not
  entered), and 1004 takes it out again when that build did not start;
- 1002, in that next build, takes the terminal as found from there and holds it as
  its own, the terminal being in the full screen already, so nothing is written and
  nothing cleared (1 when it is not there or not whole);
- any other `op` is a signal arriving: leave, then die of it, as the handler has
  reset itself. A signal arriving while the terminal is being restored restores it
  again before it ends the process.

The signal handler: its C name is what op 1001 installs. -/
@[noinline, export lean_posix_term_ctl]
def termCtl (op : UInt32) : IO UInt32 := termRaw op

/-- Enters the full screen in raw mode, with SGR mouse reports when `mouse` (op 0
of `termCtl`) or without them (op 1005); 1 when stdin is no terminal. Leave it with
`termCtl 1000`. -/
def termEnter (mouse : Bool := true) : IO UInt32 := termCtl (if mouse then 0 else 1005)

end Posix
