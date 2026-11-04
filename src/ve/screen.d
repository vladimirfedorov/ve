module ve.screen;

import std.algorithm.comparison : max, min;
import std.array : appender;
import std.conv : to;
import std.format : format, formattedWrite;
import std.utf : isValidDchar, replacementDchar;
import ve.codec : decodeUtf8;

enum Color : ubyte {
    none, // terminal's default
    black, red, green, yellow, blue, magenta, cyan, white,
    brightBlack, brightRed, brightGreen, brightYellow,
    brightBlue, brightMagenta, brightCyan, brightWhite,
}

struct Style {
    Color fg, bg;
    bool bold, dim, italic, inverse;
}

struct Cell {
    dchar ch = ' ';
    Style style;
}

struct Rect {
    int x, y, width, height;

    bool contains(int px, int py) const {
        return px >= x && px < x + width && py >= y && py < y + height;
    }

    Rect intersect(Rect r) const {
        int x0 = max(x, r.x), y0 = max(y, r.y);
        int x1 = min(x + width, r.x + r.width), y1 = min(y + height, r.y + r.height);
        return Rect(x0, y0, max(0, x1 - x0), max(0, y1 - y0));
    }
}

private struct Cursor {
    bool visible;
    int x, y;
}

// The frame being drawn and the one the terminal shows
// flush() returns the escape codes for the difference
final class Screen {
    private int w, h;
    private Cell[] cells, shown;
    private Cursor cursor, shownCursor;
    private bool redrawAll;

    this(int width, int height) { allocate(width, height); }

    int width() const { return w; }
    int height() const { return h; }

    void resize(int width, int height) {
        if (width != w || height != h) allocate(width, height);
    }

    // Starts a frame: blank cells, cursor hidden
    void clear() {
        cells[] = Cell.init;
        cursor = Cursor.init;
    }

    Canvas canvas() { return Canvas(this, Rect(0, 0, w, h)); }

    string flush() {
        auto buf = appender!string;
        Style style;      // terminal's style; plain between flushes
        int tx = -1, ty;  // terminal's cursor
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                Cell cell = cells[y * w + x];
                if (!redrawAll && cell == shown[y * w + x]) continue;
                if (x != tx || y != ty) buf.formattedWrite("\x1b[%d;%dH", y + 1, x + 1);
                buf ~= sgr(style, cell.style);
                buf ~= cell.ch;
                style = cell.style;
                tx = x + 1; // never wraps: after the last column the next cell gets a move
                ty = y;
            }
        }
        if (style != Style.init) buf ~= "\x1b[m";
        if (buf.data.length == 0 && !redrawAll && cursor == shownCursor) return null;

        string result = "\x1b[?25l" ~ buf.data;
        if (cursor.visible) result ~= format("\x1b[%d;%dH\x1b[?25h", cursor.y + 1, cursor.x + 1);
        shown[] = cells[];
        shownCursor = cursor;
        redrawAll = false;
        return result;
    }

    private void allocate(int width, int height) {
        w = width;
        h = height;
        cells = new Cell[](w * h);
        shown = new Cell[](w * h);
        cursor = Cursor.init;
        redrawAll = true;
    }
}

// SGR codes that change the terminal's style from `from` to `to`
private string sgr(Style from, Style to) {
    if (from == to) return null;
    string codes;
    void add(int code) { codes ~= (codes.length ? ";" : "") ~ code.to!string; }
    int color(Color c, int base) { // base: 30 foreground, 40 background
        if (c == Color.none) return base + 9;
        return c <= Color.white ? base + c - Color.black : base + 60 + c - Color.brightBlack;
    }

    if ((from.bold && !to.bold) || (from.dim && !to.dim)) {
        add(22); // turns off both bold and dim
        if (to.bold) add(1);
        if (to.dim) add(2);
    } else {
        if (to.bold && !from.bold) add(1);
        if (to.dim && !from.dim) add(2);
    }
    if (to.italic != from.italic) add(to.italic ? 3 : 23);
    if (to.inverse != from.inverse) add(to.inverse ? 7 : 27);
    if (to.fg != from.fg) add(color(to.fg, 30));
    if (to.bg != from.bg) add(color(to.bg, 40));
    return "\x1b[" ~ codes ~ "m";
}

// A clipped part of the screen
// coordinates are relative to it
struct Canvas {
    private Screen screen;
    Rect area; // in screen coordinates

    void put(int x, int y, dchar ch, Style style = Style.init) {
        x += area.x;
        y += area.y;
        if (!area.contains(x, y)) return;
        if (ch < 0x20 || (ch >= 0x7F && ch < 0xA0) || !isValidDchar(ch)) ch = replacementDchar;
        screen.cells[y * screen.w + x] = Cell(ch, style);
    }

    // Returns the column after the text
    int text(int x, int y, const(char)[] s, Style style = Style.init) {
        bool invalid;
        for (size_t i = 0; i < s.length; ) put(x++, y, decodeUtf8(s, i, invalid), style);
        return x;
    }

    void fill(dchar ch = ' ', Style style = Style.init) {
        foreach (y; 0 .. area.height)
            foreach (x; 0 .. area.width) put(x, y, ch, style);
    }

    Canvas sub(Rect r) {
        return Canvas(screen, Rect(area.x + r.x, area.y + r.y, r.width, r.height).intersect(area));
    }

    // Shows the cursor at x, y; outside the canvas hides it
    void cursor(int x, int y) {
        x += area.x;
        y += area.y;
        screen.cursor = area.contains(x, y) ? Cursor(true, x, y) : Cursor.init;
    }
}

// For tests
version (unittest) {
    string[] rows(const Screen screen) {
        string[] result;
        foreach (y; 0 .. screen.h) {
            dchar[] row;
            foreach (cell; screen.cells[y * screen.w .. (y + 1) * screen.w]) row ~= cell.ch;
            result ~= row.to!string;
        }
        return result;
    }

    Cell cellAt(const Screen screen, int x, int y) { return screen.cells[y * screen.w + x]; }
    bool cursorAt(const Screen screen, int x, int y) { return screen.cursor == Cursor(true, x, y); }
}

// Style changes
unittest {
    Style plain;
    Style bold = {bold: true}, dim = {dim: true}, boldDim = {bold: true, dim: true};
    Style red = {fg: Color.red}, onBrightBlue = {bg: Color.brightBlue};
    Style all = {fg: Color.red, bg: Color.blue, bold: true, italic: true, inverse: true};

    assert(sgr(plain, plain)        is null);
    assert(sgr(plain, bold)         == "\x1b[1m");
    assert(sgr(bold, dim)           == "\x1b[22;2m");
    assert(sgr(boldDim, dim)        == "\x1b[22;2m");
    assert(sgr(boldDim, plain)      == "\x1b[22m");
    assert(sgr(red, plain)          == "\x1b[39m");
    assert(sgr(plain, onBrightBlue) == "\x1b[104m");
    assert(sgr(plain, all)          == "\x1b[1;3;7;31;44m");
    assert(sgr(all, plain)          == "\x1b[22;23;27;39;49m");
}

// Canvas clipping
unittest {
    Screen screen = new Screen(6, 3);
    Canvas canvas = screen.canvas.sub(Rect(2, 1, 3, 2)); // columns 2-4, rows 1-2

    canvas.put(-1, 0, 'a');
    canvas.put( 3, 0, 'b');
    canvas.put( 0, 2, 'c');
    canvas.put( 0, 0, 'x');
    assert(screen.rows == ["      ", "  x   ", "      "]);

    screen.clear();
    assert(canvas.text(1, 1, "hello") == 6);
    assert(canvas.text(-2, 0, "abcd") == 2);
    assert(screen.rows == ["      ", "  cd  ", "   he "]);

    screen.clear();
    canvas.sub(Rect(1, 0, 10, 10)).fill('#');
    assert(screen.rows == ["      ", "   ## ", "   ## "]);
    assert(canvas.sub(Rect(5, 5, 2, 2)).area.width == 0);

    screen.clear();
    canvas.put(0, 0, '\n');
    canvas.put(1, 0, '\u0085');
    canvas.put(2, 0, cast(dchar) 0xD800);
    const(char)[] invalid = ['a', cast(char) 0xFF, 'b'];
    canvas.text(0, 1, invalid);
    assert(screen.rows == ["      ", "  ��� ", "  a�b "]);

    canvas.cursor(1, 1);
    assert(screen.cursor == Cursor(true, 3, 2));
    canvas.cursor(3, 0);
    assert(!screen.cursor.visible);
}

// Flush writes only what changed
unittest {
    Screen screen = new Screen(3, 2);
    Canvas canvas = screen.canvas;
    assert(screen.flush == "\x1b[?25l\x1b[1;1H   \x1b[2;1H   ");
    assert(screen.flush == "");

    canvas.put(1, 0, 'a');
    assert(screen.flush == "\x1b[?25l\x1b[1;2Ha");
    canvas.put(1, 1, 'b');
    canvas.put(2, 1, 'c');
    assert(screen.flush == "\x1b[?25l\x1b[2;2Hbc");

    Style red = {fg: Color.red}, boldRed = {fg: Color.red, bold: true};
    canvas.put(0, 1, 'x', red);
    canvas.put(1, 1, 'y', boldRed);
    assert(screen.flush == "\x1b[?25l\x1b[2;1H\x1b[31mx\x1b[1my\x1b[m");

    canvas.cursor(2, 1);
    assert(screen.flush == "\x1b[?25l\x1b[2;3H\x1b[?25h");
    canvas.put(2, 0, 'z');
    assert(screen.flush == "\x1b[?25l\x1b[1;3Hz\x1b[2;3H\x1b[?25h");
    canvas.cursor(-1, 0);
    assert(screen.flush == "\x1b[?25l");

    // A frame drawn again the same way writes nothing
    void draw() {
        screen.clear();
        canvas.text(0, 0, "ab");
        canvas.cursor(1, 1);
    }
    draw();
    screen.flush();
    draw();
    assert(screen.flush == "");

    // A new size redraws everything
    screen.resize(3, 2);
    assert(screen.flush == "");
    screen.resize(2, 1);
    assert(screen.rows == ["  "]);
    assert(screen.flush == "\x1b[?25l\x1b[1;1H  ");
    assert(screen.flush == "");
}
