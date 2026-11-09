/-!
# Terminals: a pty, a controlling terminal, the window size

The numbers are macOS's: O_RDWR 2, O_NOCTTY 0x20000, O_CLOEXEC 0x1000000,
TCSAFLUSH 2, TIOCGWINSZ 0x40087468,
TIOCSWINSZ 0x80087467, ENOTTY 25, EBADF 9; `struct winsize` is four unsigned
shorts, rows first.
-/

namespace Posix

/-- A raw terminal, so it neither turns \n into \r\n nor echoes: the master
and the slave, which no child inherits. Both are close-on-exec from the moment
they are opened: no program a child executes has either open, not even a child
another thread starts while `openPty` runs or before the caller closes the slave
(a forked child holds them only until its exec), so the master sees the end of
the slave once the caller has closed its copies and the children it gave the
slave are gone. To give a child the slave, make it the child's 0, 1 or 2
(`spawn ... s s s`, which clears close-on-exec even on a slave that is already
that number, or a `dup2` onto another number, which leaves the copy without it).
`loginTty` in a forked child dup2s it onto 0, 1 and 2, so a slave that is itself
0, 1 or 2 (stdio closed before `openPty`) stays close-on-exec at that number.
`cfmakeraw` fills a `struct termios`, which fits in the buffer. Both are large
numbers when no pty can be had.

The steps are `openpty`'s, but the master is opened by `posix_openpt` with
O_CLOEXEC, which POSIX.1-2024 specifies for it, and the slave by `open` with
O_CLOEXEC, rather than made close-on-exec by a later `fcntl`. macOS's
grantpt(3) lists only O_RDWR and O_NOCTTY and returns EINVAL for "an invalid mode bit", so a system that refused O_CLOEXEC
would make `openPty` fail rather than hand out a master a program inherits.
`lake test` checks that a child's program has neither. -/
@[extern c inline "({ extern int posix_openpt(int); extern int grantpt(int); extern int unlockpt(int); extern int ptsname_r(int, char*, unsigned long); extern int open(const char*, int, ...); extern int close(int); extern void cfmakeraw(void*); extern int tcsetattr(int, int, const void*); unsigned long t[32] = {0}; cfmakeraw(t); char name[128]; int s = -1; int m = posix_openpt(0x2 | 0x20000 | 0x1000000); if (m >= 0 && (grantpt(m) != 0 || unlockpt(m) != 0 || ptsname_r(m, name, sizeof name) != 0 || (s = open(name, 0x2 | 0x20000 | 0x1000000)) < 0 || tcsetattr(s, 2, t) != 0)) { if (s >= 0) close(s); close(m); m = -1; s = -1; } lean_object* p = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p, 0, lean_box_uint32((unsigned)m)); lean_ctor_set(p, 1, lean_box_uint32((unsigned)s)); lean_io_result_mk_ok(p); })"]
opaque openPty : IO (UInt32 × UInt32)

/-- A new session with `fd`, a terminal, as its controlling terminal and stdio: 0,
or a large number when it failed. For a child before it executes its command. -/
@[extern c inline "({ extern int login_tty(int); lean_io_result_mk_ok(lean_box_uint32((unsigned)login_tty((int)#1))); })"]
opaque loginTty (fd : UInt32) : IO UInt32

/-- The rows and columns of the terminal at stdout, or 24 by 80 when it does not
say. -/
@[extern c inline "({ extern int ioctl(int, unsigned long, ...); unsigned short w[4] = {0}; int ok = ioctl(1, 0x40087468UL, w) == 0 && w[0] > 0 && w[1] > 0; lean_object* p = lean_alloc_ctor(0, 2, 0); lean_ctor_set(p, 0, lean_box_uint32(ok ? w[0] : 24)); lean_ctor_set(p, 1, lean_box_uint32(ok ? w[1] : 80)); lean_io_result_mk_ok(p); })"]
opaque winSize : IO (UInt32 × UInt32)

/-- `winSizeOf`'s result, encoded: rows in bits 16 to 31 and columns in bits 0 to
15, or the high bit or-ed with the errno. -/
@[extern c inline "({ extern int ioctl(int, unsigned long, ...); extern int* __error(void); unsigned short w[4] = {0}; uint64_t r = ioctl((int)#1, 0x40087468UL, w) == 0 ? ((uint64_t)w[0] << 16) | w[1] : (1ull << 63) | (unsigned)*__error(); lean_io_result_mk_ok(lean_box_uint64(r)); })"]
private opaque winSizeRaw (fd : UInt32) : IO UInt64

/-- The rows and columns of the terminal at `fd`, as it says them (0 by 0 when
nobody has set them, as on a new pty); or the errno: ENOTTY (25) when `fd` is no
terminal (a pipe, a file), EBADF (9) when it is not open. For a program whose
stdout is a pipe and whose stderr is a terminal, `winSizeOf 2`. -/
def winSizeOf (fd : UInt32) : IO (Except UInt32 (UInt32 × UInt32)) := do
  let r ← winSizeRaw fd
  return if r &&& ((1 : UInt64) <<< 63) == 0 then .ok (((r >>> 16) &&& 0xffff).toUInt32, (r &&& 0xffff).toUInt32)
    else .error (r &&& 0xffffffff).toUInt32

/-- Sets the size of the terminal at `fd`, a pty's master or slave, to `rows` by
`cols`, which sends SIGWINCH to the foreground process group of the session it
controls: 0, or the errno. -/
@[extern c inline "({ extern int ioctl(int, unsigned long, ...); extern int* __error(void); unsigned short w[4] = {(unsigned short)#2, (unsigned short)#3, 0, 0}; lean_io_result_mk_ok(lean_box_uint32(ioctl((int)#1, 0x80087467UL, w) == 0 ? 0u : (unsigned)*__error())); })"]
opaque setWinSize (fd rows cols : UInt32) : IO UInt32

end Posix
