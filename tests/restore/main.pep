# Turns raw mode on, says whether it did, and then ends as the argument
# says, so tests/run.sh can check the terminal is restored on each path:
#
# - `return`: returns from `main` with raw mode on
# - `panic`: panics with raw mode on
# - `signal`: is ended by SIGTERM with raw mode on (POSIX)
# - `forget`: keeps the RawMode alive past `main`, for the exit handler
#
# A second argument `mouse` turns mouse reporting on too, and says so.

import process;
import term;

[Target(OS(Linux) || OS(Mac))]
extern int raise(int number);

[Target(OS(Linux) || OS(Mac))]
_terminate() {
    raise(15);
}

[Target(OS(Windows))]
_terminate() {
    panic("SIGTERM is POSIX only");
}

# A cycle that keeps the RawMode and MouseMode alive past `main`.
struct Keeper {
    var raw: term.RawMode;
    var mouse: term.MouseMode?;
    var self: Keeper;
}

main(): int {
    var arguments = process.arguments();
    var how = arguments[1];
    var raw = term.RawMode();
    print(raw.active ? "raw" : "not a terminal");
    var mouse = Optional<term.MouseMode>.Empty;
    if (arguments.count > 2 && arguments[2] == "mouse") {
        mouse = Optional<term.MouseMode>.Value(term.MouseMode());
        print(mouse.value().active ? "mouse on" : "no mouse");
    }
    if (how == "panic") {
        panic("on purpose, in raw mode");
    }
    if (how == "signal") {
        _terminate();
    }
    if (how == "forget") {
        var keeper = Keeper();
        keeper.raw = raw;
        keeper.mouse = mouse;
        keeper.self = keeper;
    }
    return 0;
}
