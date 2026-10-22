## Keys and the events beside them: `Key`, `KeyEvent`, `Event`, and the
## decoders `KeyDecoder` and `InputDecoder`, which turn the bytes a terminal
## sends in raw mode into key events, and mouse reports too. Decoding is
## pure: bytes in, events out, so it needs no terminal and works on bytes
## from anywhere.

import text;
import "mouse";

## Which key a `KeyEvent` is.
export enum Key {
    ## A character key; the event's `text` holds the character.
    Char,
    ## Enter (Return): carriage return or line feed.
    Enter,
    ## Tab; Shift+Tab sets `shift`.
    Tab,
    ## Backspace: DEL (127) or Ctrl+H (8).
    Backspace,
    ## Escape on its own.
    Escape,
    ## The up arrow.
    Up,
    ## The down arrow.
    Down,
    ## The left arrow.
    Left,
    ## The right arrow.
    Right,
    ## Home.
    Home,
    ## End.
    End,
    ## Page Up.
    PageUp,
    ## Page Down.
    PageDown,
    ## Insert.
    Insert,
    ## Delete (forward delete).
    Delete,
    ## A function key; the event's `number` says which, 1 to 12.
    Function,
    ## An escape sequence the decoder does not know, or a mouse report read
    ## as a key (see `InputDecoder`); programs usually ignore it.
    Unknown,
}

## One key press: the key, the character it typed, and the modifiers held.
##
## A control character arrives as its letter with `ctrl` set: Ctrl+A is
## `Key.Char` with `text` "a". Modifiers come from the terminal: Ctrl, Alt
## and Shift with the arrows, Home, End and the other editing keys, Alt with
## any key (the terminal sends Escape first), and Shift with Tab.
export struct KeyEvent {
    ## Which key.
    const key: Key;
    ## For `Key.Char`, the character typed, one code point (Ctrl+letter
    ## gives the letter in lower case); empty for the other keys.
    const text: String;
    ## For `Key.Function`, which one, 1 to 12; 0 for the other keys.
    const number: int;
    ## Whether Ctrl was held.
    const ctrl: bool;
    ## Whether Alt (Meta, Option) was held.
    const alt: bool;
    ## Whether Shift was held. A shifted character arrives as itself ("A"),
    ## with `shift` false.
    const shift: bool;

    ## Makes a key event.
    ##
    ## @param key which key
    ## @param text the character, for `Key.Char`
    ## @param number the function key's number, for `Key.Function`
    ## @param ctrl whether Ctrl was held
    ## @param alt whether Alt was held
    ## @param shift whether Shift was held
    construct(
        key: Key, text: String = "", number: int = 0, ctrl: bool = false, alt: bool = false, shift: bool = false
    ) {
        this.key = key;
        this.text = text;
        this.number = number;
        this.ctrl = ctrl;
        this.alt = alt;
        this.shift = shift;
    }

    # The same key with Alt held too.
    _with_alt(): KeyEvent {
        return KeyEvent(key, text, number, ctrl, true, shift);
    }

    ## Returns the key's name with its modifiers, as a key binding is
    ## written: "a", "Ctrl+a", "Alt+Left", "Ctrl+Shift+Up", "F5", "Enter".
    ##
    ## @returns the name
    to_string(): String {
        var name = "";
        if (ctrl) {
            name += "Ctrl+";
        }
        if (alt) {
            name += "Alt+";
        }
        if (shift) {
            name += "Shift+";
        }
        if (key == Key.Char) {
            name += text;
        } else if (key == Key.Function) {
            name += $"F{number}";
        } else {
            name += key.name();
        }
        return name;
    }
}

const ESCAPE: u8 = 27;

# Bracketed paste's end marker; its start is "Escape [ 200 ~".
const _PASTE_END = "\x1B[201~";

## One thing the user did, as `InputDecoder` and `InputReader` give it: a
## key press, a mouse report, or a paste.
[Value]
export enum Event {
    ## A key press.
    Key(key: KeyEvent),
    ## A mouse report, which arrives only while a `MouseMode` is on.
    Mouse(mouse: MouseEvent),
    ## Text pasted into the terminal, whole, which arrives only while a
    ## `PasteMode` is on. Line ends are "\n" (terminals send "\r"). When
    ## the paste was longer than the decoder's `paste_limit`, `text` holds
    ## its start and `truncated` is true.
    Paste(text: String, truncated: bool),
}

## Decodes the bytes a terminal sends in raw mode into `Event`s: key
## presses (see `KeyDecoder`), mouse reports, in xterm's SGR encoding
## (`ESC [ < b ; x ; y M`, or `m` for a release) and its older X10 one
## (`ESC [ M` and three bytes), and bracketed pastes (`ESC [ 200 ~`, the
## text, then `ESC [ 201 ~`).
##
## Feed it bytes as they arrive. A sequence split across reads is held
## until the rest comes, and a lone Escape is held until `flush`, as with
## `KeyDecoder`. A mouse report the decoder cannot read (a button past the
## third, a position of 0, a broken sequence) decodes as `Key.Unknown`;
## huge numbers are capped, never overflow.
##
## A paste is held until its end marker comes, however many reads it
## takes; `pasting` says one is under way. Past `paste_limit` bytes the
## rest is dropped. When the end marker never comes, `flush` gives back
## what was held as the keys it would have been without bracketing.
##
## @example
##     import term;
##     import [Event, MouseKind] from term;
##
##     var decoder = term.InputDecoder();
##     var events = decoder.feed("\x1B[<0;3;4Mx".bytes());
##     match (events[0]) {
##         Mouse(mouse) => assert(mouse.kind == MouseKind.Down && mouse.column == 2, "a click"),
##         else => panic("a mouse report"),
##     }
export struct InputDecoder {
    var _pending = Array<u8>();
    # Whether the last byte decoded was a carriage return, so a line feed
    # right after it ends the same line rather than another.
    var _after_return = false;
    # The paste under way: whether one is, its bytes so far, and whether
    # bytes past the limit were dropped.
    var _pasting = false;
    var _paste = Array<u8>();
    var _paste_truncated = false;

    ## The most bytes of one paste kept; the rest is dropped.
    const paste_limit: ulong;

    ## Makes a decoder.
    ##
    ## @param paste_limit the most bytes of one paste kept, 1 MiB unless
    ##   said
    construct(paste_limit: ulong = 1048576) {
        this.paste_limit = paste_limit;
    }

    ## Whether bytes are held that may begin a longer sequence, or a paste
    ## is under way, so a caller knows to wait and then `flush`.
    var has_pending: bool {
        get {
            return _pending.count > 0 || _pasting;
        }
    }

    ## Whether a paste has begun and its end has not come yet, so a caller
    ## knows to wait longer before calling `flush`.
    var pasting: bool {
        get {
            return _pasting;
        }
    }

    ## Adds `bytes` and returns the events they complete, in order. Bytes
    ## that may begin a longer sequence are held for the next call.
    ##
    ## @param bytes the bytes the terminal sent
    ## @returns the events, possibly none
    feed(bytes: u8[]): Event[] {
        _pending.append_all(bytes);
        return _drain(false);
    }

    ## Decodes the bytes held as they stand, since no more are coming: a
    ## lone Escape is the Escape key, Escape before a character is Alt with
    ## it, an incomplete UTF-8 character is U+FFFD, and a paste whose end
    ## never came is the keys its text would have been.
    ##
    ## @returns the events, possibly none
    flush(): Event[] {
        return _drain(true);
    }

    _drain(final: bool): Event[] {
        var events = Array<Event>();
        ulong start = 0;
        while (start < _pending.count || (final && _pasting)) {
            if (_pasting) {
                var end = _paste_end(start);
                var stop = end.value_or(_pending.count);
                var complete = !end.is_empty() && _marker_length(stop) == _PASTE_END.size;
                if (!complete && final) {
                    # No end is coming: what was held is typed keys after all.
                    var rest = _pending.split_off(start);
                    _pending = _paste;
                    _pending.append_all(rest);
                    _paste = Array<u8>();
                    _pasting = false;
                    _paste_truncated = false;
                    start = 0;
                    continue;
                }
                _add_paste(start, stop);
                if (!complete) {
                    start = stop;
                    break;
                }
                start = stop + _PASTE_END.size;
                events.append(_take_paste());
                continue;
            }
            var (size, event) = _decode(start, final);
            if (size == 0) {
                break;
            }
            var line_feed = _pending[start] == '\n';
            # A paste's start marker sets `_pasting`, and is no event itself.
            if (!_pasting && !(line_feed && _after_return)) {
                events.append(event);
            }
            _after_return = _pending[start] == '\r';
            start += size;
        }
        _pending = _pending.split_off(start);
        return events;
    }

    # Where the paste's end marker begins at or after `from`, or where the
    # bytes held end with what may be its start; none when neither.
    _paste_end(from: ulong): ulong? {
        var at = from;
        while (at < _pending.count) {
            var found = _pending.slice(at, _pending.count).find(ESCAPE);
            if (found.is_empty()) {
                break;
            }
            at += found.value();
            var length = _marker_length(at);
            if (length == _PASTE_END.size || at + length == _pending.count) {
                return Optional<ulong>.Value(at);
            }
            at += 1;
        }
        return Optional<ulong>.Empty;
    }

    # How many bytes from `at` match the start of the paste's end marker.
    _marker_length(at: ulong): ulong {
        ulong length = 0;
        while (length < _PASTE_END.size
            && at + length < _pending.count
            && _pending[at + length] == _PASTE_END.byte_at(length)) {
            length += 1;
        }
        return length;
    }

    # Adds the bytes from `from` to `to` to the paste, up to the limit.
    _add_paste(from: ulong, to: ulong) {
        var room = paste_limit > _paste.count ? paste_limit - _paste.count : 0;
        var take = to - from < room ? to - from : room;
        _paste.append_all(_pending.slice(from, from + take).to_array());
        _paste_truncated = _paste_truncated || take < to - from;
    }

    # The finished paste's event; the decoder goes back to keys.
    _take_paste(): Event {
        if (_paste_truncated) {
            _paste.truncate(_utf8_whole(_paste));
        }
        var pasted = text.Utf8.decode_lossy(_paste).replace("\r\n", "\n").replace("\r", "\n");
        var event = Event.Paste(pasted, _paste_truncated);
        _paste = Array<u8>();
        _pasting = false;
        _paste_truncated = false;
        _after_return = false;
        return event;
    }

    # Decodes the event whose bytes start at `start`: the number of bytes
    # it takes and the event, or 0 when more bytes are needed to tell.
    _decode(start: ulong, final: bool): (ulong, Event) {
        if (_pending[start] == ESCAPE) {
            return _decode_escape(start, final);
        }
        var (size, key) = _decode_key(start, final);
        return (size, Event.Key(key));
    }

    # Decodes a key that is not an escape sequence.
    _decode_key(start: ulong, final: bool): (ulong, KeyEvent) {
        var first = _pending[start];
        if (first >= 128) {
            return _decode_utf8(start, final);
        }
        return (1, _control_or_char(first));
    }

    _decode_escape(start: ulong, final: bool): (ulong, Event) {
        var unknown = Event.Key(KeyEvent(Key.Unknown));
        if (start + 1 == _pending.count) {
            return final ? (1, Event.Key(KeyEvent(Key.Escape))) : (0, unknown);
        }
        var second = _pending[start + 1];
        if (second == '[' || second == 'O') {
            var sequence = _decode_sequence(start + 2, second == 'O');
            if (!sequence.is_empty()) {
                var (size, event) = sequence.value();
                return (size + 2, event);
            }
            if (!final) {
                return (0, unknown);
            }
            # "Escape [" with nothing after it: Alt with '['.
        }
        if (second == ESCAPE) {
            return (1, Event.Key(KeyEvent(Key.Escape)));
        }
        # Escape then a key: that key with Alt.
        var (size, key) = _decode_key(start + 1, final);
        if (size == 0) {
            return (0, unknown);
        }
        return (size + 1, Event.Key(key._with_alt()));
    }

    # Decodes a CSI sequence ("Escape [", `ss3` false) or an SS3 one
    # ("Escape O"), whose parameters start at `start`: the bytes after the
    # introducer it takes, or none when it is not complete yet.
    _decode_sequence(start: ulong, ss3: bool): (ulong, Event)? {
        # SGR mouse reports start their parameters with '<'.
        var sgr = !ss3 && start < _pending.count && _pending[start] == '<';
        var parameters = Array<int>();
        var current = 0;
        var has_digits = false;
        var index = start;
        while (index < _pending.count) {
            var c = _pending[index];
            if (c >= '0' && c <= '9') {
                # Past any real key's number or position: stop growing, so it cannot overflow.
                if (current < 100000) {
                    current = current * 10 + (c - '0') as int;
                }
                has_digits = true;
            } else if (c == ';') {
                parameters.append(current);
                current = 0;
                has_digits = false;
            } else if (c >= 64 && c <= 126) {
                if (has_digits || parameters.count > 0) {
                    parameters.append(current);
                }
                var size = index - start + 1;
                if (sgr) {
                    var mouse = Optional<MouseEvent>.Empty;
                    if ((c == 'M' || c == 'm') && parameters.count == 3) {
                        mouse = _mouse_from_code(parameters[0], parameters[1], parameters[2], c == 'm');
                    }
                    return Optional<(ulong, Event)>.Value((size, _mouse_or_unknown(mouse)));
                }
                if (c == 'M' && !ss3 && index == start) {
                    # X10: the button code, column and row follow as bytes, each plus 32.
                    if (index + 3 >= _pending.count) {
                        return Optional<(ulong, Event)>.Empty;
                    }
                    var b = _pending[index + 1] as int - 32;
                    var x = _pending[index + 2] as int - 32;
                    var y = _pending[index + 3] as int - 32;
                    return Optional<(ulong, Event)>.Value(
                        (size + 3, _mouse_or_unknown(_mouse_from_code(b, x, y, false)))
                    );
                }
                if (c == '~' && !ss3 && parameters.count == 1 && parameters[0] == 200) {
                    _pasting = true;  # a paste's start marker
                }
                return Optional<(ulong, Event)>.Value((size, Event.Key(_sequence_key(c, parameters, ss3))));
            } else if (c < 32 || c > 63) {
                # Not a parameter byte: a broken sequence. Take what came
                # before it, which may be nothing.
                return Optional<(ulong, Event)>.Value((index - start, Event.Key(KeyEvent(Key.Unknown))));
            }
            index += 1;
        }
        return Optional<(ulong, Event)>.Empty;
    }

    _decode_utf8(start: ulong, final: bool): (ulong, KeyEvent) {
        var first = _pending[start];
        ulong size = first >= 240 ? 4 : (first >= 224 ? 3 : (first >= 192 ? 2 : 1));
        ulong have = 1;
        while (have < size && start + have < _pending.count && (_pending[start + have] & 192) == 128) {
            have += 1;
        }
        var complete = have == size;
        if (!complete && start + have == _pending.count && !final) {
            return (0, KeyEvent(Key.Unknown));
        }
        # A stray or broken sequence decodes to U+FFFD, one byte at a time.
        var taken = complete ? size : 1;
        var bytes = _pending.slice(start, start + taken).to_array();
        return (taken, KeyEvent(Key.Char, text.Utf8.decode_lossy(bytes)));
    }
}

_mouse_or_unknown(mouse: MouseEvent?): Event {
    return mouse.is_empty() ? Event.Key(KeyEvent(Key.Unknown)) : Event.Mouse(mouse.value());
}

# The length of the longest start of `bytes` that ends with a whole UTF-8
# character, for a paste cut at its limit.
_utf8_whole(bytes: u8[]): ulong {
    var start = bytes.count;
    while (start > 0 && (bytes[start - 1] & 192) == 128) {
        start -= 1;
    }
    if (start == 0) {
        return bytes.count;
    }
    var lead = bytes[start - 1];
    ulong size = lead >= 240 ? 4 : (lead >= 224 ? 3 : (lead >= 192 ? 2 : 1));
    return bytes.count - (start - 1) >= size ? bytes.count : start - 1;
}

# The keys `events` are, for the readers of keys alone: a mouse report is
# `Key.Unknown`, and a paste the keys its text types, as before either was
# decoded.
_keys(events: Event[]): KeyEvent[] {
    var keys = Array<KeyEvent>();
    for (var event in events) {
        match (event) {
            Key(key) => {
                keys.append(key);
            }
            Mouse(mouse) => {
                keys.append(KeyEvent(Key.Unknown));
            }
            Paste(pasted, truncated) => {
                var decoder = InputDecoder();
                keys.append_all(_keys(decoder.feed(pasted.bytes())));
                keys.append_all(_keys(decoder.flush()));
            }
        }
    }
    return keys;
}

## Decodes the bytes a terminal sends in raw mode into `KeyEvent`s: UTF-8
## characters, control characters, and the escape sequences of xterm and
## its kin (VT100, the Linux console, Windows' virtual terminal input) for
## the arrows, Home, End, Insert, Delete, Page Up and Down, and F1 to F12,
## with their modifiers. A mouse report is one `Key.Unknown`, and a paste
## the keys its text types; use `InputDecoder` to read them as they are.
##
## Feed it bytes as they arrive. A sequence split across reads is held
## until the rest comes. A lone Escape looks like the start of a sequence,
## so it is held too: when no more bytes arrive soon (a few tens of
## milliseconds), call `flush` to decode it as the Escape key.
##
## @example
##     import term;
##
##     var decoder = term.KeyDecoder();
##     var events = decoder.feed("\x1B[1;5Ax".bytes());
##     assert(events[0].to_string() == "Ctrl+Up", "an arrow with Ctrl");
##     assert(events[1].text == "x", "a character");
export struct KeyDecoder {
    var _input = InputDecoder();

    ## Whether bytes are held that may begin a longer sequence, so a caller
    ## knows to wait briefly and then `flush`.
    var has_pending: bool {
        get {
            return _input.has_pending;
        }
    }

    ## Adds `bytes` and returns the key events they complete, in order.
    ## Bytes that may begin a longer sequence are held for the next call.
    ##
    ## @param bytes the bytes the terminal sent
    ## @returns the events, possibly none
    feed(bytes: u8[]): KeyEvent[] {
        return _keys(_input.feed(bytes));
    }

    ## Decodes the bytes held as they stand, since no more are coming: a
    ## lone Escape is the Escape key, Escape before a character is Alt with
    ## it, and an incomplete UTF-8 character is U+FFFD.
    ##
    ## @returns the events, possibly none
    flush(): KeyEvent[] {
        return _keys(_input.flush());
    }
}

# The key a single byte below 128 is.
_control_or_char(byte: u8): KeyEvent {
    if (byte == '\r' || byte == '\n') {
        return KeyEvent(Key.Enter);
    }
    if (byte == '\t') {
        return KeyEvent(Key.Tab);
    }
    if (byte == 127 || byte == 8) {
        return KeyEvent(Key.Backspace);
    }
    if (byte == 0) {
        return KeyEvent(Key.Char, " ", ctrl = true);
    }
    if (byte < 27) {
        return KeyEvent(Key.Char, _one_byte(byte + 96), ctrl = true);
    }
    if (byte < 32) {
        # 28 to 31: Ctrl with \ ] ^ _.
        return KeyEvent(Key.Char, _one_byte(byte + 64), ctrl = true);
    }
    return KeyEvent(Key.Char, _one_byte(byte));
}

_one_byte(byte: u8): String {
    var bytes = Array<u8>();
    bytes.append(byte);
    return text.Utf8.decode_lossy(bytes);
}

# The key a complete CSI or SS3 sequence names: its final byte `final` and
# its numeric parameters. A second parameter is xterm's modifier code: 1
# plus Shift 1, Alt 2 and Ctrl 4.
_sequence_key(final: u8, parameters: int[], ss3: bool): KeyEvent {
    var modifiers = parameters.count >= 2 ? parameters[1] - 1 : 0;
    if (modifiers < 0) {
        modifiers = 0;
    }
    var key = Key.Unknown;
    var number = 0;
    if (final == 'A') {
        key = Key.Up;
    } else if (final == 'B') {
        key = Key.Down;
    } else if (final == 'C') {
        key = Key.Right;
    } else if (final == 'D') {
        key = Key.Left;
    } else if (final == 'H') {
        key = Key.Home;
    } else if (final == 'F') {
        key = Key.End;
    } else if (final == 'M' && ss3) {
        key = Key.Enter;  # keypad Enter
    } else if (final == 'Z') {
        key = Key.Tab;
        modifiers = modifiers | 1;
    } else if (final >= 'P' && final <= 'S') {
        key = Key.Function;
        number = (final - 'P') as int + 1;
    } else if (final == '~' && parameters.count > 0) {
        (key, number) = _tilde_key(parameters[0]);
    }
    if (key == Key.Unknown) {
        # Its parameters are not modifiers (a mouse report's are positions).
        return KeyEvent(key);
    }
    return KeyEvent(
        key, number = number, ctrl = (modifiers & 4) != 0, alt = (modifiers & 2) != 0, shift = (modifiers & 1) != 0
    );
}

# The key of "Escape [ code ~" (VT220 and xterm), and its function key
# number.
_tilde_key(code: int): (Key, int) {
    return match (code) {
        1, 7 => (Key.Home, 0),
        2 => (Key.Insert, 0),
        3 => (Key.Delete, 0),
        4, 8 => (Key.End, 0),
        5 => (Key.PageUp, 0),
        6 => (Key.PageDown, 0),
        11..16 => (Key.Function, code - 10),
        17..22 => (Key.Function, code - 11),
        23..25 => (Key.Function, code - 12),
        else => (Key.Unknown, 0),
    };
}
