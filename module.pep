## Interactive terminal programs: raw mode, key and mouse input, line
## editing with history, cursor control, and 16, 256 and true colors, on
## Linux, macOS (termios) and Windows (the Console API).
##
## Bring it in with `import term`. Decoding input (`InputDecoder`) and
## editing lines (`LineEditor`) are pure, bytes in and events or text out,
## so they work and test without a terminal. Without one (input or output
## a pipe or a file), raw mode does nothing, lines are read plainly, and
## `colors_enabled()` is false.
##
## - `RawMode`, `restore`: raw mode on and off; the terminal is restored at
##   exit and on a panic too
## - `KeyReader`, `KeyDecoder`, `KeyEvent`, `Key`: key presses
## - `MouseMode`, `MouseTracking`: mouse reporting on and off (it is off
##   unless a program turns it on)
## - `InputReader`, `InputDecoder`, `Event`, `MouseEvent`, `MouseKind`,
##   `MouseButton`: key presses and mouse reports together
## - `LineReader`, `LineInput`, `LineEditor`, `EditStatus`, `History`:
##   readline-style line editing
## - `Style`, `Color`, `BasicColor`, `RESET`, `colors_enabled`: colors and
##   text styles
## - `move_to`, `move_up` and the other moves, `CLEAR_SCREEN` and the other
##   sequences: the cursor and the screen
## - `input_is_terminal`, `output_is_terminal`, `size`, `Size`: the
##   terminal itself
##
## @example
##     import term;
##     import [BasicColor, Color, LineInput, Style] from term;
##
##     main(): int {
##         var prompt = Style(foreground = Color.Basic(BasicColor.Green), bold = true);
##         var reader = term.LineReader();
##         while (true) {
##             match (reader.read_line(prompt.paint("> ", term.colors_enabled()))) {
##                 Line(text) => {
##                     print($"you typed {text}");
##                 }
##                 Interrupted => {}
##                 EndOfInput => {
##                     return 0;
##                 }
##             }
##         }
##     }

# This file only gathers the module's public API from its other files.

import "keys";
import "line";
import "mouse";
import "style";
import "terminal";

export Key;
export KeyEvent;
export KeyDecoder;
export Event;
export InputDecoder;
export MouseKind;
export MouseButton;
export MouseEvent;
export _mouse_from_record;
export History;
export EditStatus;
export LineEditor;
export BasicColor;
export Color;
export Style;
export RESET;
export CLEAR_SCREEN;
export CLEAR_LINE;
export CLEAR_TO_END_OF_LINE;
export CLEAR_TO_END_OF_SCREEN;
export HIDE_CURSOR;
export SHOW_CURSOR;
export SAVE_CURSOR;
export RESTORE_CURSOR;
export ENTER_ALTERNATE_SCREEN;
export LEAVE_ALTERNATE_SCREEN;
export move_to;
export move_up;
export move_down;
export move_right;
export move_left;
export move_to_column;
export input_is_terminal;
export output_is_terminal;
export Size;
export size;
export colors_enabled;
export RawMode;
export restore;
export KeyReader;
export InputReader;
export MouseTracking;
export MouseMode;
export LineInput;
export LineReader;
