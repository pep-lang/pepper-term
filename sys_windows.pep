## The terminal on Windows, through the Console API, private to the module.
## Every platform's file declares the same `_term_` functions.
##
## Raw mode turns on virtual terminal input, so the console sends keys as
## the same escape sequences a POSIX terminal does, and `KeyDecoder` reads
## both. Mouse reporting reads the console's input records instead, and
## turns its mouse records into the SGR reports a POSIX terminal sends.

import async;
import text;
import "mouse";

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
extern int ReadConsoleInputW(void* console, void* records, uint count, uint* read);
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
# Console input modes mouse reporting sets, and the one it clears.
[Target(OS(Windows))]
const _ENABLE_MOUSE_INPUT: uint = 16;
[Target(OS(Windows))]
const _ENABLE_QUICK_EDIT_MODE: uint = 64;
[Target(OS(Windows))]
const _ENABLE_EXTENDED_FLAGS: uint = 128;
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
# The mouse mode's number (1000, 1002 or 1003) while it is on, else 0;
# whether Quick Edit was on before it; and the button state of the last
# mouse record, which the next one is compared with.
[Target(OS(Windows))]
const _term_mouse = async.Atomic<int>(0);
[Target(OS(Windows))]
const _term_mouse_quick_edit = async.Atomic<bool>(false);
[Target(OS(Windows))]
const _term_mouse_buttons = async.Atomic<uint>(0);

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
    var (left, top, right, bottom) = _term_window();
    var columns = right - left + 1;
    var rows = bottom - top + 1;
    if (columns <= 0 || rows <= 0) {
        return Optional<(ulong, ulong)>.Empty;
    }
    return Optional<(ulong, ulong)>.Value((columns as ulong, rows as ulong));
}

# The window's cells in the screen buffer: its left, top, right and bottom,
# or all 0 and -1 when standard output is not a console.
[Target(OS(Windows))]
_term_window(): (long, long, long, long) {
    # CONSOLE_SCREEN_BUFFER_INFO is 22 bytes; srWindow's Left, Top, Right
    # and Bottom are the shorts at byte 10.
    __ptr<short> info = malloc(24);
    var ok = GetConsoleScreenBufferInfo(_term_handle(1), info) != 0;
    var window = (info[5] as long, info[6] as long, info[7] as long, info[8] as long);
    free(info);
    return ok ? window : (0, 0, -1, -1);
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

# Turns on the console's mouse input, for the mouse mode `code` (1000,
# 1002 or 1003), and Quick Edit off while it is on: whether it did.
[Target(OS(Windows))]
_term_mouse_on(code: int): bool {
    var input = _term_mode(0);
    if (_term_mouse.load() != 0 || input.is_empty() || !_term_is_terminal(1)) {
        return false;
    }
    _term_hooks.call(_term_install_hooks);
    var mode = input.value();
    var mouse = (mode & ~_ENABLE_QUICK_EDIT_MODE) | _ENABLE_MOUSE_INPUT | _ENABLE_EXTENDED_FLAGS;
    if (SetConsoleMode(_term_handle(0), mouse) == 0) {
        return false;
    }
    _term_mouse_quick_edit.store((mode & _ENABLE_QUICK_EDIT_MODE) != 0);
    _term_mouse_buttons.store(0);
    _term_mouse.store(code);
    return true;
}

# Turns the console's mouse input off, and Quick Edit back on if it was.
# Only those bits change, so raw mode, turned on or off meanwhile, stays as
# it is.
[Target(OS(Windows))]
_term_mouse_off() {
    if (_term_mouse.exchange(0) == 0) {
        return;
    }
    var input = _term_mode(0);
    if (!input.is_empty()) {
        var mode = input.value() & ~_ENABLE_MOUSE_INPUT;
        if (_term_mouse_quick_edit.load()) {
            mode = mode | _ENABLE_QUICK_EDIT_MODE | _ENABLE_EXTENDED_FLAGS;
        }
        SetConsoleMode(_term_handle(0), mode);
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
    var tracking = _term_mouse.load();
    if (tracking != 0) {
        return _term_read_records(buffer, tracking);
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

# Reads the console's input records while mouse input is on, which
# ReadConsoleW would drop: key presses become their characters (virtual
# terminal input makes them the same sequences as on POSIX), and mouse
# records the SGR reports a terminal sends, so both reach the decoder in
# order. Waits until a record gives a byte; -1 on an error.
#
# shortcut: a console that passes the terminal's own SGR reports through
# as key records (Windows Terminal, with virtual terminal input) is not
# filtered by `tracking`, so it may report moves Buttons did not ask for;
# filter in the decoder if a program needs that.
[Target(OS(Windows))]
_term_read_records(buffer: u8[], tracking: int): long {
    var handle = _term_handle(0);
    # INPUT_RECORD is 20 bytes: EventType, padding, then the event.
    __ptr<ushort> records = malloc(20 * 128);
    __ptr<uint> count = malloc(4);
    var start = buffer.count;
    var utf16 = Array<u8>();
    var ok = true;
    while (ok && buffer.count == start) {
        count[0] = 0;
        ok = ReadConsoleInputW(handle, records, 128, count) != 0 && count[0] > 0;
        __ptr<uint> words = unsafe_cast<__ptr<uint>>(records);
        __ptr<short> shorts = unsafe_cast<__ptr<short>>(records);
        var (left, top, right, bottom) = _term_window();
        for (var index in 0..(ok ? count[0] as ulong : 0)) {
            var at = index * 10;
            # Alt+numpad typing gives its character when Alt (VK_MENU, 18) is released.
            var typed = words[at / 2 + 1] != 0 || records[at + 5] == 18;
            if (records[at] == 1 && typed && records[at + 7] != 0) {
                # KEY_EVENT: bKeyDown, wRepeatCount, wVirtualKeyCode, then UnicodeChar.
                for (var repeat in 0..(records[at + 4] > 0 ? records[at + 4] as ulong : 1)) {
                    utf16.append((records[at + 7] & 255) as u8);
                    utf16.append((records[at + 7] >> 8) as u8);
                }
            } else if (records[at] == 2) {
                # MOUSE_EVENT: the position's X and Y, then dwButtonState,
                # dwControlKeyState and dwEventFlags.
                buffer.append_all(text.Utf16.decode_lossy(utf16).bytes());
                utf16 = Array<u8>();
                var x = shorts[at + 2] as long - left;
                var y = shorts[at + 3] as long - top;
                var buttons = words[at / 2 + 2];
                var events = _mouse_from_record(
                    buttons,
                    _term_mouse_buttons.exchange(buttons),
                    words[at / 2 + 3],
                    words[at / 2 + 4],
                    (x > 0 ? x : 0) as ulong,
                    (y > 0 ? y : 0) as ulong,
                    tracking
                );
                for (var event in events) {
                    buffer.append_all(event._sgr().bytes());
                }
            }
        }
        buffer.append_all(text.Utf16.decode_lossy(utf16).bytes());
        utf16 = Array<u8>();
    }
    free(records);
    free(count);
    return ok ? (buffer.count - start) as long : -1;
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
    var at_exit: extern () => void = _term_restore_all;
    atexit(at_exit);
    var handler: extern (int) => void = _term_on_abort;
    var previous = signal(_SIGABRT, handler);
    if (previous != __null) {
        signal(_SIGABRT, previous);
    }
}

[Target(OS(Windows))]
_term_restore_all() {
    _term_mouse_off();
    _term_restore();
}

[Target(OS(Windows))]
_term_on_abort(number: int) {
    _term_restore_all();
}
