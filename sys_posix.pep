## The terminal on Linux and macOS, through termios, private to the module.
## Every platform's file declares the same `_term_` functions. The OS's
## clipboard is reached through the programs that serve it: `pbcopy` and
## `pbpaste` on macOS, and `wl-copy`, `xclip` or `xsel` on Linux.

import async;
import os;
import process;

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
# The same for bracketed paste.
[Target(OS(Linux) || OS(Mac))]
const _term_paste = async.Atomic<bool>(false);
[Target(OS(Linux) || OS(Mac))]
const _PASTE_OFF = "\x1B[?2004l";
[Target(OS(Linux) || OS(Mac))]
const _term_paste_off_bytes: __ptr<u8> = malloc(16);

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
    return _term_mode_on(_term_mouse, $"\x1B[?{code}h\x1B[?1006h", _MOUSE_OFF, _term_mouse_off_bytes);
}

# Turns mouse reporting off. Async-signal-safe: a signal handler calls it.
[Target(OS(Linux) || OS(Mac))]
_term_mouse_off() {
    _term_mode_off(_term_mouse, _term_mouse_off_bytes, _MOUSE_OFF.size);
}

# Asks the terminal for bracketed paste: whether it did.
[Target(OS(Linux) || OS(Mac))]
_term_paste_on(): bool {
    return _term_mode_on(_term_paste, "\x1B[?2004h", _PASTE_OFF, _term_paste_off_bytes);
}

# Turns bracketed paste off. Async-signal-safe: a signal handler calls it.
[Target(OS(Linux) || OS(Mac))]
_term_paste_off() {
    _term_mode_off(_term_paste, _term_paste_off_bytes, _PASTE_OFF.size);
}

# Turns a terminal mode on by writing `on`, when standard input and output
# are a terminal and `state` says it is off, first keeping `off`, which
# turns it off again, in `off_bytes`: whether it did.
[Target(OS(Linux) || OS(Mac))]
_term_mode_on(state: async.Atomic<bool>, on: String, off: String, off_bytes: __ptr<u8>): bool {
    if (state.load() || isatty(0) == 0 || isatty(1) == 0) {
        return false;
    }
    _term_hooks.call(_term_install_hooks);
    var bytes = off.bytes();
    for (var index in 0..bytes.count) {
        off_bytes[index] = bytes[index];
    }
    state.store(true);
    _term_write(on.bytes());
    return true;
}

# Turns a mode `_term_mode_on` turned on off, writing the `size` bytes it
# kept. Async-signal-safe.
[Target(OS(Linux) || OS(Mac))]
_term_mode_off(state: async.Atomic<bool>, off_bytes: __ptr<u8>, size: ulong) {
    if (state.exchange(false)) {
        write(1, off_bytes, size);
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

# Restores the terminal (raw mode, mouse reporting and bracketed paste)
# when the program ends: at exit, and on the signals that end it, a
# panic's SIGABRT (from `abort`) included. A signal the program already
# handles keeps its handler: the program's own shutdown then restores the
# terminal at exit.
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
    _term_paste_off();
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

# The program that serves the OS's clipboard, as `ClipboardBackend.System`
# says: its name, or why there is none.
[Target(OS(Linux) || OS(Mac))]
_term_clipboard_tool(): Result<String> {
    if (os.system_os() == os.OperatingSystem.Mac) {
        if (process.find_executable("pbcopy").is_empty()) {
            return Result<String>.err(Error("no 'pbcopy' on the PATH"));
        }
        return Result<String>.ok("pbcopy");
    }
    if (!os.environment("WAYLAND_DISPLAY").value_or("").is_empty && !process.find_executable("wl-copy").is_empty()) {
        return Result<String>.ok("wl-copy");
    }
    if (!os.environment("DISPLAY").value_or("").is_empty) {
        for (var tool in ["xclip", "xsel"]) {
            if (!process.find_executable(tool).is_empty()) {
                return Result<String>.ok(tool);
            }
        }
    }
    return Result<String>.err(
        Error("no 'wl-copy' (with WAYLAND_DISPLAY set) or 'xclip' or 'xsel' (with DISPLAY set) on the PATH")
    );
}

# The command lines that copy to and read from the clipboard through `tool`.
[Target(OS(Linux) || OS(Mac))]
_term_clipboard_commands(tool: String): (String[], String[]) {
    if (tool == "pbcopy") {
        return (["pbcopy"], ["pbpaste"]);
    }
    if (tool == "wl-copy") {
        return (["wl-copy"], ["wl-paste", "--no-newline"]);
    }
    if (tool == "xclip") {
        return (["xclip", "-selection", "clipboard", "-in"], ["xclip", "-selection", "clipboard", "-out"]);
    }
    return (["xsel", "--clipboard", "--input"], ["xsel", "--clipboard", "--output"]);
}

# Starts the command line `command`, with its standard error dropped.
[Target(OS(Linux) || OS(Mac))]
_term_clipboard_command(command: String[]): process.Command {
    return process
        .Command(command[0])
        .arguments(command.slice(1, command.count).to_array())
        .stderr(process.Stream.Null);
}

# Puts `copied` on the clipboard, through the clipboard's program.
[Target(OS(Linux) || OS(Mac))]
_term_clipboard_copy(copied: String): Result<void> {
    var tool = _term_clipboard_tool();
    if (tool is Err(error)) {
        return Result<void>.err(error);
    }
    var (copy, paste) = _term_clipboard_commands(tool.value());
    # wl-copy, xclip and xsel stay behind to serve the clipboard, holding
    # whatever streams they were given: a pipe for output would never end.
    var started = _term_clipboard_command(copy).stdin(process.Stream.Pipe).stdout(process.Stream.Null).spawn();
    if (started is Err(error)) {
        return Result<void>.err(Error($"could not start '{copy[0]}': {error.message}"));
    }
    var child = started.value();
    child.stdin().write_all(copied);
    child.stdin().close();
    var status = child.wait();
    if (status.is_err() || !status.value().success()) {
        var how = status.is_err() ? "could not be waited for" : $"ended with {status.value()}";
        return Result<void>.err(Error($"'{copy[0]}' {how}"));
    }
    return Result<void>.ok();
}

# The clipboard's text, through the clipboard's program.
[Target(OS(Linux) || OS(Mac))]
_term_clipboard_read(): Result<String> {
    var tool = _term_clipboard_tool();
    if (tool is Err(error)) {
        return Result<String>.err(error);
    }
    var (copy, paste) = _term_clipboard_commands(tool.value());
    var output = _term_clipboard_command(paste).run();
    if (output is Err(error)) {
        return Result<String>.err(Error($"could not run '{paste[0]}': {error.message}"));
    }
    if (!output.value().status.success()) {
        return Result<String>.err(Error($"'{paste[0]}' ended with {output.value().status}"));
    }
    return Result<String>.ok(output.value().stdout);
}
