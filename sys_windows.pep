## The terminal on Windows, through the Console API, private to the module.
## Every platform's file declares the same `_term_` functions.
##
## Raw mode turns on virtual terminal input, so the console sends keys as
## the same escape sequences a POSIX terminal does, and `KeyDecoder` reads
## both.

import async;
import text;

[Target(OS(Windows))]
extern void* GetStdHandle(uint which);
[Target(OS(Windows))]
extern int GetConsoleMode(void* console, uint* mode);
[Target(OS(Windows))]
extern int SetConsoleMode(void* console, uint mode);
[Target(OS(Windows))]
extern int GetConsoleScreenBufferInfo(void* console, void* info);
[Target(OS(Windows))]
extern int ReadConsoleW(void* console, void* buffer, uint count, uint* read, void* control);
[Target(OS(Windows))]
extern uint WaitForSingleObject(void* handle, uint milliseconds);
[Target(OS(Windows))]
extern void* signal(int number, void* handler);
[Target(OS(Windows))]
extern int atexit(void* function);
[Target(OS(Windows))]
extern void* malloc(ulong size);
[Target(OS(Windows))]
extern void free(void* p);

# STD_INPUT_HANDLE and STD_OUTPUT_HANDLE: (DWORD)-10 and (DWORD)-11.
[Target(OS(Windows))]
const _STD_INPUT: uint = 4294967286;
[Target(OS(Windows))]
const _STD_OUTPUT: uint = 4294967285;

# Console input modes raw mode clears, and the one it sets.
[Target(OS(Windows))]
const _ENABLE_PROCESSED_INPUT: uint = 1;
[Target(OS(Windows))]
const _ENABLE_LINE_INPUT: uint = 2;
[Target(OS(Windows))]
const _ENABLE_ECHO_INPUT: uint = 4;
[Target(OS(Windows))]
const _ENABLE_VIRTUAL_TERMINAL_INPUT: uint = 512;
# The output mode that makes the console read ANSI escape sequences.
[Target(OS(Windows))]
const _ENABLE_VIRTUAL_TERMINAL_PROCESSING: uint = 4;

# The CRT's SIGABRT, which `abort` raises: what a panic ends with.
[Target(OS(Windows))]
const _SIGABRT = 22;

# Whether raw mode is on, so the restore at exit or on a panic knows to act.
[Target(OS(Windows))]
const _term_raw = async.Atomic<bool>(false);
# The console's input and output modes before raw mode.
[Target(OS(Windows))]
const _term_saved_input = async.Atomic<uint>(0);
[Target(OS(Windows))]
const _term_saved_output = async.Atomic<uint>(0);
[Target(OS(Windows))]
const _term_hooks = async.Once();

[Target(OS(Windows))]
_term_handle(fd: int): __ptr<void> {
    return GetStdHandle(fd == 0 ? _STD_INPUT : _STD_OUTPUT);
}

# The console mode of standard input (0) or output (1), or none when it is
# not a console.
[Target(OS(Windows))]
_term_mode(fd: int): uint? {
    __ptr<uint> mode = malloc(4);
    mode[0] = 0;
    var ok = GetConsoleMode(_term_handle(fd), mode) != 0;
    var value = mode[0];
    free(mode);
    return ok ? Optional<uint>.Value(value) : Optional<uint>.Empty;
}

[Target(OS(Windows))]
_term_is_terminal(fd: int): bool {
    return !_term_mode(fd).is_empty();
}

[Target(OS(Windows))]
_term_size(): (ulong, ulong)? {
    # CONSOLE_SCREEN_BUFFER_INFO is 22 bytes; srWindow's Left, Top, Right
    # and Bottom are the shorts at byte 10.
    __ptr<short> info = malloc(24);
    var ok = GetConsoleScreenBufferInfo(_term_handle(1), info) != 0;
    var columns = (info[7] - info[5] + 1) as long;
    var rows = (info[8] - info[6] + 1) as long;
    free(info);
    if (!ok || columns <= 0 || rows <= 0) {
        return Optional<(ulong, ulong)>.Empty;
    }
    return Optional<(ulong, ulong)>.Value((columns as ulong, rows as ulong));
}

[Target(OS(Windows))]
_term_enter_raw(): bool {
    var input = _term_mode(0);
    if (_term_raw.load() || input.is_empty()) {
        return false;
    }
    _term_hooks.call(_term_install_hooks);
    var output = _term_mode(1);
    _term_saved_input.store(input.value());
    _term_saved_output.store(output.value_or(0));
    var clear = _ENABLE_PROCESSED_INPUT | _ENABLE_LINE_INPUT | _ENABLE_ECHO_INPUT;
    var raw = (input.value() & ~clear) | _ENABLE_VIRTUAL_TERMINAL_INPUT;
    if (SetConsoleMode(_term_handle(0), raw) == 0) {
        return false;
    }
    if (!output.is_empty()) {
        SetConsoleMode(_term_handle(1), output.value() | _ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
    _term_raw.store(true);
    return true;
}

[Target(OS(Windows))]
_term_restore() {
    if (_term_raw.exchange(false)) {
        SetConsoleMode(_term_handle(0), _term_saved_input.load());
        var output = _term_saved_output.load();
        if (output != 0) {
            SetConsoleMode(_term_handle(1), output);
        }
    }
}

# Reads what the console has, waiting at most `timeout` milliseconds (-1:
# as long as it takes): the bytes appended, as UTF-8, 0 when the time ran
# out, or -1 on an error.
[Target(OS(Windows))]
_term_read(buffer: u8[], timeout: int): long {
    # shortcut: the console puts a key's whole escape sequence in its input
    # buffer at once, so after a read nothing more is waited for, and a
    # read that ends in Escape is the Escape key. Wait on the handle if a
    # console turns out to split them.
    if (timeout >= 0) {
        return 0;
    }
    var handle = _term_handle(0);
    __ptr<u8> units = malloc(2048);
    __ptr<uint> count = malloc(4);
    count[0] = 0;
    var ok = ReadConsoleW(handle, units, 1024, count, __null) != 0;
    var size = (count[0] as ulong) * 2;
    var utf16 = Array<u8>();
    for (var index in 0..size) {
        utf16.append(units[index]);
    }
    free(units);
    free(count);
    if (!ok || size == 0) {
        return -1;
    }
    # shortcut: a surrogate pair split across two reads decodes to two
    # U+FFFD; 1024 units a read make that rare.
    var bytes = text.Utf16.decode_lossy(utf16).bytes();
    buffer.append_all(bytes);
    return bytes.count as long;
}

# Turns on the console's reading of ANSI escape sequences, which Windows
# Terminal has on already and the older console host does not.
[Target(OS(Windows))]
_term_enable_sequences(): bool {
    var mode = _term_mode(1);
    if (mode.is_empty()) {
        return false;
    }
    var value = mode.value();
    return (value & _ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0
        || SetConsoleMode(_term_handle(1), value | _ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
}

# Console modes outlive the process, so restore them when the program ends:
# at exit, and on a panic's `abort`, which raises SIGABRT and then ends the
# process once the handler returns.
[Target(OS(Windows))]
_term_install_hooks() {
    var at_exit: extern () => void = _term_restore;
    atexit(at_exit);
    var handler: extern (int) => void = _term_on_abort;
    var previous = signal(_SIGABRT, handler);
    if (previous != __null) {
        signal(_SIGABRT, previous);
    }
}

[Target(OS(Windows))]
_term_on_abort(number: int) {
    _term_restore();
}
