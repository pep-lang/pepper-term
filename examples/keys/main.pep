# Shows each key pressed, by name, in raw mode, until q or the end of input.
#
#     pepper run -I packages examples/keys/main.pep

import term;
import [Key] from term;

main(): int {
    with (var raw = term.RawMode()) {
        if (raw.active) {
            var size = term.size();
            var columns = size.is_empty() ? 0 : size.value().columns;
            print($"raw mode on a {columns}-column terminal; press q to quit\r");
        }
        var keys = term.KeyReader();
        while (true) {
            var key = keys.read();
            if (key.is_empty()) {
                break;
            }
            var event = key.value();
            if (event.key == Key.Char && event.text == "q" && !event.ctrl && !event.alt) {
                break;
            }
            print($"{event}\r");
        }
    }
    return 0;
}
