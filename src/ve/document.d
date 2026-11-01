module ve.document;

import core.stdc.string : memmove;
import std.algorithm.comparison : max, min;
import std.file : exists, read;
import std.stdio : File;

// removed bytes at pos were replaced by inserted bytes - called after every edit
alias EditListener = void delegate(size_t pos, size_t removed, size_t inserted);

private enum size_t minSize = 64;

final class Document {
    string path;
    bool dirty;
    EditListener[] listeners;

    // gap buffer
    private ubyte[] buf;
    private size_t gapStart, gapEnd;

    this() { }

    this(string path) {
        this.path = path;
        if (exists(path)) {
            buf = cast(ubyte[]) read(path);
            gapStart = gapEnd = buf.length;
        }
    }

    size_t length() const { return buf.length - (gapEnd - gapStart); }
    size_t opDollar() const { return length; }

    ubyte opIndex(size_t i) const {
        assert(i < length);
        return i < gapStart ? buf[i] : buf[i + (gapEnd - gapStart)];
    }

    // - Document commands ----------------------------------------------------

    // the commands below expect parameters to be correct

    // Copy of the bytes in from .. to
    ubyte[] slice(size_t from, size_t to) const {
        assert(from <= to && to <= length);
        ubyte[] result = new ubyte[](to - from);
        size_t n = from < gapStart ? min(to, gapStart) - from : 0; // part before the gap
        size_t gap = gapEnd - gapStart;
        result[0 .. n] = buf[from .. from + n];
        result[n .. $] = buf[from + n + gap .. to + gap];
        return result;
    }

    // Replace count bytes at pos with bytes
    void replace(size_t pos, size_t count, const(ubyte)[] bytes) {
        assert(pos <= length && count <= length - pos);
        if (count == 0 && bytes.length == 0) return;
        moveGap(pos);
        gapEnd += count; // the removed bytes join the gap
        reserve(bytes.length);
        buf[gapStart .. gapStart + bytes.length] = bytes[];
        gapStart += bytes.length;
        dirty = true;
        foreach (listener; listeners) listener(pos, count, bytes.length);
    }

    void insert(size_t pos, const(ubyte)[] bytes) { replace(pos, 0, bytes); }
    void remove(size_t pos, size_t count) { replace(pos, count, null); }
    void overwrite(size_t pos, const(ubyte)[] bytes) { replace(pos, min(bytes.length, length - pos), bytes); }

    // Writes the bytes to path; throws on failure
    void save() {
        assert(path !is null, "save of an untitled document");
        File file = File(path, "wb");
        file.rawWrite(buf[0 .. gapStart]);
        file.rawWrite(buf[gapEnd .. $]);
        file.close(); // a failed flush throws here, before the document counts as saved
        dirty = false;
    }

    // Moves the gap to start at pos
    // The moved bytes and their target overlap when the gap is shorter than the distance
    private void moveGap(size_t pos) {
        if (pos < gapStart) {
            size_t n = gapStart - pos; // bytes in pos .. gapStart go to the end of the gap
            memmove(&buf[gapEnd - n], &buf[pos], n);
            gapStart -= n;
            gapEnd -= n;
        } else if (pos > gapStart) {
            size_t n = pos - gapStart; // bytes after the gap go to its start
            memmove(&buf[gapStart], &buf[gapEnd], n);
            gapStart += n;
            gapEnd += n;
        }
    }

    // Makes the gap at least n bytes long
    private void reserve(size_t n) {
        if (gapEnd - gapStart >= n) return;
        size_t after = buf.length - gapEnd;
        size_t size = max(2 * buf.length, length + n, minSize);
        ubyte[] grown = new ubyte[](size);
        grown[0 .. gapStart] = buf[0 .. gapStart];
        grown[$ - after .. $] = buf[gapEnd .. $];
        buf = grown;
        gapEnd = size - after;
    }
}

// Random edits, checked against a plain array
unittest {
    import std.random : Random, uniform;

    Document doc = new Document;
    assert(doc.path is null && doc.length == 0 && !doc.dirty);

    ubyte[] model;
    Random rnd = Random(1);
    foreach (step; 0 .. 2000) {
        size_t pos = uniform(0, model.length + 1, rnd);
        ubyte[] bytes = new ubyte[](uniform(0, 8, rnd));
        foreach (ref b; bytes) b = uniform!ubyte(rnd);

        int op = uniform(0, 4, rnd); // inserts twice as often, so the document grows
        if (op <= 1) {
            doc.insert(pos, bytes);
            model = model[0 .. pos] ~ bytes ~ model[pos .. $];
        } else if (op == 2) {
            size_t count = uniform(0, min(8, model.length - pos) + 1, rnd);
            doc.remove(pos, count);
            model = model[0 .. pos] ~ model[pos + count .. $];
        } else {
            size_t count = min(bytes.length, model.length - pos);
            doc.overwrite(pos, bytes);
            model = model[0 .. pos] ~ bytes ~ model[pos + count .. $];
        }

        assert(doc.length == model.length);
        foreach (i, b; model) assert(doc[i] == b);
        size_t from = uniform(0, model.length + 1, rnd);
        size_t to = uniform(from, model.length + 1, rnd);
        assert(doc.slice(from, to) == model[from .. to]);
    }
    assert(doc.slice(0, doc.length) == model);
}

// Listeners
unittest {
    import std.string : representation;

    struct Edit { size_t pos, removed, inserted; }
    Edit[] edits;
    ubyte[] seen; // the document's bytes when the listener ran

    Document doc = new Document;
    doc.listeners ~= (size_t pos, size_t removed, size_t inserted) {
        edits ~= Edit(pos, removed, inserted);
        seen = doc.slice(0, doc.length);
    };

    doc.insert(0, "hello".representation);
    assert(edits == [Edit(0, 0, 5)] && seen == "hello" && doc.dirty);
    doc.remove(1, 3);
    assert(edits[$ - 1] == Edit(1, 3, 0) && seen == "ho");
    doc.overwrite(0, "J".representation);
    assert(edits[$ - 1] == Edit(0, 1, 1) && seen == "Jo");
    doc.overwrite(1, "abc".representation); // past the end
    assert(edits[$ - 1] == Edit(1, 1, 3) && seen == "Jabc");
    doc.replace(1, 2, "XYZ".representation);
    assert(edits[$ - 1] == Edit(1, 2, 3) && seen == "JXYZc");
    assert(edits.length == 5);

    // Empty edits change nothing and notify nobody
    doc.dirty = false;
    doc.insert(2, null);
    doc.remove(2, 0);
    doc.overwrite(5, null);
    assert(edits.length == 5 && !doc.dirty);
}

// Load and save
unittest {
    import std.conv : to;
    import std.file : deleteFile = remove, readFile = read, tempDir, writeFile = write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.string : representation;

    // BOM, CRLF, a truncated UTF-8 sequence, NUL, invalid UTF-8 byte
    immutable ubyte[] bytes = [0xEF, 0xBB, 0xBF, 'a', '\r', '\n', 0xC3, 'b', 0x00, 0xFF, '\n'];
    string path = buildPath(tempDir, "ve-document-test-" ~ thisProcessID.to!string);
    writeFile(path, bytes);
    scope(exit) deleteFile(path);

    Document doc = new Document(path);
    assert(doc.path == path && !doc.dirty && doc.slice(0, doc.length) == bytes);
    doc.insert(4, "xyz".representation);
    doc.remove(4, 3); // leaves the gap in the middle, save writes both parts
    assert(doc.dirty);
    doc.save();
    assert(!doc.dirty && cast(ubyte[]) readFile(path) == bytes);

    // A missing file is a new, empty document
    string missing = path ~ "-new";
    assert(!exists(missing));
    doc = new Document(missing);
    assert(doc.path == missing && doc.length == 0 && !doc.dirty);
    doc.insert(0, "new".representation);
    doc.save();
    scope(exit) deleteFile(missing);
    assert(cast(ubyte[]) readFile(missing) == "new");
}
