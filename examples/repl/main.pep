# A REPL: reads lines with editing and history, and answers each one in
# color. Ctrl+C abandons a line; Ctrl+D or the end of input quits.
#
#     pepper run -I packages examples/repl/main.pep

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
            Interrupted => {}
            EndOfInput => {
                print($"{reader.editor.history.entries.count} lines");
                return 0;
            }
        }
    }
}
