module ve.layout;

import std.algorithm.mutation : remove;
import std.array : insertInPlace;
import std.format : format;
import ve.decoder;
import ve.document;
import ve.screen;

private immutable Style activeTab = {inverse: true};

// One bottom tab of a split: a source shown through a decoder
final class Buffer {
    Document source; // a file's bytes, shared by every buffer on that file
    Decoder decoder;

    this(Document source, Decoder decoder) {
        this.source = source;
        this.decoder = decoder;
    }

    string title() { return source.name; }
    void close() { decoder.close(); }
}

// Buffers shown one at a time under a tab strip
final class Split {
    Buffer[] buffers;
    size_t active;

    Buffer buffer() { return buffers[active]; }

    // Adds b after the active buffer and activates it
    void add(Buffer b) {
        size_t at = buffers.length ? active + 1 : 0;
        buffers.insertInPlace(at, b);
        active = at;
    }

    // Activates the next buffer, or the previous one if it was the last
    void closeActive() {
        buffers[active].close();
        buffers = buffers.remove(active);
        if (active == buffers.length && active > 0) active--;
    }

    void next() { active = (active + 1) % buffers.length; }
    void prev() { active = (active + buffers.length - 1) % buffers.length; }

    // The strip starts at column stripStart of the first row; the tab numbers come before it
    void draw(Canvas canvas, bool focused, int stripStart = 0) {
        int width = canvas.area.width;
        drawStrip(canvas.sub(Rect(stripStart, 0, width - stripStart, 1)));
        buffer.decoder.draw(canvas.sub(Rect(0, 1, width, canvas.area.height - 1)), focused);
    }

    // " a.txt  b.txt*  untitled ": buffers on the left are dropped until the active one fits
    private void drawStrip(Canvas strip) {
        string[] labels;
        foreach (b; buffers) labels ~= " " ~ b.title ~ (b.source.dirty ? "* " : " ");
        size_t first;
        while (first < active && width(labels[first .. active + 1]) > strip.area.width) first++;
        int x;
        foreach (i; first .. labels.length) x = strip.text(x, 0, labels[i], i == active ? activeTab : Style.init);
    }

    private static int width(string[] labels) {
        int w;
        foreach (label; labels) w += textWidth(label);
        return w;
    }
}

// A top tab: its splits (one for now) and the one that gets the keys
final class Tab {
    Split root;
    Split focused;

    this() { root = focused = new Split; }
}

// Top tabs, numbered by position
final class Layout {
    Tab[] tabs;
    size_t active;

    Tab tab() { return tabs[active]; }

    // Appends t and activates it, so the other tabs keep their numbers
    void add(Tab t) {
        tabs ~= t;
        active = tabs.length - 1;
    }

    // Activates the next tab, or the previous one if it was the last
    void closeActive() {
        foreach (b; tab.root.buffers) b.close();
        tabs = tabs.remove(active);
        if (active == tabs.length && active > 0) active--;
    }

    void next() { active = (active + 1) % tabs.length; }
    void prev() { active = (active + tabs.length - 1) % tabs.length; }

    // Every buffer in every tab
    Buffer[] buffers() {
        Buffer[] result;
        foreach (t; tabs) result ~= t.root.buffers;
        return result;
    }

    // The first row: " 1  2 │ a.txt  b.txt "; the tab numbers show only with 2+ tabs
    void draw(Canvas canvas, bool focused) {
        int x;
        if (tabs.length > 1) {
            foreach (i; 0 .. tabs.length)
                x = canvas.text(x, 0, format(" %d ", i + 1), i == active ? activeTab : Style.init);
            x = canvas.text(x, 0, "│");
        }
        tab.root.draw(canvas, focused, x);
    }
}

version (unittest) {
    import std.string : representation;
    import ve.codec : Utf8Codec;
    import ve.textdecoder : TextDecoder;

    private Buffer textBuffer(string path) {
        Document doc = new Document;
        doc.path = path;
        return new Buffer(doc, new TextDecoder(doc, new Utf8Codec));
    }
}

// Adding, switching and closing
unittest {
    Split split = new Split;
    Buffer a = textBuffer("a"), b = textBuffer("b"), c = textBuffer("c");
    split.add(a);
    split.add(b);
    split.active = 0;
    split.add(c);
    assert(split.buffers == [a, c, b] && split.buffer is c);

    split.next();
    assert(split.buffer is b);
    split.next();
    assert(split.buffer is a);
    split.prev();
    assert(split.buffer is b);

    assert(b.source.listeners.length == 1);
    split.closeActive(); // the last one: the one before becomes active
    assert(split.buffers == [a, c] && split.buffer is c && b.source.listeners.length == 0);
    split.active = 0;
    split.closeActive();
    assert(split.buffers == [c] && split.buffer is c);
    split.closeActive();
    assert(split.buffers.length == 0);
}

// Tab strip
unittest {
    Split split = new Split;
    split.add(textBuffer("src/a.txt"));
    split.add(textBuffer("b.d"));
    split.add(textBuffer(null));
    split.buffers[1].source.insert(0, "x".representation);
    split.active = 1;

    Screen screen = new Screen(30, 3);
    split.draw(screen.canvas, true);
    assert(screen.rows == [" a.txt  b.d*  untitled        ", "x                             ", "~                             "]);
    assert(!screen.cellAt(1, 0).style.inverse && screen.cellAt(8, 0).style.inverse);
    assert(screen.cursorAt(0, 1));

    screen = new Screen(12, 2);
    split.active = 2;
    split.draw(screen.canvas, false);
    assert(screen.rows[0] == " untitled   ");
}

// Top tabs
unittest {
    Layout layout = new Layout;
    Tab one = new Tab, two = new Tab, three = new Tab;
    layout.add(one);
    one.root.add(textBuffer("a"));
    Screen screen = new Screen(20, 4);
    layout.draw(screen.canvas, true);
    assert(screen.rows[0] == " a                  "); // one tab: no top bar

    layout.add(two);
    two.root.add(textBuffer("b"));
    two.root.add(textBuffer("c"));
    layout.add(three);
    three.root.add(textBuffer("d"));
    assert(layout.tab is three && layout.buffers.length == 4);
    layout.next();
    assert(layout.tab is one);
    layout.prev();
    layout.prev();
    assert(layout.tab is two);

    screen.clear();
    layout.draw(screen.canvas, true);
    assert(screen.rows == [" 1  2  3 │ b  c     ", "                    ", "~                   ", "~                   "]);
    assert(!screen.cellAt(1, 0).style.inverse && screen.cellAt(4, 0).style.inverse); // tab 2
    assert(!screen.cellAt(11, 0).style.inverse && screen.cellAt(14, 0).style.inverse); // buffer c
    assert(screen.cursorAt(0, 1));

    // Closing a tab closes its buffers; the next tab becomes active
    Buffer b = two.root.buffers[0];
    assert(b.source.listeners.length == 1);
    layout.closeActive();
    assert(layout.tabs == [one, three] && layout.tab is three && b.source.listeners.length == 0);
    layout.closeActive();
    assert(layout.tabs == [one] && layout.tab is one);
}
