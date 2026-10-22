# Shows each mouse report and key press, in raw mode with every mouse move
# reported, until q or the end of input.
#
#     pepper run -I packages examples/mouse/main.pep

import term;
import [Key, MouseTracking] from term;

main(): int {
    with (var raw = term.RawMode()) {
        with (var mouse = term.MouseMode(MouseTracking.Motion)) {
            if (mouse.active) {
                print("click, drag, scroll or move the mouse; press q to quit\r");
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
                }
            }
        }
    }
    return 0;
}
