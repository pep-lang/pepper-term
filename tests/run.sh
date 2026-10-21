#!/usr/bin/env bash
# Runs the package's tests: the [Test] functions in tests/, with pepper test.
#
# Usage: tests/run.sh [path/to/pepper]   (default: pepper on PATH)
#
# Then it builds the examples and runs them on piped input, which is how
# they behave without a terminal. On Linux and macOS it also runs
# tests/restore/main.pep on a pseudo-terminal (through `script`) and checks
# the terminal's settings are back as they were after each way the program
# can end with raw mode on.
set -euxo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pepper="${1:-pepper}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

# The package is the module `term`: a folder of that name on the import path.
mkdir "$build/packages"
ln -s "$root" "$build/packages/term"
"$pepper" test -I "$build/packages" "$root/tests"

for program in repl keys; do
    "$pepper" build -I "$build/packages" "$root/examples/$program/main.pep" -o "$build/$program"
done
"$pepper" build -I "$build/packages" "$root/tests/restore/main.pep" -o "$build/restore"

# Without a terminal: lines are read plainly, and keys decoded as they come.
expect() {
    if [ "$1" != "$2" ]; then
        printf 'error: expected %q, got %q\n' "$2" "$1" >&2
        exit 1
    fi
}
# Windows' print ends lines with "\r\n", so carriage returns are dropped.
expect "$(printf 'one\r\ntwo\n\nlast' | "$build/repl" | tr -d '\r')" \
    "$(printf '> you typed one\n> you typed two\n> you typed \n> you typed last\n> 3 lines')"
expect "$(printf 'a\033[A\033[1;5C\303\251\tq' | "$build/keys" | tr -d '\r')" "$(printf 'a\nUp\nCtrl+Right\n\303\251\nTab')"

case "$(uname -s)" in
    Linux) on_terminal() { script -qec "$1" /dev/null; } ;;
    Darwin) on_terminal() { script -q /dev/null sh -c "$1"; } ;;
    *) exit 0 ;;  # no pseudo-terminal to test on
esac

# A control first: the settings must not change with nothing run between.
on_terminal "stty -g > '$build/before'; sleep 0.2; stty -g > '$build/after'" < /dev/null || true
cat "$build/before" "$build/after"
cmp "$build/before" "$build/after" || { echo "error: the terminal's settings change by themselves" >&2; exit 1; }

for how in return panic signal forget; do
    rm -f "$build/before" "$build/after" "$build/said"
    on_terminal "stty -g > '$build/before'; '$build/restore' $how > '$build/said' 2>&1; stty -g > '$build/after'" < /dev/null || true
    grep -q '^raw' "$build/said" || { cat "$build/said" >&2; echo "error: $how: raw mode did not turn on" >&2; exit 1; }
    cmp "$build/before" "$build/after" || {
        cat "$build/before" "$build/after" >&2
        echo "error: $how left the terminal in raw mode" >&2
        exit 1
    }
done
