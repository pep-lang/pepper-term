#!/usr/bin/env bash
# Runs the package's tests: the [Test] functions in tests/, with pepper test.
#
# Usage: tests/run.sh [path/to/pepper]   (default: pepper on PATH)
#
# Then it builds the examples and runs them on piped input, which is how
# they behave without a terminal, and copies to and reads the OS's
# clipboard (a fake wl-copy on Linux, pbcopy on macOS). On Linux and macOS
# it also runs tests/restore/main.pep on a pseudo-terminal (through
# `script`) and checks the terminal's settings are back as they were after
# each way the program can end with raw mode on, and checks OSC 52's copy
# and its read's timeout there.
set -euxo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pepper="${1:-pepper}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

# The package is the module `term`: a folder of that name on the import path.
mkdir "$build/packages"
ln -s "$root" "$build/packages/term"
"$pepper" test -I "$build/packages" "$root/tests"

for program in repl keys events clipboard; do
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
expect "$(printf '\033[<0;3;4M\033[<64;1;1Mxq' | "$build/events" | tr -d '\r')" \
    "$(printf 'mouse Left Down at 2,3\nmouse ScrollUp at 0,0\nkey x')"
# A paste is one event, line ends and all, even across the pipe's reads.
expect "$(printf '\033[200~a\rb\033[201~q' | "$build/events" | tr -d '\r')" 'paste of 3 bytes: a\nb'
big="$(head -c 5000 /dev/zero | tr '\0' x)"
expect "$(printf '\033[200~%s\033[201~q' "$big" | "$build/events" | tr -d '\r')" "paste of 5000 bytes: $big"

# The OS's clipboard: on Linux through a fake wl-copy and wl-paste on the
# PATH, which keep the text in a file; on macOS through the real pbcopy and
# pbpaste; on Windows its own, skipped (saying so) when it cannot be opened.
# What the real clipboard held is put back after, and kept out of the log.
clipboard_round_trip() {
    expect "$(printf 'h\303\251llo\nworld' | "$@" "$build/clipboard" copy | tr -d '\r')" 'copied, through System'
    expect "$("$@" "$build/clipboard" < /dev/null | tr -d '\r')" "$(printf 'read, through System: h\303\251llo\nworld')"
}
case "$(uname -s)" in
    Linux)
        mkdir "$build/fake"
        printf '#!/bin/sh\ncat > "$FAKE_CLIPBOARD"\n' > "$build/fake/wl-copy"
        printf '#!/bin/sh\n[ "$1" = --no-newline ] || exit 2\ncat "$FAKE_CLIPBOARD"\n' > "$build/fake/wl-paste"
        chmod +x "$build/fake/wl-copy" "$build/fake/wl-paste"
        clipboard_round_trip env -u DISPLAY WAYLAND_DISPLAY=fake PATH="$build/fake:$PATH" FAKE_CLIPBOARD="$build/copied"
        expect "$(cat "$build/copied")" "$(printf 'h\303\251llo\nworld')"
        # With no clipboard program, Auto is OSC 52, which needs a terminal.
        expect "$(env -u DISPLAY -u WAYLAND_DISPLAY "$build/clipboard" < /dev/null || true)" \
            'could not read, through Osc52: no clipboard: standard input and output, which OSC 52 needs, are not a terminal'
        ;;
    Darwin)
        { set +x; } 2> /dev/null
        saved="$(pbpaste)"
        set -x
        clipboard_round_trip env
        { set +x; } 2> /dev/null
        printf '%s' "$saved" | pbcopy
        set -x
        ;;
    MINGW* | MSYS* | CYGWIN*)
        { set +x; } 2> /dev/null
        saved="$("$build/clipboard" < /dev/null || true)"
        set -x
        case "$saved" in
            'read, through System: '*)
                clipboard_round_trip env
                { set +x; } 2> /dev/null
                printf '%s' "${saved#read, through System: }" | "$build/clipboard" copy > /dev/null
                set -x
                ;;
            *OpenClipboard*) echo "skipped the Windows clipboard: it cannot be opened here" ;;
            *) echo "error: reading the Windows clipboard failed" >&2; exit 1 ;;
        esac
        ;;
esac

case "$(uname -s)" in
    Linux) on_terminal() { script -qec "$1" /dev/null; } ;;
    Darwin) on_terminal() { script -q /dev/null sh -c "$1"; } ;;
    *) exit 0 ;;  # no pseudo-terminal to test on
esac

# The settings as `stty -a` lists them, one per line. `pendin` is left out:
# macOS's kernel sets it on its own when canonical mode comes back with
# input pending (here the ^D `script` sends at the end of its input).
settings() {
    tr ' \t' '\n\n' < "$1" | grep -v -e '^-*pendin$' -e '^$' || true
}

for how in return panic signal forget; do
    rm -f "$build/before" "$build/after" "$build/said"
    on_terminal "stty -a > '$build/before'; '$build/restore' $how > '$build/said' 2>&1; stty -a > '$build/after'" < /dev/null || true
    grep -q '^raw' "$build/said" || { cat "$build/said" >&2; echo "error: $how: raw mode did not turn on" >&2; exit 1; }
    diff <(settings "$build/before") <(settings "$build/after") || {
        echo "error: $how left the terminal in raw mode" >&2
        exit 1
    }
done

# With mouse reporting and bracketed paste on too: their sequences go to
# the terminal, which `script` copies out, so after the last sequence that
# turns each on must come the one that turns it off.
turned_off() {
    case "${2##*"$3"}" in
        *"$4"*) ;;
        *) cat -v "$build/typescript" >&2; echo "error: $1 left $5 on" >&2; exit 1 ;;
    esac
}
for how in return panic signal forget; do
    on_terminal "'$build/restore' $how modes" < /dev/null > "$build/typescript" 2>&1 || true
    grep -q 'modes on' "$build/typescript" || { cat -v "$build/typescript" >&2; echo "error: $how: the modes did not turn on" >&2; exit 1; }
    after="$(cat "$build/typescript")"
    turned_off "$how" "$after" $'\e[?1006h' $'\e[?1006l\e[?1003l\e[?1002l\e[?1000l' "mouse reporting"
    turned_off "$how" "$after" $'\e[?2004h' $'\e[?2004l' "bracketed paste"
done

# OSC 52 on a terminal (SSH_TTY makes Auto choose it): a copy writes the
# sequence, and a read the terminal does not answer (`script` answers
# nothing) times out rather than hanging.
on_terminal "printf hi | SSH_TTY=x '$build/clipboard' copy; SSH_TTY=x '$build/clipboard'" < /dev/null > "$build/typescript" 2>&1 || true
for want in $'copied, through Osc52' $'\e]52;c;aGk=\a' $'\e]52;c;?\a' 'could not read, through Osc52: the terminal did not answer'; do
    grep -qF "$want" "$build/typescript" || { cat -v "$build/typescript" >&2; echo "error: OSC 52: no $(printf %q "$want")" >&2; exit 1; }
done
