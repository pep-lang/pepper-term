# Reading a real Windows console: input records are written into this
# process's console with WriteConsoleInputW, and read back through
# `InputReader` as a program would read them, so the console paths
# (ReadConsoleW, input records with the mouse on, waiting for the rest of a
# sequence) are tested without a person at the keyboard. On Linux and macOS
# there is no such console, and the test does nothing.

import term;
import [Event, Key, MouseTracking] from term;

[Target(OS(Windows))]
extern void* GetStdHandle(uint which);
[Target(OS(Windows))]
extern int SetStdHandle(uint which, void* handle);
[Target(OS(Windows))]
extern void* CreateFileW(
    void* name, uint access, uint share, void* security, uint creation, uint flags, void* template
);
[Target(OS(Windows))]
extern int CloseHandle(void* handle);
[Target(OS(Windows))]
extern int AllocConsole();
[Target(OS(Windows))]
extern int WriteConsoleInputW(void* console, void* records, uint count, uint* written);
[Target(OS(Windows))]
extern int GetConsoleScreenBufferInfo(void* console, void* info);
[Target(OS(Windows))]
extern void* malloc(ulong size);
[Target(OS(Windows))]
extern void free(void* p);

# STD_INPUT_HANDLE and STD_OUTPUT_HANDLE.
[Target(OS(Windows))]
const STD_INPUT: uint = 4294967286;
[Target(OS(Windows))]
const STD_OUTPUT: uint = 4294967285;

# Opens the console device `name` ("CONIN$" or "CONOUT$") for reading and
# writing, or null.
[Target(OS(Windows))]
open_console(name: String): __ptr<void> {
    __ptr<ushort> wide = malloc((name.size + 1) * 2);
    var bytes = name.bytes();
    for (var index in 0..bytes.count) {
        wide[index] = bytes[index] as ushort;
    }
    wide[bytes.count] = 0;
    # GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_EXISTING.
    var handle = CreateFileW(wide, 3221225472, 3, __null, 3, 0, __null);
    free(wide);
    # INVALID_HANDLE_VALUE is -1. Hex, since decimal is refused: pep-lang/pepper#158.
    return unsafe_cast<ulong>(handle) == 0xFFFFFFFFFFFFFFFF ? __null : handle;
}

# Builds INPUT_RECORDs, 20 bytes each, to write into the console.
[Target(OS(Windows))]
struct Records {
    var words = Array<ushort>();

    # A key press and its release, typing `unit` (one UTF-16 unit).
    press(unit: ushort) {
        _key(1, unit);
        _key(0, unit);
    }

    # Types each character of `typed`, which is ASCII.
    press_all(typed: String) {
        for (var byte in typed.bytes()) {
            press(byte as ushort);
        }
    }

    # A MOUSE_EVENT record at `column`, `row` of the screen buffer.
    mouse(column: int, row: int, buttons: ushort, flags: ushort) {
        _record(2, [column as ushort, row as ushort, buttons, 0, 0, 0, flags, 0]);
    }

    _key(down: ushort, unit: ushort) {
        # bKeyDown, wRepeatCount 1, wVirtualKeyCode, wVirtualScanCode, UnicodeChar, dwControlKeyState.
        _record(1, [down, 0, 1, 0, 0, unit, 0, 0]);
    }

    _record(kind: ushort, event: ushort[]) {
        words.append(kind);
        words.append(0);
        words.append_all(event);
    }

    write(console: __ptr<void>) {
        __ptr<ushort> buffer = malloc(words.count * 2);
        for (var index in 0..words.count) {
            buffer[index] = words[index];
        }
        __ptr<uint> written = malloc(4);
        expect_true(WriteConsoleInputW(console, buffer, (words.count / 10) as uint, written) != 0);
        expect_equal(written[0] as ulong, words.count / 10);
        free(written);
        free(buffer);
        words = Array<ushort>();
    }
}

describe(event: Event?): String {
    if (event.is_empty()) {
        return "end";
    }
    return match (event.value()) {
        Key(key) => $"key {key}",
        Mouse(mouse) => $"mouse {mouse}",
        Paste(pasted, truncated) => $"paste [{pasted}]",
    };
}

[Target(OS(Windows))]
read_the_console() {
    var input = open_console("CONIN$");
    if (input == __null) {
        AllocConsole();
        input = open_console("CONIN$");
    }
    var output = open_console("CONOUT$");
    expect_true(input != __null && output != __null);
    var saved_input = GetStdHandle(STD_INPUT);
    var saved_output = GetStdHandle(STD_OUTPUT);
    SetStdHandle(STD_INPUT, input);
    SetStdHandle(STD_OUTPUT, output);
    # srWindow's Left and Top, which mouse positions are counted from.
    __ptr<short> info = malloc(24);
    GetConsoleScreenBufferInfo(output, info);
    var left = info[5] as int;
    var top = info[6] as int;
    free(info);

    var records = Records();
    with (var raw = term.RawMode()) {
        expect_true(raw.active);
        var reader = term.InputReader();
        # Keys and a paste, through ReadConsoleW.
        records.press_all("x\x1B[200~a\rb\x1B[201~");
        records.write(input);
        expect_equal(describe(reader.read()), "key x");
        expect_equal(describe(reader.read()), "paste [a\nb]");
        # A paste longer than one read (1024 units) waits for the rest.
        var long = "";
        for (var index in 0..3000) {
            long += "y";
        }
        records.press_all("\x1B[200~" + long + "\x1B[201~");
        records.write(input);
        expect_equal(describe(reader.read()), $"paste [{long}]");
        # A lone Escape is told from a sequence by waiting: its release
        # wakes the wait, and must not block the read.
        records.press(27);
        records.write(input);
        expect_equal(describe(reader.read()), "key Escape");

        with (var mouse = term.MouseMode(MouseTracking.Buttons)) {
            expect_true(mouse.active);
            # A press, a move Buttons did not ask for, a release, then keys
            # and a paste, through the input records.
            records.mouse(left + 3, top + 4, 1, 0);
            records.mouse(left + 5, top + 4, 1, 1);
            records.mouse(left + 5, top + 4, 0, 0);
            records.press_all("q\x1B[200~p\x1B[201~");
            records.write(input);
            expect_equal(describe(reader.read()), "mouse Left Down at 3,4");
            expect_equal(describe(reader.read()), "mouse Left Up at 5,4");
            expect_equal(describe(reader.read()), "key q");
            expect_equal(describe(reader.read()), "paste [p]");
            # Escape, then a move that is not asked for: still the Escape key.
            records.press(27);
            records.mouse(left + 1, top + 1, 0, 1);
            records.write(input);
            expect_equal(describe(reader.read()), "key Escape");
        }
    }
    SetStdHandle(STD_INPUT, saved_input);
    SetStdHandle(STD_OUTPUT, saved_output);
    CloseHandle(input);
    CloseHandle(output);
}

[Target(OS(Linux) || OS(Mac))]
read_the_console() {}

[Test]
reads_keys_mouse_and_pastes_from_the_console() {
    read_the_console();
}
