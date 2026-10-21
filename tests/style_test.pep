# Colors, styles and cursor sequences.

import term;
import [BasicColor, Color, Style] from term;

[Test]
paints_basic_colors() {
    var red = Style(foreground = Color.Basic(BasicColor.Red));
    expect_equal(red.sequence(), "\x1B[31m");
    expect_equal(red.paint("hi", true), "\x1B[31mhi\x1B[0m");
    var bright = Style(foreground = Color.Basic(BasicColor.BrightWhite), background = Color.Basic(BasicColor.Blue));
    expect_equal(bright.sequence(), "\x1B[97;44m");
    expect_equal(Style(background = Color.Basic(BasicColor.BrightBlack)).sequence(), "\x1B[100m");
}

[Test]
paints_256_and_true_colors() {
    expect_equal(Style(foreground = Color.Indexed(208)).sequence(), "\x1B[38;5;208m");
    expect_equal(Style(background = Color.Indexed(0)).sequence(), "\x1B[48;5;0m");
    expect_equal(Style(foreground = Color.Rgb(255, 128, 0)).sequence(), "\x1B[38;2;255;128;0m");
    expect_equal(Style(background = Color.Rgb(1, 2, 3)).sequence(), "\x1B[48;2;1;2;3m");
}

[Test]
paints_attributes() {
    var all = Style(bold = true, dim = true, italic = true, underline = true, reverse = true);
    expect_equal(all.sequence(), "\x1B[1;2;3;4;7m");
    var warning = Style(foreground = Color.Basic(BasicColor.Yellow), bold = true);
    expect_equal(warning.paint("careful", true), "\x1B[1;33mcareful\x1B[0m");
}

[Test]
leaves_text_plain_when_disabled_or_unstyled() {
    var red = Style(foreground = Color.Basic(BasicColor.Red));
    expect_equal(red.paint("hi", false), "hi");
    expect_equal(Style().sequence(), "");
    expect_equal(Style().paint("hi", true), "hi");
}

[Test]
moves_the_cursor() {
    expect_equal(term.move_to(0, 0), "\x1B[1;1H");
    expect_equal(term.move_to(9, 4), "\x1B[10;5H");
    expect_equal(term.move_up(), "\x1B[1A");
    expect_equal(term.move_down(3), "\x1B[3B");
    expect_equal(term.move_right(2), "\x1B[2C");
    expect_equal(term.move_left(5), "\x1B[5D");
    expect_equal(term.move_left(0), "");
    expect_equal(term.move_to_column(0), "\x1B[1G");
    expect_equal(term.CLEAR_SCREEN + term.HIDE_CURSOR, "\x1B[2J\x1B[?25l");
}
