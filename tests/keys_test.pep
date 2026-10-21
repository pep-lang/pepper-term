# The key decoder: bytes in, key events out.

import term;
import [Key, KeyDecoder] from term;

# The names of the events `input` decodes to, flushed at the end.
names(input: String): String {
    var decoder = KeyDecoder();
    var parts = Array<String>();
    for (var event in decoder.feed(input.bytes())) {
        parts.append(event.to_string());
    }
    for (var event in decoder.flush()) {
        parts.append(event.to_string());
    }
    return ",".join(parts);
}

[Test]
decodes_characters_and_control_keys() {
    expect_equal(names("aZ 1"), "a,Z, ,1");
    expect_equal(names("\r\t\x7F\x08"), "Enter,Tab,Backspace,Backspace");
    expect_equal(names("\x01\x03\x04\x1A"), "Ctrl+a,Ctrl+c,Ctrl+d,Ctrl+z");
    expect_equal(names("\x1C\x1F"), "Ctrl+\\,Ctrl+_");
}

[Test]
decodes_utf8_characters() {
    expect_equal(names("é€😀"), "é,€,😀");
    var events = KeyDecoder().feed("ü".bytes());
    expect_equal(events.count, 1);
    expect_true(events[0].key == Key.Char);
    expect_equal(events[0].text, "ü");
}

[Test]
replaces_broken_utf8() {
    var bytes = Array<u8>();
    bytes.append(255);
    bytes.append(195);  # a lead byte, then not a continuation
    bytes.append('a');
    var decoder = KeyDecoder();
    var parts = Array<String>();
    for (var event in decoder.feed(bytes)) {
        parts.append(event.text);
    }
    expect_equal(",".join(parts), "\u{FFFD},\u{FFFD},a");
}

[Test]
decodes_arrows_and_editing_keys() {
    expect_equal(names("\x1B[A\x1B[B\x1B[C\x1B[D"), "Up,Down,Right,Left");
    expect_equal(names("\x1BOA\x1BOD"), "Up,Left");
    expect_equal(names("\x1B[H\x1B[F\x1BOH\x1BOF"), "Home,End,Home,End");
    expect_equal(names("\x1B[1~\x1B[4~\x1B[7~\x1B[8~"), "Home,End,Home,End");
    expect_equal(names("\x1B[2~\x1B[3~\x1B[5~\x1B[6~"), "Insert,Delete,PageUp,PageDown");
    expect_equal(names("\x1B[Z"), "Shift+Tab");
}

[Test]
decodes_function_keys() {
    expect_equal(names("\x1BOP\x1BOQ\x1BOR\x1BOS"), "F1,F2,F3,F4");
    expect_equal(names("\x1B[11~\x1B[15~\x1B[17~\x1B[21~\x1B[23~\x1B[24~"), "F1,F5,F6,F10,F11,F12");
    expect_equal(names("\x1B[1;2P\x1B[15;5~"), "Shift+F1,Ctrl+F5");
}

[Test]
decodes_modifiers() {
    expect_equal(names("\x1B[1;5A\x1B[1;3D\x1B[1;2C\x1B[1;8B"), "Ctrl+Up,Alt+Left,Shift+Right,Ctrl+Alt+Shift+Down");
    expect_equal(names("\x1B[3;5~"), "Ctrl+Delete");
    expect_equal(names("\x1Bb\x1B\x01\x1Bé"), "Alt+b,Ctrl+Alt+a,Alt+é");
}

[Test]
holds_a_lone_escape_until_flushed() {
    var decoder = KeyDecoder();
    expect_equal(decoder.feed("\x1B".bytes()).count, 0);
    expect_true(decoder.has_pending);
    var events = decoder.flush();
    expect_equal(events.count, 1);
    expect_true(events[0].key == Key.Escape);
    expect_false(decoder.has_pending);
    expect_equal(names("\x1B\x1B[A"), "Escape,Up");
    expect_equal(names("\x1B["), "Alt+[");
}

[Test]
joins_sequences_split_across_reads() {
    var decoder = KeyDecoder();
    expect_equal(decoder.feed("\x1B[1;".bytes()).count, 0);
    var events = decoder.feed("5Aé".bytes().slice(0, 3).to_array());
    expect_equal(events.count, 1);
    expect_equal(events[0].to_string(), "Ctrl+Up");
    var rest = "é".bytes();
    var tail = Array<u8>();
    tail.append(rest[1]);
    events = decoder.feed(tail);
    expect_equal(events.count, 1);
    expect_equal(events[0].text, "é");
}

[Test]
reads_carriage_return_and_line_feed_as_one_enter() {
    expect_equal(names("a\r\nb\n\nc"), "a,Enter,b,Enter,Enter,c");
}

[Test]
reports_unknown_sequences() {
    expect_equal(names("\x1B[200~x"), "Unknown,x");
    expect_equal(names("\x1B[<0;3;4M"), "Unknown");
}

[Test]
survives_broken_and_huge_sequences() {
    # A control byte breaks the sequence, without holding the bytes back.
    var decoder = KeyDecoder();
    var events = decoder.feed("\x1B[\x01x".bytes());
    expect_equal(events.count, 3);
    expect_true(events[0].key == Key.Unknown);
    expect_equal(events[1].to_string(), "Ctrl+a");
    expect_false(decoder.has_pending);
    expect_equal(names("\x1B[99999999999999999999A"), "Up");
}
