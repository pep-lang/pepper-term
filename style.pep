## Colors, text styles and cursor control, as the ANSI (ECMA-48) escape
## sequences every modern terminal reads, Windows' console included once
## virtual terminal processing is on (`colors_enabled` turns it on). Each
## function returns the sequence as a `String` to write; none writes
## anything itself.

## The 16 colors every color terminal has. Terminals choose the exact
## shades, and users often retheme them.
export enum BasicColor {
    ## Black.
    Black,
    ## Red.
    Red,
    ## Green.
    Green,
    ## Yellow.
    Yellow,
    ## Blue.
    Blue,
    ## Magenta.
    Magenta,
    ## Cyan.
    Cyan,
    ## White (light gray on many terminals).
    White,
    ## Bright black (dark gray).
    BrightBlack,
    ## Bright red.
    BrightRed,
    ## Bright green.
    BrightGreen,
    ## Bright yellow.
    BrightYellow,
    ## Bright blue.
    BrightBlue,
    ## Bright magenta.
    BrightMagenta,
    ## Bright cyan.
    BrightCyan,
    ## Bright white.
    BrightWhite,
}

## A text or background color, in one of the three palettes terminals
## offer.
[Value]
export enum Color {
    ## The terminal's own color, which `Style` leaves alone.
    Default,
    ## One of the 16 basic colors, which every color terminal shows.
    Basic(color: BasicColor),
    ## One of the 256 colors of xterm's palette: 0 to 15 the basic ones,
    ## 16 to 231 a 6x6x6 color cube, 232 to 255 a gray ramp.
    Indexed(index: u8),
    ## A true (24-bit) color; most terminals show it, and others approximate
    ## it or ignore it.
    Rgb(red: u8, green: u8, blue: u8),
}

## How text looks: its colors and attributes. `sequence` gives the escape
## sequence that sets it, and `paint` wraps text in it.
##
## @example
##     import term;
##     import [BasicColor, Color, Style] from term;
##
##     var warning = Style(foreground = Color.Basic(BasicColor.Yellow), bold = true);
##     print(warning.paint("careful", true));   # "\x1B[1;33mcareful\x1B[0m"
export struct Style {
    ## The text color.
    var foreground: Color;
    ## The background color.
    var background: Color;
    ## Bold (on some terminals, bright).
    var bold: bool;
    ## Dim (faint).
    var dim: bool;
    ## Italic; not every terminal shows it.
    var italic: bool;
    ## Underlined.
    var underline: bool;
    ## Foreground and background swapped.
    var reverse: bool;

    ## Makes a style.
    ##
    ## @param foreground the text color
    ## @param background the background color
    ## @param bold whether the text is bold
    ## @param dim whether the text is dim
    ## @param italic whether the text is italic
    ## @param underline whether the text is underlined
    ## @param reverse whether the colors are swapped
    construct(
        foreground: Color = Color.Default,
        background: Color = Color.Default,
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        underline: bool = false,
        reverse: bool = false
    ) {
        this.foreground = foreground;
        this.background = background;
        this.bold = bold;
        this.dim = dim;
        this.italic = italic;
        this.underline = underline;
        this.reverse = reverse;
    }

    ## Returns the escape sequence (SGR) that sets this style, or "" for a
    ## style that sets nothing. It changes only what the style sets, so
    ## follow the text with `RESET`.
    ##
    ## @returns the sequence
    sequence(): String {
        var codes = Array<String>();
        if (bold) {
            codes.append("1");
        }
        if (dim) {
            codes.append("2");
        }
        if (italic) {
            codes.append("3");
        }
        if (underline) {
            codes.append("4");
        }
        if (reverse) {
            codes.append("7");
        }
        _append_color(codes, foreground, 30);
        _append_color(codes, background, 40);
        if (codes.count == 0) {
            return "";
        }
        return $"\x1B[{";".join(codes)}m";
    }

    ## Returns `text` in this style: the style's sequence, the text, then
    ## `RESET`. With `enabled` false, or a style that sets nothing, it is
    ## `text` alone, so output to a file or a pipe stays plain.
    ##
    ## @param text the text to style
    ## @param enabled whether to style it; pass `colors_enabled()` to follow
    ##   the terminal and `NO_COLOR`
    ## @returns the styled text
    paint(text: String, enabled: bool): String {
        var start = enabled ? sequence() : "";
        if (start.is_empty) {
            return text;
        }
        return start + text + RESET;
    }
}

# Appends the SGR codes of `color` to `codes`: `base` is 30 for the text
# color and 40 for the background.
_append_color(codes: String[], color: Color, base: int) {
    match (color) {
        Default => {}
        Basic(basic) => {
            var index = basic as int;
            codes.append(index < 8 ? $"{base + index}" : $"{base + 60 + index - 8}");
        }
        Indexed(index) => {
            codes.append($"{base + 8};5;{index}");
        }
        Rgb(red, green, blue) => {
            codes.append($"{base + 8};2;{red};{green};{blue}");
        }
    }
}

## The sequence that turns every style and color off.
export const RESET = "\x1B[0m";
## The sequence that erases the whole screen. The cursor stays where it
## is; follow it with `move_to(0, 0)` to start at the top.
export const CLEAR_SCREEN = "\x1B[2J";
## The sequence that erases the cursor's row.
export const CLEAR_LINE = "\x1B[2K";
## The sequence that erases from the cursor to the end of its row.
export const CLEAR_TO_END_OF_LINE = "\x1B[K";
## The sequence that erases from the cursor to the end of the screen.
export const CLEAR_TO_END_OF_SCREEN = "\x1B[J";
## The sequence that hides the cursor.
export const HIDE_CURSOR = "\x1B[?25l";
## The sequence that shows the cursor.
export const SHOW_CURSOR = "\x1B[?25h";
## The sequence that saves the cursor's position, for `RESTORE_CURSOR`.
export const SAVE_CURSOR = "\x1B7";
## The sequence that moves the cursor back to where `SAVE_CURSOR` saved it.
export const RESTORE_CURSOR = "\x1B8";
## The sequence that switches to the alternate screen, which full-screen
## programs draw on so that the shell's screen comes back when they leave.
export const ENTER_ALTERNATE_SCREEN = "\x1B[?1049h";
## The sequence that returns from the alternate screen.
export const LEAVE_ALTERNATE_SCREEN = "\x1B[?1049l";

## Returns the sequence that moves the cursor to `row` and `column`,
## counted from 0 at the top left.
##
## @param row the row, from 0
## @param column the column, from 0
## @returns the sequence
## @example
##     import term;
##
##     assert(term.move_to(0, 4) == "\x1B[1;5H", "the terminal counts from 1");
export move_to(row: ulong, column: ulong): String {
    return $"\x1B[{row + 1};{column + 1}H";
}

## Returns the sequence that moves the cursor up `count` rows, stopping at
## the top; "" for 0.
##
## @param count how many rows
## @returns the sequence
export move_up(count: ulong = 1): String {
    return _move(count, "A");
}

## Returns the sequence that moves the cursor down `count` rows, stopping
## at the bottom; "" for 0.
##
## @param count how many rows
## @returns the sequence
export move_down(count: ulong = 1): String {
    return _move(count, "B");
}

## Returns the sequence that moves the cursor right `count` columns,
## stopping at the edge; "" for 0.
##
## @param count how many columns
## @returns the sequence
export move_right(count: ulong = 1): String {
    return _move(count, "C");
}

## Returns the sequence that moves the cursor left `count` columns,
## stopping at the edge; "" for 0.
##
## @param count how many columns
## @returns the sequence
export move_left(count: ulong = 1): String {
    return _move(count, "D");
}

## Returns the sequence that moves the cursor to `column` of its row,
## counted from 0.
##
## @param column the column, from 0
## @returns the sequence
export move_to_column(column: ulong): String {
    return $"\x1B[{column + 1}G";
}

# A cursor move ("Escape [ count letter"), or nothing for 0: the terminal
# reads a count of 0 as 1.
_move(count: ulong, letter: String): String {
    if (count == 0) {
        return "";
    }
    return $"\x1B[{count}{letter}";
}
