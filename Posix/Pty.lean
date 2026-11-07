/-!
# Terminals: a pty, a controlling terminal, the window size

The numbers are macOS's: F_SETFD 2, FD_CLOEXEC 1, TIOCGWINSZ 0x40087468,
TIOCSWINSZ 0x80087467.
-/

namespace Posix

/-- A raw terminal, so it neither turns \n into \r\n nor echoes: the master, which
no child inherits, and the slave. `cfmakeraw` fills a `struct termios`, which fits
in the buffer. Both are large numbers when no pty can be had. -/
@[extern c inline "({ extern int openpty(int*, int*, char*, void*, void*); extern void cfmakeraw(void*); extern int fcntl(int, int, ...); unsigned long t[32] = {0}; cfmakeraw(t); int m = -1, s = -1; if (openpty(&m, &s, 0, t, 0) == 0) fcntl(m, 2, 1); lean_object* p = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p, 0, lean_box_uint32((unsigned)m)); lean_ctor_set(p, 1, lean_box_uint32((unsigned)s)); lean_io_result_mk_ok(p); })"]
opaque openPty : IO (UInt32 × UInt32)

/-- A new session with `fd`, a terminal, as its controlling terminal and stdio: 0,
or a large number when it failed. For a child before it executes its command. -/
@[extern c inline "({ extern int login_tty(int); lean_io_result_mk_ok(lean_box_uint32((unsigned)login_tty((int)#1))); })"]
opaque loginTty (fd : UInt32) : IO UInt32

/-- The rows and columns of the terminal at stdout, or 24 by 80 when it does not
say. -/
@[extern c inline "({ extern int ioctl(int, unsigned long, ...); unsigned short w[4] = {0}; int ok = ioctl(1, 0x40087468UL, w) == 0 && w[0] > 0 && w[1] > 0; lean_object* p = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p, 0, lean_box_uint32(ok ? w[0] : 24)); lean_ctor_set(p, 1, lean_box_uint32(ok ? w[1] : 80)); lean_io_result_mk_ok(p); })"]
opaque winSize : IO (UInt32 × UInt32)

/-- Sets the size of the terminal at `fd`, a pty's master or slave, to `rows` by
`cols`, which sends SIGWINCH to the foreground process group of the session it
controls: 0, or the errno. -/
@[extern c inline "({ extern int ioctl(int, unsigned long, ...); extern int* __error(void); unsigned short w[4] = {(unsigned short)#2, (unsigned short)#3, 0, 0}; lean_io_result_mk_ok(lean_box_uint32(ioctl((int)#1, 0x80087467UL, w) == 0 ? 0u : (unsigned)*__error())); })"]
opaque setWinSize (fd rows cols : UInt32) : IO UInt32

end Posix
