# With the argument `copy`, copies standard input to the clipboard;
# without one, prints what the clipboard holds. Either way it says which
# backend it used: the OS's clipboard, or the terminal's (OSC 52) over SSH
# or where the OS has none.
#
#     echo some text | pepper run -I packages examples/clipboard/main.pep -- copy
#     pepper run -I packages examples/clipboard/main.pep

import io;
import process;
import term;

main(): int {
    var clipboard = term.Clipboard();
    var arguments = process.arguments();
    if (arguments.count > 1 && arguments[1] == "copy") {
        var copied = clipboard.copy(io.File.stdin().read_string().ok_or(""));
        if (copied.is_err()) {
            print($"could not copy, through {clipboard.backend.name()}: {copied.error()}");
            return 1;
        }
        print($"copied, through {clipboard.backend.name()}");
        return 0;
    }
    var pasted = clipboard.read();
    if (pasted.is_err()) {
        print($"could not read, through {clipboard.backend.name()}: {pasted.error()}");
        return 1;
    }
    print($"read, through {clipboard.backend.name()}: {pasted.value()}");
    return 0;
}
