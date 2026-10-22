# pepper-term

Interactive terminal programs for [Pepper](https://github.com/pep-lang/pepper):
raw mode, key and mouse input, readline-style line editing with history,
cursor control, and 16, 256 and true colors. It uses termios on Linux and macOS
and the Console API on Windows, and restores the terminal however the
program ends, a panic included.

One module, **`term`**:

- **`LineReader`** reads lines for a REPL or a prompt, with editing and
  history; **`LineEditor`**, **`History`** and **`EditStatus`** are the
  editing itself, which needs no terminal.
- **`RawMode`** turns raw mode on for its lifetime; **`restore()`** turns it
  off from anywhere.
- **`KeyReader`** reads key presses; **`KeyDecoder`** turns bytes into
  **`KeyEvent`**s (arrows, Home, End, Insert, Delete, Page Up and Down,
  F1 to F12, Ctrl, Alt and Shift, UTF-8 characters), with no terminal.
- **`MouseMode`** turns mouse reporting on for its lifetime (it is off
  unless a program asks), with **`MouseTracking`** saying which reports:
  buttons, drags, or every move. **`InputReader`** and **`InputDecoder`**
  read key presses and mouse reports together, as **`Event`**s:
  `Event.Key(KeyEvent)` or `Event.Mouse(MouseEvent)`, a **`MouseEvent`**
  holding its **`MouseKind`** (down, up, drag, moved, scroll up, down,
  left or right), **`MouseButton`**, zero-based column and row, and
  Ctrl, Alt and Shift.
- **`Style`**, **`Color`** and **`BasicColor`** color and style text;
  **`colors_enabled()`** says whether to, following `NO_COLOR`.
- **`move_to`**, `move_up`, `move_down`, `move_left`, `move_right`,
  `move_to_column`, and the constants `CLEAR_SCREEN`, `CLEAR_LINE`,
  `HIDE_CURSOR`, `ENTER_ALTERNATE_SCREEN` and their kin, move the cursor and
  clear the screen.
- **`input_is_terminal()`**, **`output_is_terminal()`** and **`size()`**
  describe the terminal.

```pepper
import term;
import [BasicColor, Color, LineInput, Style] from term;

main(): int {
    var colors = term.colors_enabled();
    var prompt = Style(foreground = Color.Basic(BasicColor.Green), bold = true).paint("> ", colors);
    var answer = Style(foreground = Color.Rgb(255, 160, 0));
    var reader = term.LineReader();
    while (true) {
        match (reader.read_line(prompt)) {
            Line(text) => {
                print(answer.paint($"you typed {text}", colors));
            }
            Interrupted => {}   # Ctrl+C: start a new line
            EndOfInput => {     # Ctrl+D, or the end of piped input
                return 0;
            }
        }
    }
}
```

This is `examples/repl/main.pep`; `examples/keys/main.pep` shows each key
pressed in raw mode, and `examples/mouse/main.pep` each mouse report.

Without a terminal (input or output a pipe or a file), everything still
works: `RawMode` does nothing and is not `active`, `LineReader` reads lines
plainly, `KeyReader` decodes the bytes as they come, and `colors_enabled()`
is false, so `paint` leaves text plain.

## Restoring the terminal

Raw mode is turned off when the `RawMode` goes away (use it in a `with`
block), at the end of `main`, on a panic, and, on Linux and macOS, on
SIGTERM, SIGHUP, SIGINT and SIGQUIT. Mouse reporting is turned off on the
same paths. `process.exit` ends the program without running exit
handlers, so call `term.restore()` before it.

## Mouse input

On Linux and macOS, `MouseMode` asks the terminal for xterm's reports
(modes 1000, 1002 or 1003) in SGR encoding (mode 1006); the older X10
encoding is decoded too when a terminal sends it. On Windows it turns on
the console's mouse input, and Quick Edit off while it is on, and the
console's mouse records become the same events. Many terminals keep
Shift+click for selecting text, so `shift` is rarely seen.

## Limits

- Each code point counts as one column: wide (CJK, emoji) and combining
  characters misplace the cursor in `LineEditor`.
- A line wider than the terminal scrolls sideways; it does not wrap onto
  more rows.
- No bracketed paste, resize notification (SIGWINCH), progress bars, or history saved to a
  file.
- In raw mode on Linux and macOS, output is raw too: write `"\r\n"` for a
  new line.
- On Windows, raw mode uses virtual terminal input (Windows 10 and later),
  and an Escape key is told from an escape sequence by what one read
  returns, without waiting.

## Using it

This repository is a package: `pep.toml` marks its root, and its root
`module.pep` is the `term` module. Add it to a project under the name
`term`:

```sh
pepper package add pep-lang/pepper-term --name term
```

which writes

```toml
[dependencies]
term = { github = "pep-lang/pepper-term" }
```

Without a project, put a folder named `term` that holds (or links to)
this repository on the import path: `pepper build -I packages main.pep`.

## Tests

```sh
tests/run.sh path/to/pepper
```

runs the `[Test]` functions in `tests/` with `pepper test` (key and mouse
decoding, Windows mouse records, line editing and styles, which need no
terminal), runs the examples on piped input, and on Linux and macOS runs
`tests/restore/main.pep` on a pseudo-terminal (through `script`) to check
the terminal's settings come back, and mouse reporting is turned off,
after a return, a panic, SIGTERM, and a `RawMode` kept alive past `main`.

## Releasing

CI (`.github/workflows/ci.yml`) runs the tests on Linux, macOS and
Windows for every push to `main` and every pull request. To release, set
`version` in `pep.toml`, merge, then push the matching tag
(`git tag v1.0.0 && git push origin v1.0.0`): CI tests the tag and
publishes a GitHub release for it. `pepper package add` and `pepper
package update` find versions by their tags.

## License

Apache-2.0; see [LICENSE](LICENSE).
