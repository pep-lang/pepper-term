## Line editing: `History`, and `LineEditor`, which applies key events to a
## line of text and renders it, readline style. Editing is pure: key events
## in, the edited line and the bytes that draw it out, so it needs no
## terminal. `LineReader` (in `terminal`) runs it against the real one.

import "keys";

## The lines entered so far, oldest first, for Up and Down to recall.
export struct History {
    ## The lines, oldest first.
    var entries = Array<String>();
    ## The most lines kept; adding past it drops the oldest.
    var limit: ulong;

    ## Makes an empty history.
    ##
    ## @param limit the most lines kept
    construct(limit: ulong = 1000) {
        this.limit = limit;
    }

    ## Adds `line` as the newest entry, unless it is empty or the same as
    ## the newest entry already there. Drops the oldest past `limit`.
    ##
    ## @param line the line entered
    add(line: String) {
        if (line.is_empty || (entries.count > 0 && entries.last() == line)) {
            return;
        }
        entries.append(line);
        if (entries.count > limit) {
            entries = entries.split_off(entries.count - limit);
        }
    }
}

## Where a line being edited stands after a key.
export enum EditStatus {
    ## Still being edited.
    Editing,
    ## Enter was pressed: the line is done, and in the history.
    Submitted,
    ## Ctrl+C was pressed: the line is abandoned.
    Interrupted,
    ## Ctrl+D was pressed on an empty line: the end of input.
    EndOfInput,
}

## A line being edited: the text, the cursor, and the history that Up and
## Down move through. `handle` applies one key; `render` gives the bytes
## that redraw the line.
##
## The keys are readline's (Emacs mode):
##
## - characters insert at the cursor
## - Left, Right, Ctrl+B, Ctrl+F move one character; Ctrl or Alt with
##   Left and Right, and Alt+B and Alt+F, move one word
## - Home, End, Ctrl+A, Ctrl+E go to the start and the end
## - Backspace and Ctrl+H delete before the cursor, Delete and Ctrl+D at it
##   (Ctrl+D on an empty line ends input)
## - Ctrl+W and Alt+Backspace delete the word before the cursor, Ctrl+U
##   everything before it, Ctrl+K everything from it
## - Up, Down, Ctrl+P, Ctrl+N recall older and newer history entries
## - Enter submits the line, Ctrl+C abandons it
##
## @example
##     import term;
##
##     var editor = term.LineEditor();
##     for (var key in term.KeyDecoder().feed("helo\x1B[Dl\r".bytes())) {
##         editor.handle(key);
##     }
##     assert(editor.text == "hello", "Left, then insert");
##     assert(editor.history.entries[0] == "hello", "Enter records it");
export struct LineEditor {
    ## The history Up and Down move through, and Enter adds to.
    var history: History;
    # The line, one code point per element.
    var _characters = Array<String>();
    var _cursor: ulong = 0;
    # The history entry shown, or `history.entries.count` for the line
    # being written, which `_draft` keeps while an older one is shown.
    var _recalled: ulong = 0;
    var _draft = "";

    ## Makes an editor with an empty line.
    ##
    ## @param history the history to recall from and add to
    construct(history: History = History()) {
        this.history = history;
        _recalled = history.entries.count;
    }

    ## The text of the line.
    var text: String {
        get {
            return "".join(_characters);
        }
    }

    ## The cursor's position, in code points from the start of the line.
    var cursor: ulong {
        get {
            return _cursor;
        }
    }

    ## Empties the line for the next one, keeping the history.
    clear() {
        _set("");
        _recalled = history.entries.count;
        _draft = "";
    }

    ## Applies `key` to the line.
    ##
    ## @param key the key pressed
    ## @returns where the line stands: `Submitted` after Enter (the line is
    ##   added to the history), `Interrupted` after Ctrl+C, `EndOfInput`
    ##   after Ctrl+D on an empty line, and `Editing` otherwise
    handle(key: KeyEvent): EditStatus {
        var word = key.ctrl || key.alt;
        var letter = key.key == Key.Char && (key.ctrl || key.alt) ? key.text : "";
        if (key.key == Key.Enter) {
            history.add(text);
            _recalled = history.entries.count;
            return EditStatus.Submitted;
        }
        if (key.ctrl && letter == "c") {
            return EditStatus.Interrupted;
        }
        if (key.ctrl && letter == "d" && _characters.count == 0) {
            return EditStatus.EndOfInput;
        }
        if (key.key == Key.Char && !key.ctrl && !key.alt) {
            _characters.insert(_cursor, key.text);
            _cursor += 1;
        } else if (key.key == Key.Left || (key.ctrl && letter == "b")) {
            _cursor = word && key.key == Key.Left ? _word_start() : _back(1);
        } else if (key.key == Key.Right || (key.ctrl && letter == "f")) {
            _cursor = word && key.key == Key.Right ? _word_end() : _cursor + (_cursor < _characters.count ? 1 : 0);
        } else if (key.alt && letter == "b") {
            _cursor = _word_start();
        } else if (key.alt && letter == "f") {
            _cursor = _word_end();
        } else if (key.key == Key.Home || (key.ctrl && letter == "a")) {
            _cursor = 0;
        } else if (key.key == Key.End || (key.ctrl && letter == "e")) {
            _cursor = _characters.count;
        } else if (key.key == Key.Backspace && key.alt) {
            _delete(_word_start(), _cursor);
        } else if (key.key == Key.Backspace || (key.ctrl && letter == "h")) {
            _delete(_back(1), _cursor);
        } else if (key.key == Key.Delete || (key.ctrl && letter == "d")) {
            _delete(_cursor, _cursor + (_cursor < _characters.count ? 1 : 0));
        } else if (key.ctrl && letter == "w") {
            _delete(_word_start(), _cursor);
        } else if (key.ctrl && letter == "u") {
            _delete(0, _cursor);
        } else if (key.ctrl && letter == "k") {
            _delete(_cursor, _characters.count);
        } else if (key.key == Key.Up || (key.ctrl && letter == "p")) {
            _recall(-1);
        } else if (key.key == Key.Down || (key.ctrl && letter == "n")) {
            _recall(1);
        }
        return EditStatus.Editing;
    }

    ## Inserts `text` at the cursor, as `Event.Paste` gives it: line ends
    ## and all, without submitting the line, and without touching the
    ## history.
    ##
    ## @param text the text pasted
    paste(text: String) {
        var tail = _characters.split_off(_cursor);
        for (var c in text) {
            _characters.append(c);
        }
        _cursor = _characters.count;
        _characters.append_all(tail);
    }

    ## Returns the bytes that redraw the line on the terminal row the cursor
    ## is on: a carriage return, `prompt`, the text, an erase to the end of
    ## the row, and the move back to the cursor.
    ##
    ## A line wider than `width` columns scrolls sideways to keep the cursor
    ## in view. Each code point counts as one column. A line end (from a
    ## paste) shows as "⏎", and another control character as "\u{FFFD}", so
    ## pasted text cannot move the cursor or send the terminal sequences.
    ##
    ## @param prompt the text shown before the line
    ## @param width the terminal's width in columns; 0 when unknown, which
    ##   never scrolls
    ## @returns the text to write
    render(prompt: String, width: ulong = 0): String {
        # shortcut: one column per code point; wide (CJK, emoji) and
        # combining characters misplace the cursor. Upgrade with a
        # wcwidth table when someone needs them.
        ulong first = 0;
        var last = _characters.count;
        var shown_prompt = _visible_length(prompt);
        if (width > 0 && shown_prompt + _characters.count + 1 > width) {
            var room = width > shown_prompt + 1 ? width - shown_prompt - 1 : 1;
            first = _cursor > room ? _cursor - room : 0;
            last = first + room < _characters.count ? first + room : _characters.count;
        }
        var shown = "".join(_characters.slice(first, last).iterate().map((c) => _shown(c)).to_array());
        var out = $"\r{prompt}{shown}\x1B[K";
        var back = last - _cursor;
        if (back > 0) {
            out += $"\x1B[{back}D";
        }
        return out;
    }

    _set(line: String) {
        _characters = Array<String>();
        for (var c in line) {
            _characters.append(c);
        }
        _cursor = _characters.count;
    }

    _back(count: ulong): ulong {
        return _cursor > count ? _cursor - count : 0;
    }

    _delete(from: ulong, to: ulong) {
        var tail = _characters.split_off(to);
        _characters.truncate(from);
        _characters.append_all(tail);
        _cursor = from;
    }

    # The start of the word before the cursor: back over spaces, then over
    # the word.
    _word_start(): ulong {
        var at = _cursor;
        while (at > 0 && _characters[at - 1] == " ") {
            at -= 1;
        }
        while (at > 0 && _characters[at - 1] != " ") {
            at -= 1;
        }
        return at;
    }

    # The end of the word at or after the cursor.
    _word_end(): ulong {
        var at = _cursor;
        var count = _characters.count;
        while (at < count && _characters[at] == " ") {
            at += 1;
        }
        while (at < count && _characters[at] != " ") {
            at += 1;
        }
        return at;
    }

    # Shows the entry `step` newer (1) or older (-1) than the one shown.
    _recall(step: int) {
        var count = history.entries.count;
        if (_recalled > count) {
            # The history was changed from outside.
            _recalled = count;
        }
        if (step < 0 && _recalled == 0) {
            return;
        }
        if (step > 0 && _recalled >= count) {
            return;
        }
        if (_recalled == count) {
            _draft = text;
        }
        _recalled = step < 0 ? _recalled - 1 : _recalled + 1;
        _set(_recalled == count ? _draft : history.entries[_recalled]);
    }
}

# How the line's character `c` shows: control characters, which only a
# paste puts in, as one harmless column.
_shown(c: String): String {
    var byte = c.byte_at(0);
    if (byte == '\n') {
        return "⏎";
    }
    # C0, DEL, and C1 (U+0080 to U+009F, which some terminals obey too).
    var control = byte < 32 || byte == 127 || (byte == 194 && c.byte_at(1) < 160);
    return control ? "\u{FFFD}" : c;
}

# The columns `text` takes on screen: its code points, without the CSI
# escape sequences ("Escape [ ... final") that color it.
_visible_length(text: String): ulong {
    ulong count = 0;
    var in_sequence = false;
    var after_escape = false;
    for (var c in text) {
        if (after_escape) {
            after_escape = false;
            in_sequence = c == "[";
            if (!in_sequence) {
                count += 1;
            }
        } else if (in_sequence) {
            var byte = c.byte_at(0);
            in_sequence = byte < 64 || byte > 126;
        } else if (c == "\x1B") {
            after_escape = true;
        } else {
            count += 1;
        }
    }
    return count;
}
