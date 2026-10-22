## The clipboard: `Clipboard` copies text to it and reads text from it,
## through the OS's clipboard where the program runs locally, or through
## the terminal (OSC 52), which reaches the clipboard of the machine the
## user sits at, over SSH too.

import base64;
import io;
import os;
import "sys_posix";
import "sys_windows";
import "terminal";

## Where a `Clipboard` copies to and reads from.
export enum ClipboardBackend {
    ## `System` when the program runs locally and the OS has a clipboard it
    ## can reach, else `Osc52`. Locally means none of `SSH_CONNECTION`,
    ## `SSH_CLIENT` and `SSH_TTY` is set: over SSH the OS's clipboard is
    ## the remote machine's, which the user cannot paste from.
    Auto,
    ## The OS's clipboard: on Windows, its own (`CF_UNICODETEXT`); on
    ## macOS, `pbcopy` and `pbpaste`; on Linux, `wl-copy` and `wl-paste`
    ## when `WAYLAND_DISPLAY` is set, else `xclip` or else `xsel` when
    ## `DISPLAY` is, each found on the `PATH`.
    System,
    ## The terminal's: OSC 52 sequences written to standard output, which
    ## the terminal acts on, so it reaches the user's clipboard over SSH.
    Osc52,
}

## Why a `Clipboard` could not copy or read. None of them holds the
## clipboard's text, so they are safe to show or log.
[Value]
export enum ClipboardError {
    ## There is no clipboard to use; `reason` says why, such as no
    ## `wl-copy`, `xclip` or `xsel` on the `PATH`, or standard output not
    ## a terminal for OSC 52.
    NoBackend(reason: String),
    ## The text is longer than `limit` bytes: a copy past the
    ## `Clipboard`'s `osc52_limit`, or a reply past the reader's
    ## `clipboard_limit`.
    TooLarge(limit: ulong),
    ## The terminal did not answer an OSC 52 read in time. Most terminals
    ## turn reading the clipboard off, and answer nothing.
    TimedOut,
    ## The OS's clipboard, or the program reaching it, refused; `reason`
    ## says how.
    Failed(reason: String),

    ## Returns what went wrong, as a sentence fragment for a message.
    ##
    ## @returns the description
    to_string(): String {
        return match (this) {
            NoBackend(reason) => $"no clipboard: {reason}",
            TooLarge(limit) => $"the text is longer than the clipboard's limit of {limit} bytes",
            TimedOut => "the terminal did not answer the clipboard read; it may have reading the clipboard (OSC 52) turned off",
            Failed(reason) => $"the clipboard refused: {reason}",
        };
    }
}

## Copies text to the clipboard, and reads it, through the backend
## `backend` says (see `ClipboardBackend`): the OS's clipboard, or the
## terminal's through OSC 52. `Auto`, the default, is resolved once, when
## the `Clipboard` is made, so `backend` says which is in use.
##
## Through OSC 52, `copy` writes `ESC ] 52 ; c ; <base64> BEL` to standard
## output, and the terminal sets its clipboard; nothing comes back to say
## whether it did. Most terminals allow it, some only after the user turns
## it on, and some cap its length (`osc52_limit`). `read` asks with
## `ESC ] 52 ; c ; ? BEL`, which most terminals refuse by not answering, so
## it waits at most `timeout_ms` and then fails with
## `ClipboardError.TimedOut`; it never hangs.
##
## Inside tmux, the sequence reaches tmux, not the terminal: with
## `set -g set-clipboard on` in `.tmux.conf`, tmux sets its own buffer and
## passes the copy on to the terminal. GNU screen passes OSC 52 on only
## inside its own escape (`ESC P` ... `ESC \`) and cuts long ones short.
## This package writes the plain sequence and wraps it for neither, since
## tmux's `set-clipboard` makes that unneeded; under screen, use `System`.
##
## The text copied or read is never put in an error or a log.
##
## @example
##     import term;
##     import [ClipboardBackend] from term;
##
##     main(): int {
##         var clipboard = term.Clipboard();
##         var copied = clipboard.copy("hello");
##         if (copied.is_err()) {
##             print($"could not copy: {copied.error()}");
##             return 1;
##         }
##         print(clipboard.backend == ClipboardBackend.System ? "copied" : "asked the terminal to copy");
##         return 0;
##     }
export struct Clipboard {
    ## The backend in use: `System` or `Osc52`, `Auto` resolved.
    const backend: ClipboardBackend;
    ## The most bytes of text `copy` sends through OSC 52; longer text
    ## fails with `ClipboardError.TooLarge` rather than being cut.
    const osc52_limit: ulong;
    # The OS's clipboard program (or Windows' clipboard), or why there is
    # none: found once, so `backend` and each call agree.
    const _tool: Result<String>;

    ## Makes a clipboard, choosing its backend.
    ##
    ## @param backend the backend; `Auto` picks one as `ClipboardBackend`
    ##   says
    ## @param osc52_limit the most bytes of text to copy through OSC 52:
    ##   74,994 unless said, whose base64 is just under the 100,000 bytes
    ##   some terminals (hterm, for one) take at most
    construct(backend: ClipboardBackend = ClipboardBackend.Auto, osc52_limit: ulong = 74994) {
        _tool = _term_clipboard_tool();
        this.backend = backend == ClipboardBackend.Auto ? _clipboard_auto(_tool.is_ok()) : backend;
        this.osc52_limit = osc52_limit;
    }

    ## Copies `text` to the clipboard.
    ##
    ## Through OSC 52 the terminal does not say whether it copied, so
    ## success means the request was written.
    ##
    ## @param text the text to copy
    ## @returns nothing; `NoBackend` when the OS has no clipboard to reach
    ##   or, for OSC 52, standard output is not a terminal, `TooLarge` past
    ##   `osc52_limit`, or `Failed` when the OS refused
    copy(text: String): Result<void, ClipboardError> {
        if (backend == ClipboardBackend.System) {
            if (_tool is Err(error)) {
                return Result<void, ClipboardError>.err(ClipboardError.NoBackend(error.message));
            }
            var copied = _term_clipboard_copy(_tool.value(), text);
            if (copied is Err(error)) {
                return Result<void, ClipboardError>.err(ClipboardError.Failed(error.message));
            }
            return Result<void, ClipboardError>.ok();
        }
        if (text.size > osc52_limit) {
            return Result<void, ClipboardError>.err(ClipboardError.TooLarge(osc52_limit));
        }
        if (!output_is_terminal()) {
            return Result<void, ClipboardError>.err(
                ClipboardError.NoBackend("standard output, which OSC 52 is written to, is not a terminal")
            );
        }
        _term_enable_sequences();
        io.File.stdout().write_all(_osc52_copy(text));
        return Result<void, ClipboardError>.ok();
    }

    ## Returns the text on the clipboard.
    ##
    ## Through OSC 52 it asks the terminal, in raw mode (turned on while it
    ## waits, if it is not on), and waits at most `timeout_ms` for the
    ## answer, which `input` decodes. Other input that comes meanwhile,
    ## such as keys, stays in `input` for its next `read`, so pass the
    ## program's own `InputReader`. An answer that comes after the wait
    ## arrives there as an `Event.ClipboardReply`. A terminal that asks the
    ## user first (kitty can) may answer after the wait; with raw mode off
    ## by then the terminal shows the answer as typed text, so for such a
    ## terminal keep a `RawMode` on and pass a longer `timeout_ms`.
    ##
    ## @param timeout_ms how long to wait for the terminal's answer, in
    ##   milliseconds; the OS's clipboard answers at once
    ## @param input the reader the terminal's answer is read through
    ## @returns the text, empty when the clipboard holds none; `NoBackend`
    ##   when there is no clipboard or, for OSC 52, standard input or
    ##   output is not a terminal, `TimedOut` when the terminal does not
    ##   answer, `TooLarge` past `input`'s `clipboard_limit`, or `Failed`
    ##   when the OS refused
    read(timeout_ms: int = 1000, input: InputReader = InputReader()): Result<String, ClipboardError> {
        if (backend == ClipboardBackend.System) {
            if (_tool is Err(error)) {
                return Result<String, ClipboardError>.err(ClipboardError.NoBackend(error.message));
            }
            var pasted = _term_clipboard_read(_tool.value());
            if (pasted is Err(error)) {
                return Result<String, ClipboardError>.err(ClipboardError.Failed(error.message));
            }
            return Result<String, ClipboardError>.ok(pasted.value());
        }
        if (!input_is_terminal() || !output_is_terminal()) {
            return Result<String, ClipboardError>.err(
                ClipboardError.NoBackend("standard input and output, which OSC 52 needs, are not a terminal")
            );
        }
        var reply = Optional<(String, bool)>.Empty;
        with (var raw = RawMode()) {
            _term_enable_sequences();
            io.File.stdout().write_all("\x1B]52;c;?\x07");
            reply = input._read_reply(timeout_ms);
        }
        if (reply.is_empty()) {
            return Result<String, ClipboardError>.err(ClipboardError.TimedOut);
        }
        var (copied, truncated) = reply.value();
        if (truncated) {
            return Result<String, ClipboardError>.err(ClipboardError.TooLarge(input._decoder.clipboard_limit));
        }
        return Result<String, ClipboardError>.ok(copied);
    }
}

# The OSC 52 sequence that copies `text` to the terminal's clipboard.
export _osc52_copy(text: String): String {
    return $"\x1B]52;c;{base64.encode(text.bytes())}\x07";
}

# The backend `ClipboardBackend.Auto` stands for here and now, where the
# OS's clipboard is reachable when `system` is true.
_clipboard_auto(system: bool): ClipboardBackend {
    for (var name in ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"]) {
        if (!os.environment(name).value_or("").is_empty) {
            return ClipboardBackend.Osc52;
        }
    }
    return system ? ClipboardBackend.System : ClipboardBackend.Osc52;
}
