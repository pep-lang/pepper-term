# The clipboard: what OSC 52 writes, its limit, how `Auto` chooses, and, on
# Windows, a copy and read of the real clipboard. Reading OSC 52 replies is
# tested beside the other input, in input_test.pep.

import os;
import term;
import [Clipboard, ClipboardBackend] from term;

[Test]
encodes_osc52_copies_as_base64() {
    expect_equal(term._osc52_copy("hello"), "\x1B]52;c;aGVsbG8=\x07");
    expect_equal(term._osc52_copy(""), "\x1B]52;c;\x07");
    expect_equal(term._osc52_copy("é\n"), "\x1B]52;c;w6kK\x07");
}

[Test]
refuses_osc52_copies_past_the_limit() {
    var clipboard = Clipboard(ClipboardBackend.Osc52, osc52_limit = 4);
    expect_true(clipboard.backend == ClipboardBackend.Osc52);
    var copied = clipboard.copy("hello");
    expect_true(copied is Err(TooLarge(4)));
    # The error never holds the text.
    expect_false(copied.error().to_string().contains("hello"));
    # The default's base64 fits in the 100,000 bytes some terminals take.
    var longest = "";
    for (var index in 0..Clipboard(ClipboardBackend.Osc52).osc52_limit) {
        longest += "x";
    }
    expect_true(term._osc52_copy(longest).size <= 100000);
}

[Test]
needs_a_terminal_for_osc52() {
    # The tests' output and input are not a terminal.
    if (term.output_is_terminal() || term.input_is_terminal()) {
        return;
    }
    var clipboard = Clipboard(ClipboardBackend.Osc52);
    expect_true(clipboard.copy("x") is Err(NoBackend(_)));
    expect_true(clipboard.read(timeout_ms = 10) is Err(NoBackend(_)));
}

[Test]
chooses_osc52_over_ssh() {
    var saved = os.environment("SSH_TTY");
    os.set_environment("SSH_TTY", "/dev/pts/0");
    var over_ssh = Clipboard().backend;
    if (saved.is_empty()) {
        os.remove_environment("SSH_TTY");
    } else {
        os.set_environment("SSH_TTY", saved.value());
    }
    expect_true(over_ssh == ClipboardBackend.Osc52);
    expect_true(Clipboard(ClipboardBackend.System).backend == ClipboardBackend.System);
}

[Target(OS(Windows))]
copy_and_read_the_windows_clipboard() {
    var clipboard = Clipboard(ClipboardBackend.System);
    # Put back what the clipboard held, after the test.
    var before = clipboard.read();
    if (before is Err(Failed(reason))) {
        print($"skipped: the Windows clipboard cannot be opened here ({reason})");
        return;
    }
    expect_true(before.is_ok());
    var text = "pepper-term é€😀\r\nline two";
    expect_true(clipboard.copy(text).is_ok());
    var after = clipboard.read();
    expect_true(after.is_ok());
    expect_equal(after.value(), text);
    expect_true(clipboard.copy("").is_ok());
    expect_equal(clipboard.read().value(), "");
    clipboard.copy(before.value());
}

[Target(OS(Linux) || OS(Mac))]
copy_and_read_the_windows_clipboard() {}

[Test]
copies_and_reads_the_windows_clipboard() {
    copy_and_read_the_windows_clipboard();
}
