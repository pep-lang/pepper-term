# The line editor and its history: key events in, the line out.

import term;
import [EditStatus, History, KeyDecoder, LineEditor] from term;

# Feeds the keys `input` decodes to into `editor`, and returns the status
# after the last one.
type_into(editor: LineEditor, input: String): EditStatus {
    var status = EditStatus.Editing;
    for (var key in KeyDecoder().feed(input.bytes())) {
        status = editor.handle(key);
    }
    return status;
}

edited(input: String): String {
    var editor = LineEditor();
    type_into(editor, input);
    return editor.text;
}

const LEFT = "\x1B[D";
const RIGHT = "\x1B[C";
const UP = "\x1B[A";
const DOWN = "\x1B[B";

[Test]
inserts_and_moves() {
    expect_equal(edited("helo" + LEFT + "l"), "hello");
    expect_equal(edited("bc\x01a\x05d"), "abcd");      # Ctrl+A, Ctrl+E
    expect_equal(edited("bc\x1B[Ha\x1B[Fd"), "abcd");  # Home, End
    expect_equal(edited("ac\x02b\x06d"), "abcd");      # Ctrl+B, Ctrl+F
    expect_equal(edited("x" + LEFT + LEFT + LEFT + "<" + RIGHT + RIGHT + ">"), "<x>");
    expect_equal(edited("héllo" + LEFT + LEFT + "-"), "hél-lo");
}

[Test]
deletes() {
    expect_equal(edited("abc\x7F"), "ab");
    expect_equal(edited("abc\x08\x08"), "a");
    expect_equal(edited("abc\x01\x1B[3~"), "bc");                           # Home, Delete
    expect_equal(edited("abc\x01\x04"), "bc");                              # Ctrl+D deletes when not empty
    expect_equal(edited("\x7F\x1B[3~x"), "x");                              # nothing to delete
    expect_equal(edited("one two  \x17"), "one ");                          # Ctrl+W
    expect_equal(edited("one two\x1B\x7F"), "one ");                        # Alt+Backspace
    expect_equal(edited("one two" + LEFT + LEFT + LEFT + "\x15"), "two");   # Ctrl+U
    expect_equal(edited("one two" + LEFT + LEFT + LEFT + "\x0B"), "one ");  # Ctrl+K
}

[Test]
moves_by_words() {
    expect_equal(edited("one two three\x1B[1;5D\x1B[1;5D!"), "one !two three");
    expect_equal(edited("one two three\x01\x1Bf!"), "one! two three");
    expect_equal(edited("one two\x1Bb\x1Bb\x1B[1;3C_"), "one_ two");
}

[Test]
reports_enter_ctrl_c_and_ctrl_d() {
    var editor = LineEditor();
    expect_true(type_into(editor, "hi") == EditStatus.Editing);
    expect_true(type_into(editor, "\r") == EditStatus.Submitted);
    expect_equal(editor.text, "hi");
    editor.clear();
    expect_equal(editor.text, "");
    expect_true(type_into(editor, "x\x03") == EditStatus.Interrupted);
    editor.clear();
    expect_true(type_into(editor, "\x04") == EditStatus.EndOfInput);
}

[Test]
recalls_history() {
    var editor = LineEditor();
    type_into(editor, "first\r");
    editor.clear();
    type_into(editor, "second\r");
    editor.clear();
    type_into(editor, "draft" + UP);
    expect_equal(editor.text, "second");
    type_into(editor, UP);
    expect_equal(editor.text, "first");
    type_into(editor, UP);
    expect_equal(editor.text, "first");
    type_into(editor, DOWN + DOWN);
    expect_equal(editor.text, "draft");
    type_into(editor, DOWN);
    expect_equal(editor.text, "draft");
    type_into(editor, "\x10!\r");  # Ctrl+P
    expect_equal(editor.text, "second!");
    expect_equal(",".join(editor.history.entries), "first,second,second!");
}

[Test]
history_skips_repeats_and_keeps_its_limit() {
    var history = History(limit = 2);
    history.add("a");
    history.add("a");
    history.add("");
    history.add("b");
    history.add("c");
    expect_equal(",".join(history.entries), "b,c");
}

[Test]
renders_the_line_and_cursor() {
    var editor = LineEditor();
    type_into(editor, "hello" + LEFT + LEFT);
    expect_equal(editor.cursor, 3);
    expect_equal(editor.render("> "), "\r> hello\x1B[K\x1B[2D");
    type_into(editor, "\x05");
    expect_equal(editor.render("> "), "\r> hello\x1B[K");
}

[Test]
scrolls_a_line_wider_than_the_terminal() {
    var editor = LineEditor();
    type_into(editor, "abcdefghij");
    # 2 columns of prompt and one for the cursor leave 7 for text.
    expect_equal(editor.render("> ", 10), "\r> defghij\x1B[K");
    type_into(editor, "\x01");
    expect_equal(editor.render("> ", 10), "\r> abcdefg\x1B[K\x1B[7D");
    expect_equal(editor.render("> ", 20), "\r> abcdefghij\x1B[K\x1B[10D");
}
