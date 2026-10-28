## The terminal itself: whether the standard streams are one, its size,
## raw mode, mouse reporting, bracketed paste, and reading keys, mouse
## reports, pastes and edited lines from it. Each part degrades when there
## is no terminal (input from a pipe or a file, output to one): raw mode,
## mouse reporting and bracketed paste do nothing, keys are decoded from the bytes as they come,
## lines are read plainly, and `colors_enabled` is false.

import io;
import os;
import text;
import "keys";
import "line";
import "mouse";
import "sys_posix";
import "sys_windows";

## Returns whether standard input is a terminal (a console on Windows),
## rather than a pipe or a file.
##
## @returns true for a terminal
export input_is_terminal(): bool {
    return _term_is_terminal(0);
}

## Returns whether standard output is a terminal (a console on Windows),
## rather than a pipe or a file.
##
## @returns true for a terminal
export output_is_terminal(): bool {
    return _term_is_terminal(1);
}

## A terminal's size, in character cells.
export struct Size {
    ## The number of columns.
    const columns: ulong;
    ## The number of rows.
    const rows: ulong;

    ## Makes a size.
    ##
    ## @param columns the number of columns
    ## @param rows the number of rows
    construct(columns: ulong, rows: ulong) {
        this.columns = columns;
        this.rows = rows;
    }
}

## Returns the size of the terminal that standard output (or else standard
## input) is on, at the time of the call.
##
## @returns the size, or none when neither is a terminal
export size(): Size? {
    var size = _term_size();
    if (size.is_empty()) {
        return Optional<Size>.Empty;
    }
    var (columns, rows) = size.value();
    return Optional<Size>.Value(Size(columns, rows));
}

## Returns whether to write colors and styles to standard output: it is a
## terminal, the `NO_COLOR` environment variable is unset or empty (see
## no-color.org), and `TERM` is not `dumb`. On Windows it also turns on
## the console's reading of escape sequences, and is false when the
## console cannot.
##
## @returns true when colors will show
## @example
##     import term;
##     import [BasicColor, Color, Style] from term;
##
##     var error = Style(foreground = Color.Basic(BasicColor.Red));
##     print(error.paint("failed", term.colors_enabled()));
export colors_enabled(): bool {
    if (!output_is_terminal() || !os.environment("NO_COLOR").value_or("").is_empty) {
        return false;
    }
    if (os.environment("TERM").value_or("") == "dumb") {
        return false;
    }
    return _term_enable_sequences();
}

## Raw mode: the terminal hands over each key as it is pressed, without
## echoing it, editing the line, or turning Ctrl+C into a signal, as an
## editor or a game needs. Making a `RawMode` turns it on; `exit`, or the
## last reference going away, turns it off again.
##
## Use it in a `with` block, which turns raw mode off however the block
## ends. The terminal is also restored when the program ends while raw
## mode is on: at the end of `main` or `process.exit`, on a panic, and on
## SIGTERM, SIGHUP, SIGINT or SIGQUIT (POSIX).
##
## In raw mode on Linux and macOS, output is raw too: "\n" moves down
## without returning to the first column, so write "\r\n".
##
## Without a terminal on standard input, raw mode does nothing and `active`
## is false. Raw mode is one setting of the whole terminal, so while one
## `RawMode` has it on, another is not `active` either.
##
## @example
##     import term;
##
##     main(): int {
##         with (var raw = term.RawMode()) {
##             var keys = term.KeyReader();
##             print(raw.active ? "press a key\r" : "not a terminal");
##             var key = keys.read();
##             if (!key.is_empty()) {
##                 print($"you pressed {key.value()}\r");
##             }
##         }
##         return 0;
##     }
export struct RawMode {
    var _active: bool;

    ## Turns raw mode on, when standard input is a terminal and raw mode is
    ## not on already.
    construct() {
        _active = _term_enter_raw();
    }

    destruct {
        exit();
    }

    ## Whether this `RawMode` turned raw mode on, and will turn it off.
    var active: bool {
        get {
            return _active;
        }
    }

    ## Returns this `RawMode`, for a `with` block.
    ##
    ## @returns this
    enter(): RawMode {
        return this;
    }

    ## Turns raw mode off, putting back the terminal's settings from before,
    ## if this `RawMode` turned it on. Later calls do nothing.
    exit() {
        if (_active) {
            _active = false;
            _term_restore();
        }
    }
}

extend RawMode with Scoped<RawMode>;

## Which mouse reports `MouseMode` asks for.
export enum MouseTracking {
    ## Presses, releases and the wheel (xterm's mode 1000).
    Buttons,
    ## Those, and moves while a button is held (mode 1002).
    Drag,
    ## Those, and every move (mode 1003).
    Motion,
}

## Mouse reporting: while it is on, the terminal sends mouse presses,
## releases, the wheel and, as `tracking` says, moves, which
## `InputReader` reads as `Event.Mouse`. Making a `MouseMode` turns it on;
## `exit`, or the last reference going away, turns it off again. It is off
## unless a program asks: without it the terminal keeps the mouse, to
## select and scroll.
##
## Use it in a `with` block, inside a `RawMode`'s. Like raw mode it is
## turned off when the program ends while it is on: at the end of `main`
## or `process.exit`, on a panic, and on SIGTERM, SIGHUP, SIGINT or SIGQUIT
## (POSIX).
##
## On Linux and macOS it asks the terminal for xterm's reports in SGR
## encoding (mode 1006), which every current terminal speaks. On Windows
## it turns on the console's mouse input, and turns Quick Edit (selecting
## with the mouse) off while it is on.
##
## Without a terminal on standard input and output it does nothing, and
## `active` is false. Mouse reporting is one setting of the whole
## terminal, so while one `MouseMode` has it on, another is not `active`.
##
## @example
##     import term;
##     import [Event] from term;
##
##     main(): int {
##         with (var raw = term.RawMode()) {
##             with (var mouse = term.MouseMode()) {
##                 var input = term.InputReader();
##                 var event = input.read();
##                 if (!event.is_empty()) {
##                     match (event.value()) {
##                         Key(key) => print($"key {key}\r"),
##                         Mouse(click) => print($"mouse {click}\r"),
##                         Paste(text, truncated) => print($"paste {text}\r"),
##                         else => {}
##                     }
##                 }
##             }
##         }
##         return 0;
##     }
export struct MouseMode {
    var _active: bool;

    ## Turns mouse reporting on, when standard input and output are a
    ## terminal and it is not on already.
    ##
    ## @param tracking which reports to ask for
    construct(tracking: MouseTracking = MouseTracking.Buttons) {
        _active = _term_mouse_on(_mouse_mode_code(tracking));
    }

    destruct {
        exit();
    }

    ## Whether this `MouseMode` turned reporting on, and will turn it off.
    var active: bool {
        get {
            return _active;
        }
    }

    ## Returns this `MouseMode`, for a `with` block.
    ##
    ## @returns this
    enter(): MouseMode {
        return this;
    }

    ## Turns mouse reporting off, if this `MouseMode` turned it on. Later
    ## calls do nothing.
    exit() {
        if (_active) {
            _active = false;
            _term_mouse_off();
        }
    }
}

extend MouseMode with Scoped<MouseMode>;

# xterm's mode number for `tracking`: what the platform files take.
_mouse_mode_code(tracking: MouseTracking): int {
    return match (tracking) {
        Buttons => 1000,
        Drag => 1002,
        Motion => 1003,
    };
}

## Bracketed paste: while it is on, the terminal marks the start and end
## of text pasted into it, so `InputReader` reads each paste whole, as one
## `Event.Paste`, rather than as typed keys, and a paste with line ends
## does not run as one command per line. Making a `PasteMode` turns it on;
## `exit`, or the last reference going away, turns it off again. It is off
## unless a program asks.
##
## Use it in a `with` block. Like raw mode it is turned off when the
## program ends while it is on: at the end of `main` or `process.exit`, on
## a panic, and on SIGTERM, SIGHUP, SIGINT or SIGQUIT (POSIX).
##
## It asks for xterm's bracketed paste (mode 2004), which current
## terminals on Linux and macOS, and Windows Terminal, have. A terminal
## without it ignores the request, and its pastes arrive as typed keys, as
## they do in the older Windows console. On Windows it turns on the
## console's reading of escape sequences, which the request needs.
##
## Without a terminal on standard input and output it does nothing, and
## `active` is false. Bracketed paste is one setting of the whole
## terminal, so while one `PasteMode` has it on, another is not `active`.
##
## @example
##     import term;
##     import [LineInput] from term;
##
##     main(): int {
##         with (var paste = term.PasteMode()) {
##             var reader = term.LineReader();
##             match (reader.read_line("> ")) {
##                 Line(text) => print($"read {text}"),
##                 Interrupted => {}
##                 EndOfInput => {}
##             }
##         }
##         return 0;
##     }
export struct PasteMode {
    var _active: bool;

    ## Turns bracketed paste on, when standard input and output are a
    ## terminal and it is not on already.
    construct() {
        _active = _term_paste_on();
    }

    destruct {
        exit();
    }

    ## Whether this `PasteMode` turned bracketed paste on, and will turn it
    ## off.
    var active: bool {
        get {
            return _active;
        }
    }

    ## Returns this `PasteMode`, for a `with` block.
    ##
    ## @returns this
    enter(): PasteMode {
        return this;
    }

    ## Turns bracketed paste off, if this `PasteMode` turned it on. Later
    ## calls do nothing.
    exit() {
        if (_active) {
            _active = false;
            _term_paste_off();
        }
    }
}

extend PasteMode with Scoped<PasteMode>;

## Turns raw mode, mouse reporting and bracketed paste off now, wherever
## they were turned on, before the program ends. Does nothing when all are
## off. A copy started by `process.fork()` ends without exit handlers, so
## it calls this before `process.exit`.
export restore() {
    _term_restore_all();
}

# How long to wait, after bytes that may start an escape sequence, for the
# rest of it before deciding they were the Escape key.
const _ESCAPE_WAIT_MS = 50;
# How long to wait for more of a paste or a clipboard reply whose end has
# not come, before deciding it never will.
const _PASTE_WAIT_MS = 1000;

## Reads what the user does from standard input, decoding it with an
## `InputDecoder`: key presses and, while a `MouseMode` or `PasteMode` is
## on, mouse reports and pastes. A paste whose end does not come within a
## second is given back as typed keys.
##
## On a terminal in raw mode, each key arrives as it is pressed. Outside
## raw mode the terminal sends nothing until Enter. Without a terminal,
## the input's bytes are decoded as they come: text gives `Key.Char`
## events, and line ends give `Key.Enter`.
export struct InputReader {
    var _decoder = InputDecoder();
    var _ready = Array<Event>();
    var _next: ulong = 0;
    var _ended = false;
    var _terminal: bool;

    ## Makes a reader of standard input.
    construct() {
        _terminal = input_is_terminal();
    }

    ## Waits for the next key press, mouse report or paste.
    ##
    ## @returns the event, or none at the end of input
    read(): Event? {
        while (_next >= _ready.count) {
            if (_ended) {
                return Optional<Event>.Empty;
            }
            _fill();
        }
        _next += 1;
        return Optional<Event>.Value(_ready[_next - 1]);
    }

    _fill() {
        _ready = Array<Event>();
        _next = 0;
        var bytes = Array<u8>();
        var wait = _decoder._in_text() ? _PASTE_WAIT_MS : (_decoder.has_pending ? _ESCAPE_WAIT_MS : -1);
        long count = 0;
        if (_terminal) {
            count = _term_read(bytes, wait);
        } else {
            var read = io.File.stdin().read(bytes, 4096);
            count = read.is_ok() && read.value() > 0 ? read.value() as long : -1;
        }
        if (count < 0) {
            _ended = true;
            _ready = _decoder.flush();
            return;
        }
        _ready = count == 0 ? _decoder.flush() : _decoder.feed(bytes);
        if (!_terminal && _decoder.has_pending && !_decoder._in_text()) {
            # A pipe cannot be waited on everywhere: what came is all there
            # is. A paste's end comes in a later read, or the pipe's does.
            _ready.append_all(_decoder.flush());
        }
    }

    # Waits at most `timeout_ms` milliseconds for a clipboard reply, keeping
    # the other events that come meanwhile for `read`: the reply's text and
    # whether it was cut, or none when the time runs out first, or the
    # input is not a terminal or has ended.
    _read_reply(timeout_ms: int): (String, bool)? {
        var started = os.Instant.now();
        while (true) {
            # A while loop, not `for`: stable 0.10.1 cannot build a tuple
            # inside a range loop (pep-lang/pepper#75, fixed since).
            var index = _next;
            while (index < _ready.count) {
                if (_ready[index] is ClipboardReply(copied, truncated)) {
                    _ready.remove_at(index);
                    return Optional<(String, bool)>.Value((copied, truncated));
                }
                index += 1;
            }
            var left = timeout_ms as long - started.elapsed().milliseconds() as long;
            if (!_terminal || _ended || left <= 0) {
                return Optional<(String, bool)>.Empty;
            }
            var bytes = Array<u8>();
            var count = _term_read(bytes, left as int);
            _ready = _ready.split_off(_next);
            _next = 0;
            if (count < 0) {
                _ended = true;
                _ready.append_all(_decoder.flush());
            } else if (count > 0) {
                _ready.append_all(_decoder.feed(bytes));
            }
        }
        return Optional<(String, bool)>.Empty;
    }
}

## Reads key presses from standard input, as `InputReader` does; a mouse
## report is `Key.Unknown`, and a paste the keys its text types.
export struct KeyReader {
    var _input = InputReader();
    var _ready = Array<KeyEvent>();
    var _next: ulong = 0;

    ## Makes a reader of standard input.
    construct() {}

    ## Waits for the next key press.
    ##
    ## @returns the key, or none at the end of input
    read(): KeyEvent? {
        while (_next >= _ready.count) {
            var event = _input.read();
            if (event.is_empty()) {
                return Optional<KeyEvent>.Empty;
            }
            _ready = _keys([event.value()]);
            _next = 0;
        }
        _next += 1;
        return Optional<KeyEvent>.Value(_ready[_next - 1]);
    }
}

## What `LineReader.read_line` read.
[Value]
export enum LineInput {
    ## A line, without its line end.
    Line(text: String),
    ## Ctrl+C was pressed; the line was abandoned.
    Interrupted,
    ## The input ended: Ctrl+D on an empty line, or the end of a pipe or
    ## file.
    EndOfInput,
}

## Reads lines from standard input for a REPL or a prompt, with editing and
## history (see `LineEditor` for the keys) when standard input and output
## are a terminal, and plainly otherwise. While a `PasteMode` is on, a
## paste goes into the line whole, line ends and all, without submitting
## it.
##
## @example
##     import term;
##     import [LineInput] from term;
##
##     main(): int {
##         var reader = term.LineReader();
##         while (true) {
##             match (reader.read_line("> ")) {
##                 Line(text) => {
##                     print($"you typed {text}");
##                 }
##                 Interrupted => {}
##                 EndOfInput => {
##                     return 0;
##                 }
##             }
##         }
##     }
export struct LineReader {
    ## The editor; its `history` holds the lines read so far.
    var editor: LineEditor;
    var _input = InputReader();
    var _out = io.File.stdout();
    # Bytes read past the line returned, without a terminal.
    var _plain = Array<u8>();
    var _plain_ended = false;

    ## Makes a reader.
    ##
    ## @param history the history Up and Down recall, which each line read
    ##   is added to
    construct(history: History = History()) {
        editor = LineEditor(history);
    }

    ## Writes `prompt`, then reads one line.
    ##
    ## On a terminal, the line is edited in raw mode, which is on only while
    ## this runs, and added to the history when Enter submits it. Without
    ## one, `prompt` is written and a line is read up to "\n" (a "\r" before
    ## it is dropped); the last line need not end with one.
    ##
    ## @param prompt the text to show before the line
    ## @returns the line, `Interrupted` after Ctrl+C, or `EndOfInput` at the
    ##   end of input
    read_line(prompt: String): LineInput {
        if (!input_is_terminal() || !output_is_terminal()) {
            return _read_plain(prompt);
        }
        with (var raw = RawMode()) {
            editor.clear();
            _write(editor.render(prompt));
            while (true) {
                var event = _input.read();
                if (event.is_empty()) {
                    _write("\r\n");
                    return LineInput.EndOfInput;
                }
                var status = EditStatus.Editing;
                match (event.value()) {
                    Key(key) => {
                        status = editor.handle(key);
                    }
                    Mouse(mouse) => {}
                    Paste(pasted, truncated) => {
                        editor.paste(pasted);
                    }
                    ClipboardReply(copied, truncated) => {}
                }
                var terminal = size();
                var width = terminal.is_empty() ? 0 : terminal.value().columns;
                _write(editor.render(prompt, width));
                match (status) {
                    Editing => {}
                    Submitted => {
                        _write("\r\n");
                        return LineInput.Line(editor.text);
                    }
                    Interrupted => {
                        _write("^C\r\n");
                        return LineInput.Interrupted;
                    }
                    EndOfInput => {
                        _write("\r\n");
                        return LineInput.EndOfInput;
                    }
                }
            }
        }
        return LineInput.EndOfInput;
    }

    _write(text: String) {
        _out.write_all(text);
    }

    _read_plain(prompt: String): LineInput {
        _write(prompt);
        var input = io.File.stdin();
        while (true) {
            var end = _plain.find('\n');
            if (!end.is_empty() || _plain_ended) {
                var size = end.value_or(_plain.count);
                if (size == 0 && end.is_empty()) {
                    return LineInput.EndOfInput;
                }
                var rest = _plain.split_off(end.is_empty() ? size : size + 1);
                var line = _plain;
                _plain = rest;
                if (line.count > 0 && line[line.count - 1] == '\n') {
                    line.pop();
                }
                if (line.count > 0 && line[line.count - 1] == '\r') {
                    line.pop();
                }
                var decoded = text.Utf8.decode_lossy(line);
                editor.history.add(decoded);
                return LineInput.Line(decoded);
            }
            var read = input.read(_plain, 4096);
            _plain_ended = read.is_err() || read.value() == 0;
        }
        return LineInput.EndOfInput;
    }
}
