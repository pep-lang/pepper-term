## Mouse input: `MouseEvent`, `MouseKind` and `MouseButton`, and turning
## the terminal's reports (xterm's, and the Windows console's records) into
## them. `InputDecoder` (in `keys`) decodes reports beside key presses, and
## `MouseMode` (in `terminal`) turns them on. Decoding is pure, so it needs
## no terminal.

## What a `MouseEvent` reports.
export enum MouseKind {
    ## A button was pressed.
    Down,
    ## A button was released. Old (X10-encoded) reports do not say which,
    ## so `button` may be `MouseButton.None`.
    Up,
    ## The mouse moved with a button held (`MouseTracking.Drag` and
    ## `MouseTracking.Motion`).
    Drag,
    ## The mouse moved with no button held (`MouseTracking.Motion` only).
    Moved,
    ## The wheel turned away from the user.
    ScrollUp,
    ## The wheel turned toward the user.
    ScrollDown,
    ## The wheel tilted left.
    ScrollLeft,
    ## The wheel tilted right.
    ScrollRight,
}

## Which button a `MouseEvent` is about.
export enum MouseButton {
    ## The left (primary) button.
    Left,
    ## The middle button, or pressing the wheel.
    Middle,
    ## The right button.
    Right,
    ## No button: moves, the wheel, and releases that do not say which.
    None,
}

## One mouse report: what happened, the button, the cell it happened in,
## and the modifiers held.
##
## Many terminals keep Shift for themselves (to select text while the
## program has the mouse), so `shift` is rarely seen, and some keep Alt or
## Ctrl as well.
export struct MouseEvent {
    ## What happened.
    const kind: MouseKind;
    ## The button pressed, released or held; `MouseButton.None` for moves
    ## and the wheel.
    const button: MouseButton;
    ## The column, from 0 at the left.
    const column: ulong;
    ## The row, from 0 at the top.
    const row: ulong;
    ## Whether Ctrl was held.
    const ctrl: bool;
    ## Whether Alt (Meta, Option) was held.
    const alt: bool;
    ## Whether Shift was held.
    const shift: bool;

    ## Makes a mouse event.
    ##
    ## @param kind what happened
    ## @param button the button
    ## @param column the column, from 0
    ## @param row the row, from 0
    ## @param ctrl whether Ctrl was held
    ## @param alt whether Alt was held
    ## @param shift whether Shift was held
    construct(
        kind: MouseKind,
        button: MouseButton = MouseButton.None,
        column: ulong = 0,
        row: ulong = 0,
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false
    ) {
        this.kind = kind;
        this.button = button;
        this.column = column;
        this.row = row;
        this.ctrl = ctrl;
        this.alt = alt;
        this.shift = shift;
    }

    ## Returns the event as text, modifiers first: "Left Down at 3,4",
    ## "Ctrl+ScrollUp at 0,0", "Moved at 10,2".
    ##
    ## @returns the text
    to_string(): String {
        var name = "";
        if (ctrl) {
            name += "Ctrl+";
        }
        if (alt) {
            name += "Alt+";
        }
        if (shift) {
            name += "Shift+";
        }
        if (button != MouseButton.None) {
            name += $"{button.name()} ";
        }
        return name + $"{kind.name()} at {column},{row}";
    }

    # The event as the SGR report a terminal sends for it, which the
    # Windows console's mouse records are turned into so they reach the
    # decoder in order with the keys.
    _sgr(): String {
        var code = match (button) {
            Left => 0,
            Middle => 1,
            Right => 2,
            None => 3,
        };
        if (kind == MouseKind.Drag || kind == MouseKind.Moved) {
            code += 32;
        } else if (kind == MouseKind.ScrollUp) {
            code = 64;
        } else if (kind == MouseKind.ScrollDown) {
            code = 65;
        } else if (kind == MouseKind.ScrollLeft) {
            code = 66;
        } else if (kind == MouseKind.ScrollRight) {
            code = 67;
        }
        code += (shift ? 4 : 0) + (alt ? 8 : 0) + (ctrl ? 16 : 0);
        var end = kind == MouseKind.Up ? "m" : "M";
        return $"\x1B[<{code};{column + 1};{row + 1}{end}";
    }
}

# The event an xterm button code `code` (SGR or X10) reports at the
# one-based `column` and `row`; `release` is SGR's final "m". None for a
# report this package does not know (buttons past the third) or a position
# off the screen.
_mouse_from_code(code: int, column: int, row: int, release: bool): MouseEvent? {
    if (code < 0 || code >= 128 || column < 1 || row < 1) {
        return Optional<MouseEvent>.Empty;
    }
    var low = (code & 3) as ulong;
    var button = [MouseButton.Left, MouseButton.Middle, MouseButton.Right, MouseButton.None][low];
    var kind = release || low == 3 ? MouseKind.Up : MouseKind.Down;
    if ((code & 64) != 0) {
        kind = [MouseKind.ScrollUp, MouseKind.ScrollDown, MouseKind.ScrollLeft, MouseKind.ScrollRight][low];
        button = MouseButton.None;
    } else if ((code & 32) != 0) {
        kind = low == 3 ? MouseKind.Moved : MouseKind.Drag;
    }
    return Optional<MouseEvent>.Value(
        MouseEvent(
            kind,
            button,
            (column - 1) as ulong,
            (row - 1) as ulong,
            ctrl = (code & 16) != 0,
            alt = (code & 8) != 0,
            shift = (code & 4) != 0
        )
    );
}

# The Windows console's MOUSE_EVENT_RECORD flags.
const _MOUSE_MOVED: uint = 1;
const _MOUSE_WHEELED: uint = 4;
const _MOUSE_HWHEELED: uint = 8;

# The events one Windows console MOUSE_EVENT_RECORD reports: its button
# state `buttons`, control key state `controls` and event flags `flags`,
# at `column` and `row` of the window (from 0). The console gives the state
# of every button, not which one changed, so `previous` is the button state
# of the record before. `tracking` is the `MouseMode`'s mode number, which
# moves are kept for. Pure, so it is tested without a console.
export _mouse_from_record(
    buttons: uint, previous: uint, controls: uint, flags: uint, column: ulong, row: ulong, tracking: int
): MouseEvent[] {
    # RIGHT_ALT 1, LEFT_ALT 2, RIGHT_CTRL 4, LEFT_CTRL 8, SHIFT 16.
    var alt = (controls & 3) != 0;
    var ctrl = (controls & 12) != 0;
    var shift = (controls & 16) != 0;
    # The wheel's turn is the signed high word: positive away from the user, or right.
    var forward = (buttons & 2147483648) == 0;
    var found = Array<(MouseKind, MouseButton)>();
    if ((flags & _MOUSE_WHEELED) != 0) {
        found.append((forward ? MouseKind.ScrollUp : MouseKind.ScrollDown, MouseButton.None));
    } else if ((flags & _MOUSE_HWHEELED) != 0) {
        found.append((forward ? MouseKind.ScrollRight : MouseKind.ScrollLeft, MouseButton.None));
    } else if ((flags & _MOUSE_MOVED) != 0) {
        var button = _first_button(buttons);
        if (button == MouseButton.None && tracking == 1003) {
            found.append((MouseKind.Moved, button));
        } else if (button != MouseButton.None && tracking != 1000) {
            found.append((MouseKind.Drag, button));
        }
    } else {
        # A press, a release, or a double click's second press.
        for (var button in [MouseButton.Left, MouseButton.Middle, MouseButton.Right]) {
            var bit = _button_bit(button);
            if ((buttons & bit) != (previous & bit)) {
                found.append(((buttons & bit) != 0 ? MouseKind.Down : MouseKind.Up, button));
            }
        }
    }
    var events = Array<MouseEvent>();
    for (var (kind, button) in found) {
        events.append(MouseEvent(kind, button, column, row, ctrl = ctrl, alt = alt, shift = shift));
    }
    return events;
}

_first_button(buttons: uint): MouseButton {
    for (var button in [MouseButton.Left, MouseButton.Middle, MouseButton.Right]) {
        if ((buttons & _button_bit(button)) != 0) {
            return button;
        }
    }
    return MouseButton.None;
}

# FROM_LEFT_1ST_BUTTON_PRESSED, FROM_LEFT_2ND_BUTTON_PRESSED and
# RIGHTMOST_BUTTON_PRESSED.
_button_bit(button: MouseButton): uint {
    return match (button) {
        Left => 1,
        Middle => 4,
        Right => 2,
        None => 0,
    };
}
