# Shows each key press, mouse report and paste, in raw mode with every
# mouse move reported and bracketed paste on, until q or the end of input.
#
#     pepper run -I packages examples/events/main.pep

import term;
import [Key, MouseTracking] from term;

main(): int {
    with (var raw = term.RawMode()) {
        with (var mouse = term.MouseMode(MouseTracking.Motion)) {
            with (var paste = term.PasteMode()) {
                if (mouse.active) {
                    print("click, drag, scroll, move the mouse or paste; press q to quit\r");
                }
                var input = term.InputReader();
                while (true) {
                    var event = input.read();
                    if (event.is_empty()) {
                        break;
                    }
                    match (event.value()) {
                        Key(key) => {
                            if (key.key == Key.Char && key.text == "q" && !key.ctrl && !key.alt) {
                                break;
                            }
                            print($"key {key}\r");
                        }
                        Mouse(report) => {
                            print($"mouse {report}\r");
                        }
                        Paste(text, truncated) => {
                            var cut = truncated ? ", truncated" : "";
                            print($"paste of {text.size} bytes{cut}: {text.replace("\n", "\\n")}\r");
                        }
                    }
                }
            }
        }
    }
    return 0;
}
