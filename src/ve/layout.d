module ve.layout;

import std.algorithm.comparison : max, min;
import std.algorithm.mutation : remove;
import std.algorithm.searching : countUntil;
import std.array : insertInPlace;
import std.format : format;
import ve.decoder;
import ve.document;
import ve.screen;

private immutable Style current = {inverse: true};         // the active tab, the focused split's buffer
private immutable Style currentElsewhere = {bold: true};   // the active buffer of another split

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
    Split parent;     // null for the tab's root
    Split[] splits;   // children of a container
    bool vertical;    // children side by side, else stacked
    Buffer[] buffers;
    size_t active;

    bool leaf() const { return splits.length == 0; }
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

    // left to right, top to bottom
    void collect(ref Split[] leaves) {
        if (leaf) leaves ~= this;
        else foreach (s; splits) s.collect(leaves);
    }

    // divides area equally for now
    Rect[] childRects(Rect area) {
        int n = cast(int) splits.length;
        int total = max(vertical ? area.width - (n - 1) : area.height, 0);
        int pos = vertical ? area.x : area.y;
        Rect[] rects;
        foreach (i; 0 .. n) {
            int size = total / n + (i < total % n ? 1 : 0);
            rects ~= vertical ? Rect(pos, area.y, size, area.height) : Rect(area.x, pos, area.width, size);
            pos += size + (vertical ? 1 : 0);
        }
        return rects;
    }

    Rect firstLeafArea(Rect area) { return leaf ? area : splits[0].firstLeafArea(childRects(area)[0]); }

    // focus: the leaf whose active buffer is inverted
    // cursor: whether it shows the cursor
    void draw(Canvas canvas, Split focus, bool cursor, int stripStart = 0) {
        int width = canvas.area.width, height = canvas.area.height;
        if (!leaf) {
            Rect[] rects = childRects(Rect(0, 0, width, height));
            foreach (i, s; splits) {
                s.draw(canvas.sub(rects[i]), focus, cursor, i == 0 ? stripStart : 0);
                if (vertical && i + 1 < splits.length)
                    foreach (y; 0 .. height) canvas.put(rects[i].x + rects[i].width, y, '┃');
            }
            return;
        }
        drawStrip(canvas.sub(Rect(stripStart, 0, width - stripStart, 1)), this is focus);
        buffer.decoder.draw(canvas.sub(Rect(0, 1, width, height - 1)), cursor && this is focus);
    }

    // " a.txt  b.txt*  untitled ": buffers on the left are dropped until the active one fits
    private void drawStrip(Canvas strip, bool focused) {
        string[] labels;
        foreach (b; buffers) labels ~= " " ~ b.title ~ (b.source.dirty ? "* " : " ");
        size_t first;
        while (first < active && width(labels[first .. active + 1]) > strip.area.width) first++;
        int x;
        foreach (i; first .. labels.length)
            x = strip.text(x, 0, labels[i], i != active ? Style.init : focused ? current : currentElsewhere);
    }

    private static int width(string[] labels) {
        int w;
        foreach (label; labels) w += textWidth(label);
        return w;
    }
}

// A top tab
final class Tab {
    Split root;
    Split focused;

    this() { root = focused = new Split; }

    Split[] leaves() {
        Split[] result;
        root.collect(result);
        return result;
    }

    Split split(bool vertical) {
        Split leaf = focused, parent = leaf.parent, added = new Split;
        if (parent && parent.vertical == vertical) {
            added.parent = parent;
            parent.splits.insertInPlace(parent.splits.countUntil(leaf) + 1, added);
        } else {
            Split container = new Split;
            container.vertical = vertical;
            replace(leaf, container);
            container.splits = [leaf, added];
            leaf.parent = added.parent = container;
        }
        return focused = added;
    }

    bool close(Split leaf) {
        Split parent = leaf.parent;
        if (parent is null) return false;
        size_t at = leaves.countUntil(leaf);
        parent.splits = parent.splits.remove(parent.splits.countUntil(leaf));
        if (parent.splits.length == 1) {
            Split only = parent.splits[0];
            replace(parent, only);
            Split grand = only.parent;
            if (!only.leaf && grand && grand.vertical == only.vertical) {
                size_t i = grand.splits.countUntil(only);
                foreach (s; only.splits) s.parent = grand;
                grand.splits = grand.splits[0 .. i] ~ only.splits ~ grand.splits[i + 1 .. $];
            }
        }
        Split[] rest = leaves;
        focused = rest[min(at, rest.length - 1)];
        return true;
    }

    void nextSplit() {
        Split[] all = leaves;
        focused = all[(all.countUntil(focused) + 1) % all.length];
    }

    void prevSplit() {
        Split[] all = leaves;
        focused = all[(all.countUntil(focused) + all.length - 1) % all.length];
    }

    private void replace(Split old, Split by) {
        if (old.parent is null) root = by;
        else old.parent.splits[old.parent.splits.countUntil(old)] = by;
        by.parent = old.parent;
    }
}

// Top tabs, numbered by position
final class Layout {
    Tab[] tabs;
    size_t active;

    Tab tab() { return tabs[active]; }

    void add(Tab t) {
        tabs ~= t;
        active = tabs.length - 1;
    }

    void closeActive() {
        foreach (leaf; tab.leaves)
            foreach (b; leaf.buffers) b.close();
        tabs = tabs.remove(active);
        if (active == tabs.length && active > 0) active--;
    }

    void next() { active = (active + 1) % tabs.length; }
    void prev() { active = (active + tabs.length - 1) % tabs.length; }

    Buffer[] buffers() {
        Buffer[] result;
        foreach (t; tabs)
            foreach (leaf; t.leaves) result ~= leaf.buffers;
        return result;
    }

    // " 1  2 │ a.txt  b.txt "
    void draw(Canvas canvas, bool cursor) {
        int x;
        if (tabs.length > 1) {
            Rect first = tab.root.firstLeafArea(Rect(0, 0, canvas.area.width, canvas.area.height));
            Canvas numbers = canvas.sub(Rect(0, 0, first.width, 1));
            foreach (i; 0 .. tabs.length)
                x = numbers.text(x, 0, format(" %d ", i + 1), i == active ? current : Style.init);
            x = numbers.text(x, 0, "│");
        }
        tab.root.draw(canvas, tab.focused, cursor, x);
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
    split.draw(screen.canvas, split, true);
    assert(screen.rows == [" a.txt  b.d*  untitled        ", "x                             ", "~                             "]);
    assert(!screen.cellAt(1, 0).style.inverse && screen.cellAt(8, 0).style.inverse);
    assert(screen.cursorAt(0, 1));

    screen = new Screen(12, 2);
    split.active = 2;
    split.draw(screen.canvas, null, false);
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

// The split tree
unittest {
    Tab tab = new Tab;
    Split a = tab.root;
    a.add(textBuffer("a"));
    Split b = tab.split(true); // a | b
    assert(tab.root.vertical && tab.root.splits == [a, b] && tab.focused is b && b.parent is tab.root);
    Split c = tab.split(true); // the same direction: a sibling after b
    assert(tab.root.splits == [a, b, c]);
    tab.focused = a;
    Split d = tab.split(false); // a over d, then b, c
    Split column = tab.root.splits[0];
    assert(!column.vertical && column.splits == [a, d] && d.parent is column && tab.leaves == [a, d, b, c]);

    tab.nextSplit();
    assert(tab.focused is b);
    tab.prevSplit();
    tab.prevSplit();
    assert(tab.focused is a);
    tab.prevSplit(); // wraps
    assert(tab.focused is c);

    // A container left with one child is replaced by it; the next leaf gets the focus
    assert(tab.close(d) && tab.root.splits == [a, b, c] && a.parent is tab.root && tab.focused is b);

    // A child in its new parent's direction hands its splits up
    tab.focused = b;
    Split e = tab.split(false); // a | (b over e) | c
    Split f = tab.split(true);  // a | (b over (e | f)) | c
    assert(tab.leaves == [a, b, e, f, c]);
    assert(tab.close(b) && tab.root.splits == [a, e, f, c] && e.parent is tab.root && tab.focused is e);

    // The last leaf: the previous one gets the focus
    assert(tab.close(c) && tab.focused is f);
    tab.close(e);
    tab.close(f);
    assert(tab.root is a && a.parent is null && tab.leaves == [a] && tab.focused is a);
    assert(!tab.close(a)); // the root
}

// Children's areas and the separators cover the area exactly once
unittest {
    import std.algorithm.searching : all, maxElement, minElement;

    foreach (vertical; [false, true])
    foreach (n; 1 .. 6)
    foreach (w; 0 .. 30)
    foreach (h; [0, 1, 7, 24]) {
        Split split = new Split;
        split.vertical = vertical;
        foreach (_; 0 .. n) split.splits ~= new Split;
        Rect area = Rect(3, 2, w, h);
        Rect[] rects = split.childRects(area);
        int[] covered = new int[](w * h);
        void cover(int x, int y) {
            if (area.contains(x, y)) covered[(y - area.y) * w + x - area.x]++;
        }
        foreach (i, r; rects) {
            assert(r.width == 0 || r.height == 0 || area.intersect(r) == r);
            foreach (y; r.y .. r.y + r.height)
                foreach (x; r.x .. r.x + r.width) cover(x, y);
            if (vertical && i + 1 < n)
                foreach (y; area.y .. area.y + h) cover(r.x + r.width, y);
        }
        assert(covered.all!(c => c == 1));
        int[] sizes;
        foreach (r; rects) sizes ~= vertical ? r.width : r.height;
        assert(sizes.maxElement - sizes.minElement <= 1);
    }
}

// Drawing splits
unittest {
    Layout layout = new Layout;
    Tab tab = new Tab;
    layout.add(tab);
    tab.root.add(textBuffer("a"));
    tab.root.buffer.source.insert(0, "left".representation);
    tab.split(true).add(textBuffer("b"));

    Screen screen = new Screen(21, 4);
    layout.draw(screen.canvas, true);
    assert(screen.rows == [" a*       ┃ b        ", "left      ┃          ", "~         ┃~         ", "~         ┃~         "]);
    assert(screen.cellAt(1, 0).style.bold && !screen.cellAt(1, 0).style.inverse); // active in another split
    assert(screen.cellAt(12, 0).style.inverse);                                   // active in the focused split
    assert(screen.cursorAt(11, 1));

    // The tab numbers start the top-left split's strip and stay inside it
    Tab two = new Tab;
    layout.add(two);
    two.root.add(textBuffer("c"));
    layout.prev();
    screen.clear();
    layout.draw(screen.canvas, false);
    assert(screen.rows[0] == " 1  2 │ a*┃ b        " && !screen.cursorAt(11, 1));

    // Stacked: the lower split's strip separates them
    tab.focused = tab.root.splits[1];
    tab.split(false).add(textBuffer("d"));
    screen = new Screen(21, 6);
    layout.draw(screen.canvas, true);
    assert(screen.rows == [" 1  2 │ a*┃ b        ", "left      ┃          ", "~         ┃~         ",
                           "~         ┃ d        ", "~         ┃          ", "~         ┃~         "]);
    assert(screen.cursorAt(11, 4));
}
