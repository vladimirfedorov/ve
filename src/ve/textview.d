module ve.textview;

import std.algorithm.comparison : max, min;
import std.array : replaceInPlace;
import std.format : format;
import std.range : assumeSorted;
import ve.codec;
import ve.commands;
import ve.document;
import ve.screen;
import ve.view;

enum tabStop = 4;

private immutable Style dimmed = {dim: true}, inverted = {inverse: true};

// Byte offsets where lines start
struct LineIndex {
    size_t[] starts;
    ubyte newline;

    size_t count() const { return starts.length; }

    void rebuild(const Document doc) {
        starts = [0];
        foreach (i; 0 .. doc.length)
            if (doc[i] == newline) starts ~= i + 1;
    }

    // Called after `removed` bytes at pos were replaced by `inserted` bytes
    void update(const Document doc, size_t pos, size_t removed, size_t inserted) {
        size_t first = lineOf(pos) + 1, last = first; // starts after newlines in the removed bytes
        while (last < starts.length && starts[last] <= pos + removed) last++;
        foreach (ref s; starts[last .. $]) s = s - removed + inserted;
        size_t[] added;
        foreach (i; pos .. pos + inserted)
            if (doc[i] == newline) added ~= i + 1;
        starts.replaceInPlace(first, last, added);
    }

    // Line that contains pos
    size_t lineOf(size_t pos) const {
        return starts.assumeSorted.lowerBound(pos + 1).length - 1;
    }
}

// Code and text editor
// The cursor is a byte offset on a character start, never inside a line break
final class TextView : View {
    Codec codec;
    LineIndex lines;
    bool crlf;             // newline inserts "\r\n"
    size_t pos;            // cursor
    size_t goalCol;        // display column kept by vertical moves
    size_t rowOff, colOff; // first visible line and column
    private ubyte cr;
    private size_t pageRows = 1;

    this(Document doc, Codec codec) {
        super(doc);
        this.codec = codec;
        lines.newline = encodeByte('\n');
        cr = encodeByte('\r');
        lines.rebuild(doc);
        foreach (line; 0 .. lines.count - 1) {
            if (lineEnd(line) + 2 == lineStart(line + 1)) {
                crlf = true;
                break;
            }
        }
        doc.listeners ~= &onEdit;
    }

    override string kind() { return "text"; }

    size_t lineStart(size_t line) { return lines.starts[line]; }

    // End of the line's text, before "\n" or "\r\n"
    size_t lineEnd(size_t line) {
        if (line + 1 == lines.count) return doc.length;
        size_t end = lines.starts[line + 1] - 1;
        return end > lines.starts[line] && doc[end - 1] == cr ? end - 1 : end;
    }

    // Display column of p
    size_t column(size_t p) {
        size_t col;
        for (size_t i = lineStart(lines.lineOf(p)); i < p; ) col = advance(col, codec.decode(doc, i));
        return col;
    }

    // - Commands -------------------------------------------------------------

    override bool execute(Cmd cmd) {
        size_t line = lines.lineOf(pos);
        switch (cmd) {
            case Cmd.cursorLeft:
                if (pos > lineStart(line)) moveTo(codec.prevBoundary(doc, pos));
                else if (line > 0) moveTo(lineEnd(line - 1));
                break;
            case Cmd.cursorRight:
                if (pos < lineEnd(line)) moveTo(next(pos));
                else if (line + 1 < lines.count) moveTo(lineStart(line + 1));
                break;
            case Cmd.cursorUp:
                if (line > 0) pos = posAt(line - 1, goalCol);
                break;
            case Cmd.cursorDown:
                if (line + 1 < lines.count) pos = posAt(line + 1, goalCol);
                break;
            case Cmd.pageUp:
                pos = posAt(line > pageRows ? line - pageRows : 0, goalCol);
                break;
            case Cmd.pageDown:
                pos = posAt(min(line + pageRows, lines.count - 1), goalCol);
                break;
            case Cmd.lineStart:
                moveTo(lineStart(line));
                break;
            case Cmd.lineEnd:
                moveTo(lineEnd(line));
                break;
            case Cmd.newline:
                insert(crlf ? [cr, lines.newline] : [lines.newline]);
                break;
            case Cmd.insertTab:
                input('\t');
                break;
            case Cmd.deleteBack:
                if (pos > lineStart(line)) remove(codec.prevBoundary(doc, pos), pos);
                else if (line > 0) remove(lineEnd(line - 1), pos);
                break;
            case Cmd.deleteForward:
                if (pos < lineEnd(line)) remove(pos, next(pos));
                else if (line + 1 < lines.count) remove(pos, lineStart(line + 1));
                break;
            default:
                return false;
        }
        return true;
    }

    // A character the codec can't encode is ignored
    override void input(dchar c) {
        ubyte[4] buf;
        if (size_t n = codec.encode(c, buf)) insert(buf[0 .. n]);
    }

    private void insert(const(ubyte)[] bytes) {
        doc.insert(pos, bytes);
        moveTo(pos + bytes.length);
    }

    private void remove(size_t from, size_t to) {
        doc.remove(from, to - from); // onEdit moves the cursor to `from`
        moveTo(pos);
    }

    private void moveTo(size_t p) {
        pos = p;
        goalCol = column(pos);
    }

    private size_t next(size_t p) {
        codec.decode(doc, p);
        return p;
    }

    // The character start on line that is at or left of display column col
    private size_t posAt(size_t line, size_t col) {
        size_t p = lineStart(line), end = lineEnd(line), c;
        while (p < end) {
            size_t q = p;
            size_t nc = advance(c, codec.decode(doc, q));
            if (nc > col) break;
            p = q;
            c = nc;
        }
        return p;
    }

    private void onEdit(size_t at, size_t removed, size_t inserted) {
        lines.update(doc, at, removed, inserted);
        if (pos > at + removed) pos = pos - removed + inserted;
        else if (pos > at) pos = at;
    }

    // - Drawing --------------------------------------------------------------

    override void draw(Canvas canvas, bool focused) {
        size_t rows = max(canvas.area.height, 1), cols = max(canvas.area.width, 1);
        pageRows = rows;
        size_t line = lines.lineOf(pos), col = column(pos);
        if (line < rowOff) rowOff = line;
        if (line >= rowOff + rows) rowOff = line - rows + 1;
        if (col < colOff) colOff = col;
        if (col >= colOff + cols) colOff = col - cols + 1;

        foreach (y; 0 .. canvas.area.height) {
            if (rowOff + y < lines.count) drawLine(canvas, y, rowOff + y);
            else canvas.put(0, y, '~', dimmed);
        }
        if (focused) canvas.cursor(cast(int)(col - colOff), cast(int)(line - rowOff));
    }

    private void drawLine(Canvas canvas, int y, size_t line) {
        size_t col, end = lineEnd(line);
        for (size_t p = lineStart(line); p < end && col < colOff + canvas.area.width; ) {
            bool invalid;
            dchar c = codec.decode(doc, p, invalid);
            dchar glyph = c;
            Style style;
            if (c == '\t') {
                glyph = ' ';
            } else if (invalid || c == 0x7F || (c >= 0x80 && c < 0xA0)) {
                glyph = '?';
                style = inverted;
            } else if (c < 0x20) {
                glyph = '@' + c; // ^A shows as an inverted A
                style = inverted;
            }
            size_t to = advance(col, c);
            for (; col < to; col++)
                if (col >= colOff) canvas.put(cast(int)(col - colOff), y, glyph, style);
        }
    }

    override string statusRight() {
        size_t line = lines.lineOf(pos), chars;
        for (size_t p = lineStart(line); p < pos; chars++) codec.decode(doc, p);
        return format("Ln %d/%d, Col %d · %s", line + 1, lines.count, chars + 1, codec.name);
    }

    private ubyte encodeByte(dchar c) {
        ubyte[4] buf;
        size_t n = codec.encode(c, buf);
        assert(n == 1, "line breaks must be one byte");
        return buf[0];
    }

    private static size_t advance(size_t col, dchar c) {
        return c == '\t' ? (col / tabStop + 1) * tabStop : col + 1;
    }
}

version (unittest) {
    import std.string : representation;

    private TextView textView(string text) {
        Document doc = new Document;
        doc.insert(0, text.representation);
        doc.dirty = false;
        return new TextView(doc, new Utf8Codec);
    }

    private string text(TextView view) { return cast(string) view.doc.slice(0, view.doc.length); }

    private size_t[2] at(TextView view) { return [view.lines.lineOf(view.pos), view.column(view.pos)]; }
}

// Lines
unittest {
    assert(textView("").lines.starts == [0]);
    assert(textView("ab").lines.starts == [0]);
    assert(textView("ab\n").lines.starts == [0, 3]);
    assert(textView("a\nb\r\nc").lines.starts == [0, 2, 5]);

    TextView view = textView("a\r\nb\rc\r"); // a "\r" is hidden only before "\n"
    assert(view.lineEnd(0) == 1 && view.lineEnd(1) == 7 && view.crlf);
    assert(textView("\r\n").lineEnd(0) == 0);
    assert(textView("\n\n").lineEnd(0) == 0);
    assert(!textView("a\nb\r").crlf);
}

// Line starts updated by edits match a rebuild
unittest {
    import std.random : Random, choice, uniform;

    TextView view = textView("");
    immutable ubyte[] alphabet = ['a', '\n', '\n', '\r', 0xC3, 0xA9];
    Random rnd = Random(1);
    foreach (_; 0 .. 2000) {
        size_t at = uniform(0, view.doc.length + 1, rnd);
        size_t count = uniform(0, min(3, view.doc.length - at) + 1, rnd);
        ubyte[] bytes = new ubyte[](uniform(0, 6, rnd));
        foreach (ref b; bytes) b = alphabet.choice(rnd);
        view.doc.replace(at, count, bytes);

        LineIndex rebuilt = view.lines;
        rebuilt.rebuild(view.doc);
        assert(view.lines.starts == rebuilt.starts);
        assert(view.pos <= view.doc.length);
    }
    assert(view.lines.count > 100);
}

// Typing, moving and deleting
unittest {
    TextView view = textView("");
    foreach (dchar c; "héllo") view.input(c);
    view.execute(Cmd.newline);
    view.input('x');
    assert(view.text == "héllo\nx" && view.doc.dirty && !view.crlf);
    view.execute(Cmd.cursorUp);
    assert(view.pos == 1);
    view.execute(Cmd.cursorRight); // over both bytes of é
    assert(view.pos == 3);
    view.execute(Cmd.deleteBack);
    assert(view.text == "hllo\nx" && view.pos == 1);
    view.execute(Cmd.lineEnd);
    view.execute(Cmd.deleteForward); // joins the lines
    assert(view.text == "hllox" && view.pos == 4);
    view.execute(Cmd.cursorRight);
    view.execute(Cmd.cursorRight);
    assert(view.pos == 5);
    view.execute(Cmd.insertTab);
    assert(view.text == "hllox\t" && view.goalCol == 8);
    assert(!view.execute(Cmd.save));
}

// CRLF line breaks are added and removed whole
unittest {
    TextView view = textView("ab\r\ncd\r\n");
    view.execute(Cmd.lineEnd);
    view.execute(Cmd.newline);
    assert(view.text == "ab\r\n\r\ncd\r\n" && view.pos == 4);
    view.execute(Cmd.deleteBack);
    assert(view.text == "ab\r\ncd\r\n" && view.pos == 2);
    view.execute(Cmd.cursorRight);
    assert(view.pos == 4);
    view.execute(Cmd.cursorLeft);
    assert(view.pos == 2);
    view.execute(Cmd.deleteForward);
    assert(view.text == "abcd\r\n");
}

// Vertical moves keep the display column
unittest {
    TextView view = textView("abcdef\nab\n\tcdef");
    view.execute(Cmd.lineEnd);
    view.execute(Cmd.cursorDown);
    assert(view.at == [1, 2]);
    view.execute(Cmd.cursorDown);
    assert(view.at == [2, 6]);
    view.execute(Cmd.cursorUp);
    view.execute(Cmd.cursorUp);
    assert(view.at == [0, 6]);
    view.execute(Cmd.lineStart);
    view.execute(Cmd.cursorRight);
    view.execute(Cmd.cursorRight);
    view.execute(Cmd.pageDown);
    view.execute(Cmd.pageDown);
    assert(view.at == [2, 0]); // inside the tab: its start
}

// Each invalid byte is one character
unittest {
    TextView view = textView("a\xFF\xFEb");
    view.execute(Cmd.lineEnd);
    assert(view.pos == 4 && view.at == [0, 4]);
    view.execute(Cmd.cursorLeft);
    view.execute(Cmd.cursorLeft);
    assert(view.pos == 2);
    view.execute(Cmd.deleteBack);
    assert(view.text == "a\xFEb");
}

// Edits made elsewhere move the cursor
unittest {
    TextView view = textView("hello world");
    view.pos = 6;                                   // before "world"
    view.doc.insert(0, ">> ".representation);
    assert(view.pos == 9);
    view.doc.insert(9, "big ".representation);      // at the cursor: it stays before
    assert(view.pos == 9 && view.text == ">> hello big world");
    view.doc.remove(7, 4);                          // around the cursor
    assert(view.pos == 7 && view.text == ">> hellg world");
    view.doc.remove(0, 3);
    assert(view.pos == 4);
}

// Drawing
unittest {
    Screen screen = new Screen(10, 4);
    TextView view = textView("a\tb\x01\x7F\xFF\r\nline2\nx");
    view.draw(screen.canvas, true);
    assert(screen.rows == ["a   bA??  ", "line2     ", "x         ", "~         "]);
    assert(!screen.cellAt(4, 0).style.inverse && screen.cellAt(5, 0).style.inverse);
    assert(screen.cellAt(7, 0).style.inverse && screen.cellAt(0, 3).style.dim);
    assert(screen.cursorAt(0, 0));

    view.execute(Cmd.pageDown);
    assert(view.at == [2, 0]);
    screen.clear();
    view.draw(screen.canvas.sub(Rect(0, 0, 10, 2)), false);
    assert(view.rowOff == 1 && !screen.cursorAt(0, 1));

    screen.clear();
    view = textView("0123456789");
    view.execute(Cmd.lineEnd);
    view.draw(screen.canvas.sub(Rect(0, 0, 4, 1)), true);
    assert(screen.rows[0] == "789       " && screen.cursorAt(3, 0));
    assert(view.statusRight == "Ln 1/1, Col 11 · UTF-8");
}
