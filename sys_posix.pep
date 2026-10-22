## The terminal on Linux and macOS, through termios, private to the module.
## Every platform's file declares the same `_term_` functions.

import async;

[Target(OS(Linux) || OS(Mac))]
extern int isatty(int fd);
[Target(OS(Linux) || OS(Mac))]
extern int tcgetattr(int fd, void* termios);
[Target(OS(Linux) || OS(Mac))]
extern int tcsetattr(int fd, int actions, void* termios);
[Target(OS(Linux) || OS(Mac))]
extern void cfmakeraw(void* termios);
[Target(OS(Linux) || OS(Mac))]
extern int ioctl(int fd, ulong request, ...);
[Target(OS(Linux) || OS(Mac))]
extern int poll(void* fds, ulong count, int timeout);
[Target(OS(Linux) || OS(Mac))]
extern long read(int fd, void* buffer, ulong size);
[Target(OS(Linux) || OS(Mac))]
extern long write(int fd, void* buffer, ulong size);
[Target(OS(Linux) || OS(Mac))]
extern void* signal(int number, void* handler);
[Target(OS(Linux) || OS(Mac))]
extern int raise(int number);
[Target(OS(Linux) || OS(Mac))]
extern int atexit(void* function);
[Target(OS(Linux) || OS(Mac))]
extern void* malloc(ulong size);
[Target(OS(Linux) || OS(Mac))]
extern void free(void* p);

# Room for a `struct termios`: 60 bytes on Linux, 72 on macOS.
[Target(OS(Linux) || OS(Mac))]
const _TERMIOS_SIZE: ulong = 256;
# tcsetattr's TCSANOW and TCSAFLUSH, the same on both.
[Target(OS(Linux) || OS(Mac))]
const _TCSANOW = 0;
[Target(OS(Linux) || OS(Mac))]
const _TCSAFLUSH = 2;

[Target(OS(Linux))]
const _TIOCGWINSZ: ulong = 21523;  # 0x5413
[Target(OS(Mac))]
const _TIOCGWINSZ: ulong = 1074295912;  # 0x40087468

# Whether raw mode is on, so the restore on exit or on a signal knows to
# act.
[Target(OS(Linux) || OS(Mac))]
const _term_raw = async.Atomic<bool>(false);
# The terminal's settings before raw mode, which restoring puts back.
[Target(OS(Linux) || OS(Mac))]
const _term_saved: __ptr<void> = malloc(_TERMIOS_SIZE);
[Target(OS(Linux) || OS(Mac))]
const _term_hooks = async.Once();

# Whether mouse reporting is on, and the sequence that turns it off, kept
# as bytes so a signal handler can write it without allocating.
[Target(OS(Linux) || OS(Mac))]
const _term_mouse = async.Atomic<bool>(false);
[Target(OS(Linux) || OS(Mac))]
const _MOUSE_OFF = "\x1B[?1006l\x1B[?1003l\x1B[?1002l\x1B[?1000l";
[Target(OS(Linux) || OS(Mac))]
const _term_mouse_off_bytes: __ptr<u8> = malloc(64);

[Target(OS(Linux) || OS(Mac))]
_term_is_terminal(fd: int): bool {
    return isatty(fd) != 0;
}

[Target(OS(Linux) || OS(Mac))]
_term_size(): (ulong, ulong)? {
    # struct winsize: rows, columns, then two pixel sizes, each a ushort.
    __ptr<ushort> size = malloc(8);
    size[0] = 0;
    size[1] = 0;
    var ok = ioctl(1, _TIOCGWINSZ, size) == 0 || ioctl(0, _TIOCGWINSZ, size) == 0;
    var rows = size[0] as ulong;
    var columns = size[1] as ulong;
    free(size);
    if (!ok || columns == 0) {
        return Optional<(ulong, ulong)>.Empty;
    }
    return Optional<(ulong, ulong)>.Value((columns, rows));
}

[Target(OS(Linux) || OS(Mac))]
_term_enter_raw(): bool {
    if (_term_raw.load() || isatty(0) == 0 || tcgetattr(0, _term_saved) != 0) {
        return false;
    }
    _term_hooks.call(_term_install_hooks);
    __ptr<void> raw = malloc(_TERMIOS_SIZE);
    _copy(raw, _term_saved, _TERMIOS_SIZE);
    cfmakeraw(raw);
    var ok = tcsetattr(0, _TCSAFLUSH, raw) == 0;
    free(raw);
    _term_raw.store(ok);
    return ok;
}

# Puts the saved settings back. Async-signal-safe: a signal handler calls
# it.
[Target(OS(Linux) || OS(Mac))]
_term_restore() {
    if (_term_raw.exchange(false)) {
        tcsetattr(0, _TCSANOW, _term_saved);
    }
}

# Asks the terminal for xterm's mouse reports of mode `code` (1000, 1002
# or 1003), SGR-encoded: whether it did.
[Target(OS(Linux) || OS(Mac))]
_term_mouse_on(code: int): bool {
    if (_term_mouse.load() || isatty(0) == 0 || isatty(1) == 0) {
        return false;
    }
    _term_hooks.call(_term_install_hooks);
    var off = _MOUSE_OFF.bytes();
    for (var index in 0..off.count) {
        _term_mouse_off_bytes[index] = off[index];
    }
    _term_mouse.store(true);
    _term_write($"\x1B[?{code}h\x1B[?1006h".bytes());
    return true;
}

# Turns mouse reporting off. Async-signal-safe: a signal handler calls it.
[Target(OS(Linux) || OS(Mac))]
_term_mouse_off() {
    if (_term_mouse.exchange(false)) {
        write(1, _term_mouse_off_bytes, _MOUSE_OFF.size);
    }
}

[Target(OS(Linux) || OS(Mac))]
_term_write(bytes: u8[]) {
    __ptr<u8> buffer = malloc(bytes.count);
    for (var index in 0..bytes.count) {
        buffer[index] = bytes[index];
    }
    write(1, buffer, bytes.count);
    free(buffer);
}

# Reads what standard input has, waiting at most `timeout` milliseconds
# (-1: as long as it takes): the bytes appended, 0 when the time ran out,
# or -1 at the end of input or on an error.
[Target(OS(Linux) || OS(Mac))]
_term_read(buffer: u8[], timeout: int): long {
    # struct pollfd: int fd, short events, short revents.
    __ptr<int> poll_fd = malloc(8);
    poll_fd[0] = 0;
    poll_fd[1] = 1;  # events = POLLIN, revents = 0
    var ready = poll(poll_fd, 1, timeout);
    free(poll_fd);
    if (ready <= 0) {
        # Timed out, or interrupted by a signal: the caller tries again.
        return 0;
    }
    __ptr<u8> bytes = malloc(1024);
    var count = read(0, bytes, 1024);
    for (var index in 0..(count > 0 ? count : 0)) {
        buffer.append(bytes[index]);
    }
    free(bytes);
    return count > 0 ? count : -1;
}

# Terminals read ANSI sequences as they are.
[Target(OS(Linux) || OS(Mac))]
_term_enable_sequences(): bool {
    return true;
}

[Target(OS(Linux) || OS(Mac))]
_copy(target: __ptr<void>, source: __ptr<void>, size: ulong) {
    __ptr<u8> to = target as __ptr<u8>;
    __ptr<u8> from = source as __ptr<u8>;
    for (var index in 0..size) {
        to[index] = from[index];
    }
}

# Restores the terminal (raw mode and mouse reporting) when the program ends: at exit, and on the signals
# that end it, a panic's SIGABRT (from `abort`) included. A signal the
# program already handles keeps its handler: the program's own shutdown
# then restores the terminal at exit.
[Target(OS(Linux) || OS(Mac))]
_term_install_hooks() {
    var at_exit: extern () => void = _term_restore_all;
    atexit(at_exit);
    var handler: extern (int) => void = _term_on_signal;
    # SIGHUP, SIGINT, SIGQUIT, SIGABRT, SIGTERM.
    for (var number in [1, 2, 3, 6, 15]) {
        var previous = signal(number, handler);
        if (previous != __null) {
            signal(number, previous);
        }
    }
}

[Target(OS(Linux) || OS(Mac))]
_term_restore_all() {
    _term_mouse_off();
    _term_restore();
}

[Target(OS(Linux) || OS(Mac))]
_term_on_signal(number: int) {
    _term_restore_all();
    # The default action, once this handler returns and the signal is
    # unblocked.
    signal(number, __null);
    raise(number);
}
