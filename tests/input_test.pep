# Input events beside keys: mouse reports (SGR and X10 bytes, and Windows
# console records) and bracketed pastes in, events out.

import term;
import [EditStatus, Event, InputDecoder, KeyDecoder, LineEditor, MouseButton, MouseEvent, MouseKind] from term;
import text;

# The events `input` decodes to, as text, flushed at the end: a key is
# "key " and its name, a paste "paste " and its text in brackets ("cut"
# when truncated).
describe(events: Event[]): String {
    var parts = Array<String>();
    for (var event in events) {
        match (event) {
            Key(key) => {
                parts.append($"key {key}");
            }
            Mouse(mouse) => {
                parts.append(mouse.to_string());
            }
            Paste(pasted, truncated) => {
                parts.append(truncated ? $"paste [{pasted}] cut" : $"paste [{pasted}]");
            }
        }
    }
    return ",".join(parts);
}

decoded(input: String): String {
    var decoder = InputDecoder();
    var events = decoder.feed(input.bytes());
    events.append_all(decoder.flush());
    return describe(events);
}

# The X10 report of button code `code` at the one-based `column` and `row`.
x10(code: int, column: int, row: int): String {
    var bytes = "\x1B[M".bytes();
    bytes.append((code + 32) as u8);
    bytes.append((column + 32) as u8);
    bytes.append((row + 32) as u8);
    return text.Utf8.decode_lossy(bytes);
}

[Test]
decodes_sgr_presses_and_releases() {
    expect_equal(decoded("\x1B[<0;3;4M\x1B[<0;3;4m"), "Left Down at 2,3,Left Up at 2,3");
    expect_equal(decoded("\x1B[<1;1;1M\x1B[<2;80;24m"), "Middle Down at 0,0,Right Up at 79,23");
}

[Test]
decodes_sgr_drags_moves_and_the_wheel() {
    expect_equal(decoded("\x1B[<32;5;6M\x1B[<34;5;7M\x1B[<35;9;9M"), "Left Drag at 4,5,Right Drag at 4,6,Moved at 8,8");
    expect_equal(
        decoded("\x1B[<64;1;2M\x1B[<65;1;2M\x1B[<66;1;2M\x1B[<67;1;2M"),
        "ScrollUp at 0,1,ScrollDown at 0,1,ScrollLeft at 0,1,ScrollRight at 0,1"
    );
}

[Test]
decodes_sgr_modifiers() {
    expect_equal(
        decoded("\x1B[<4;1;1M\x1B[<8;1;1M\x1B[<16;1;1M"),
        "Shift+Left Down at 0,0,Alt+Left Down at 0,0,Ctrl+Left Down at 0,0"
    );
    expect_equal(decoded("\x1B[<28;2;2M\x1B[<81;3;3M"), "Ctrl+Alt+Shift+Left Down at 1,1,Ctrl+ScrollDown at 2,2");
}

[Test]
decodes_x10_reports() {
    expect_equal(decoded(x10(0, 3, 4) + x10(3, 3, 4)), "Left Down at 2,3,Up at 2,3");
    expect_equal(
        decoded(x10(34, 10, 1) + x10(65, 1, 1) + x10(16 + 1, 2, 2)),
        "Right Drag at 9,0,ScrollDown at 0,0,Ctrl+Middle Down at 1,1"
    );
}

[Test]
joins_reports_split_across_reads() {
    var decoder = InputDecoder();
    var report = "\x1B[<0;12;34M".bytes();
    var events = Array<Event>();
    for (var byte in report) {
        var one = Array<u8>();
        one.append(byte);
        events.append_all(decoder.feed(one));
    }
    expect_equal(describe(events), "Left Down at 11,33");
    expect_false(decoder.has_pending);
    # X10's three bytes, split too.
    expect_equal(decoder.feed("\x1B[M".bytes()).count, 0);
    expect_equal(decoder.feed(" !".bytes()).count, 0);
    expect_equal(describe(decoder.feed("!x".bytes())), "Left Down at 0,0,key x");
}

[Test]
keeps_keys_between_reports() {
    expect_equal(decoded("a\x1B[<0;1;1M\x1B[Ab"), "key a,Left Down at 0,0,key Up,key b");
}

[Test]
skips_malformed_reports() {
    # Too few or too many numbers, a position of 0, a button past the third,
    # another final byte: each is one unknown key, and decoding goes on.
    expect_equal(
        decoded("\x1B[<0;1M\x1B[<0;1;1;1M\x1B[<0;0;5M\x1B[<128;1;1M\x1B[<0;1;1Ax"),
        "key Unknown,key Unknown,key Unknown,key Unknown,key Unknown,key x"
    );
    expect_equal(decoded(x10(0, -32, 1) + "y"), "key Unknown,key y");
}

[Test]
caps_huge_numbers() {
    var events = InputDecoder().feed("\x1B[<0;99999999999999999999;3M".bytes());
    expect_equal(events.count, 1);
    match (events[0]) {
        Mouse(mouse) => {
            expect_true(mouse.column < 1000000);
            expect_equal(mouse.row, 2);
        }
        else => {
            expect_true(false);
        }
    }
    expect_equal(decoded("\x1B[<99999999999999999999;1;1M"), "key Unknown");
}

[Test]
reads_reports_as_unknown_keys() {
    var keys = term.KeyDecoder().feed("\x1B[<0;3;4Mq".bytes());
    expect_equal(keys.count, 2);
    expect_equal(keys[0].to_string(), "Unknown");
    expect_equal(keys[1].text, "q");
}

# The events a Windows record decodes to, as text.
recorded(buttons: uint, previous: uint, controls: uint, flags: uint, tracking: int): String {
    var parts = Array<String>();
    for (var event in term._mouse_from_record(buttons, previous, controls, flags, 4, 7, tracking)) {
        parts.append(event.to_string());
    }
    return ",".join(parts);
}

[Test]
translates_windows_presses_and_releases() {
    expect_equal(recorded(1, 0, 0, 0, 1000), "Left Down at 4,7");
    expect_equal(recorded(0, 1, 0, 0, 1000), "Left Up at 4,7");
    expect_equal(recorded(2, 0, 0, 0, 1000), "Right Down at 4,7");
    expect_equal(recorded(4, 0, 0, 0, 1000), "Middle Down at 4,7");
    expect_equal(recorded(3, 1, 0, 0, 1000), "Right Down at 4,7");
    expect_equal(recorded(2, 1, 0, 0, 1000), "Left Up at 4,7,Right Down at 4,7");
    expect_equal(recorded(1, 0, 0, 2, 1000), "Left Down at 4,7");  # a double click
}

[Test]
translates_windows_modifiers() {
    # LEFT_CTRL, RIGHT_ALT and SHIFT, with NUMLOCK_ON (32), which is not one.
    expect_equal(recorded(1, 0, 8 | 1 | 16 | 32, 0, 1000), "Ctrl+Alt+Shift+Left Down at 4,7");
    expect_equal(recorded(1, 0, 4, 0, 1000), "Ctrl+Left Down at 4,7");
    expect_equal(recorded(1, 0, 2, 0, 1000), "Alt+Left Down at 4,7");
}

[Test]
translates_windows_wheels() {
    # The high word is the signed turn: 120 one way, -120 the other.
    expect_equal(recorded(120 << 16, 0, 0, 4, 1000), "ScrollUp at 4,7");
    expect_equal(recorded(4294901760 - (119 << 16), 0, 0, 4, 1000), "ScrollDown at 4,7");
    expect_equal(recorded(120 << 16, 0, 0, 8, 1000), "ScrollRight at 4,7");
    expect_equal(recorded(4294901760 - (119 << 16), 0, 0, 8, 1000), "ScrollLeft at 4,7");
}

[Test]
translates_windows_moves_as_tracking_asks() {
    # MOUSE_MOVED: with no button held, kept only for 1003; with one, not for 1000.
    expect_equal(recorded(0, 0, 0, 1, 1000), "");
    expect_equal(recorded(0, 0, 0, 1, 1002), "");
    expect_equal(recorded(0, 0, 0, 1, 1003), "Moved at 4,7");
    expect_equal(recorded(1, 1, 0, 1, 1000), "");
    expect_equal(recorded(1, 1, 0, 1, 1002), "Left Drag at 4,7");
    expect_equal(recorded(2, 2, 0, 1, 1003), "Right Drag at 4,7");
}

[Test]
encodes_windows_events_as_the_reports_decoded() {
    # Windows' records reach the decoder as SGR reports.
    var events = [
        MouseEvent(MouseKind.Down, MouseButton.Left, 0, 0),
        MouseEvent(MouseKind.Up, MouseButton.Right, 79, 23, ctrl = true),
        MouseEvent(MouseKind.Drag, MouseButton.Middle, 5, 6, alt = true),
        MouseEvent(MouseKind.Moved, MouseButton.None, 7, 8, shift = true),
        MouseEvent(MouseKind.ScrollUp),
        MouseEvent(MouseKind.ScrollDown),
        MouseEvent(MouseKind.ScrollLeft),
        MouseEvent(MouseKind.ScrollRight, column = 3, row = 4),
    ];
    for (var event in events) {
        expect_equal(decoded(event._sgr()), event.to_string());
    }
}

const START = "\x1B[200~";
const END = "\x1B[201~";

[Test]
decodes_a_paste_as_one_event() {
    expect_equal(decoded("a" + START + "hello world" + END + "b"), "key a,paste [hello world],key b");
    expect_equal(decoded(START + END), "paste []");
    expect_equal(decoded(START + "é€😀" + END), "paste [é€😀]");
}

[Test]
gives_line_ends_as_line_feeds() {
    expect_equal(decoded(START + "one\rtwo\r\nthree\nfour" + END), "paste [one\ntwo\nthree\nfour]");
    # A line feed after the paste is a key again, not the end of its "\r".
    expect_equal(decoded(START + "x\r" + END + "\n"), "paste [x\n],key Enter");
}

[Test]
keeps_escape_bytes_inside_a_paste() {
    var inside = "\x1B[A\x1B[20\x1B[201\x1B[200~\x1B";
    expect_equal(decoded(START + inside + END + "z"), $"paste [{inside}],key z");
}

[Test]
joins_a_paste_split_across_reads() {
    var decoder = InputDecoder();
    var events = Array<Event>();
    for (var byte in (START + "ab\rc" + END + "q").bytes()) {
        var one = Array<u8>();
        one.append(byte);
        events.append_all(decoder.feed(one));
    }
    expect_equal(describe(events), "paste [ab\nc],key q");
    expect_false(decoder.pasting);
    expect_false(decoder.has_pending);
}

[Test]
gives_back_an_unterminated_paste_as_keys() {
    var decoder = InputDecoder();
    expect_equal(decoder.feed((START + "ab\r\x1B[2").bytes()).count, 0);
    expect_true(decoder.pasting);
    expect_true(decoder.has_pending);
    expect_equal(describe(decoder.flush()), "key a,key b,key Enter,key Alt+[,key 2");
    expect_false(decoder.pasting);
    expect_false(decoder.has_pending);
    # Decoding goes on as keys.
    expect_equal(describe(decoder.feed("\x1B[A".bytes())), "key Up");
    # Ended by the end of input before anything came.
    expect_equal(decoded(START), "");
}

[Test]
cuts_a_paste_at_its_limit() {
    var decoder = InputDecoder(paste_limit = 4);
    expect_equal(describe(decoder.feed((START + "abcdef" + END + "x").bytes())), "paste [abcd] cut,key x");
    # Across reads, and never in the middle of a character.
    expect_equal(decoder.feed((START + "ab").bytes()).count, 0);
    expect_equal(describe(decoder.feed(("cé" + END).bytes())), "paste [abc] cut");
    expect_equal(describe(decoder.feed((START + "abcd" + END).bytes())), "paste [abcd]");
    expect_equal(InputDecoder().paste_limit, 1048576);
}

[Test]
types_a_paste_for_the_readers_of_keys() {
    var parts = Array<String>();
    for (var key in KeyDecoder().feed((START + "a\rb" + END).bytes())) {
        parts.append(key.to_string());
    }
    expect_equal(",".join(parts), "a,Enter,b");
}

[Test]
pastes_into_a_line_without_submitting_it() {
    var editor = LineEditor();
    for (var key in KeyDecoder().feed("ac\x1B[D".bytes())) {
        editor.handle(key);
    }
    editor.paste("1\n2\x1B[31m");
    expect_equal(editor.text, "a1\n2\x1B[31mc");
    expect_equal(editor.cursor, 9);
    expect_equal(editor.history.entries.count, 0);
    # Line ends and control characters show as one harmless column each.
    expect_equal(editor.render("> "), "\r> a1⏎2\u{FFFD}[31mc\x1B[K\x1B[1D");
    var status = EditStatus.Editing;
    for (var key in KeyDecoder().feed("\r".bytes())) {
        status = editor.handle(key);
    }
    expect_true(status == EditStatus.Submitted);
    expect_equal(editor.history.entries[0], "a1\n2\x1B[31mc");
}
