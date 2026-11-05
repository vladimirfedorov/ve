module ve.editor;

import std.algorithm.comparison : max;
import std.algorithm.iteration : filter;
import std.algorithm.mutation : remove;
import std.algorithm.searching : canFind, count;
import std.array : array, insertInPlace;
import std.conv : to;
import std.file : exists;
import std.format : format;
import std.path : absolutePath, buildNormalizedPath;
import ve.codec;
import ve.commands;
import ve.decoder;
import ve.document;
import ve.keys;
import ve.layout;
import ve.screen;
import ve.terminal;
import ve.textdecoder;

private immutable Style inverted = {inverse: true};
private enum hint = "Alt+s save | Alt+o open | Alt+w close | Alt+q quit";

// A question in the message bar
private struct Prompt {
    string label;
    dchar[] input;
    size_t cursor;
    void delegate(string answer) done; // null while no prompt is open
}

final class Editor {
    Split split;
    Screen screen;
    Keymap keymap;
    string message;
    bool running = true;
    private Prompt prompt;
    private Cmd pending;      // command that is confirmed by repeating it
    private string overwrite; // existing file that saveAs asked about

    this() {
        keymap = defaultKeymap();
        screen = new Screen(0, 0);
        split = new Split;
    }

    Buffer buffer() { return split.buffer; }
    Decoder decoder() { return split.buffer.decoder; }

    // Opens the file in a new buffer
    // activates the buffer if the file is opened
    // throws if the file can't be read
    void open(string path) {
        foreach (i, b; split.buffers) {
            if (b.source.path.length && samePath(b.source.path, path)) {
                split.active = i;
                return;
            }
        }
        split.add(textBuffer(new Document(path)));
        if (!exists(path)) message = "New file";
    }

    void openUntitled() { split.add(textBuffer(new Document)); }

    void save() {
        if (buffer.source.path.length == 0) return saveAs(false);
        saveDocument(buffer.source);
    }

    // Overwrite existing files only when saveAs is repeated
    void saveAs(bool confirmed) {
        Document doc = buffer.source;
        ask("Save as: ", confirmed ? overwrite : doc.path, (string path) {
            if (path.length == 0) return;
            bool same = doc.path.length && samePath(doc.path, path);
            if (exists(path) && !same && !(confirmed && path == overwrite)) {
                message = format("%s exists, save as again to overwrite", path);
                overwrite = path;
                pending = Cmd.saveAs;
                return;
            }
            string old = doc.path;
            doc.path = path;
            if (!saveDocument(doc)) doc.path = old;
        });
    }

    // Closing the last buffer quits
    void closeBuffer(bool confirmed) {
        Document doc = buffer.source;
        if (doc.dirty && !confirmed && split.buffers.count!(b => b.source is doc) == 1) {
            message = format("%s has unsaved changes, close again to discard", doc.name);
            pending = Cmd.closeBuffer;
            return;
        }
        split.closeActive();
        if (split.buffers.length == 0) running = false;
    }

    void quit(bool confirmed) {
        Document[] modified = documents.filter!(d => d.dirty).array;
        if (modified.length && !confirmed) {
            message = modified.length == 1
                ? format("%s has unsaved changes, quit again to discard", modified[0].name)
                : format("%d files have unsaved changes, quit again to discard", modified.length);
            pending = Cmd.quit;
        } else {
            running = false;
        }
    }

    // Every open document, once
    Document[] documents() {
        Document[] docs;
        foreach (b; split.buffers)
            if (!docs.canFind!(d => d is b.source)) docs ~= b.source;
        return docs;
    }

    // Opens a prompt in the message bar; done gets the text when Enter is pressed
    void ask(string label, string initial, void delegate(string answer) done) {
        dchar[] input;
        bool invalid;
        for (size_t i = 0; i < initial.length; ) input ~= decodeUtf8(initial, i, invalid);
        prompt = Prompt(label, input, input.length, done);
    }

    void run() {
        enableRawMode();
        scope(exit) disableRawMode();
        writeAll("\x1b[?1049h");                     // switch to the alternate screen
        scope(exit) writeAll("\x1b[?25h\x1b[?1049l"); // and give the shell its screen and cursor back

        while (running) {
            // also after the input timeout: picks up a new terminal size, writes nothing otherwise
            refresh();
            int key = readKey();
            if (key != keyNone) processKey(key);
        }
    }

    void processKey(int key) {
        message = null;
        if (prompt.done) return promptKey(key);

        Cmd confirming = pending;
        pending = Cmd.none;
        Cmd cmd = keymap.lookup(decoder.kind, key);
        switch (cmd) {
            case Cmd.none:
                // display unbound printable characters
                if (key >= 0x20 && key != 0x7F && key < 0x110000) decoder.input(cast(dchar) key);
                break;
            case Cmd.quit:      quit(confirming == Cmd.quit); break;
            case Cmd.save:      save(); break;
            case Cmd.saveAs:    saveAs(confirming == Cmd.saveAs); break;
            case Cmd.open:      ask("Open: ", null, &openAnswer); break;
            case Cmd.closeBuffer: closeBuffer(confirming == Cmd.closeBuffer); break;
            case Cmd.nextBuffer:  split.next(); break;
            case Cmd.prevBuffer:  split.prev(); break;
            default:              decoder.execute(cmd); break;
        }
    }

    // Edits with the text decoder's keys; Enter answers, Esc cancels, other commands are ignored
    private void promptKey(int key) {
        if (key == 0x1b) {
            prompt = Prompt.init;
            return;
        }
        switch (keymap.lookup("text", key)) {
            case Cmd.cursorLeft:
                if (prompt.cursor > 0) prompt.cursor--;
                break;
            case Cmd.cursorRight:
                if (prompt.cursor < prompt.input.length) prompt.cursor++;
                break;
            case Cmd.lineStart:
                prompt.cursor = 0;
                break;
            case Cmd.lineEnd:
                prompt.cursor = prompt.input.length;
                break;
            case Cmd.deleteBack:
                if (prompt.cursor > 0) prompt.input = prompt.input.remove(--prompt.cursor);
                break;
            case Cmd.deleteForward:
                if (prompt.cursor < prompt.input.length) prompt.input = prompt.input.remove(prompt.cursor);
                break;
            case Cmd.newline:
                auto done = prompt.done;
                string answer = prompt.input.to!string;
                prompt = Prompt.init;
                done(answer);
                break;
            case Cmd.none:
                if (key >= 0x20 && key != 0x7F && key < 0x110000)
                    prompt.input.insertInPlace(prompt.cursor++, cast(dchar) key);
                break;
            default:
                break;
        }
    }

    private void openAnswer(string path) {
        if (path.length == 0) return;
        try {
            open(path);
        } catch (Exception e) {
            message = "Open failed: " ~ e.msg;
        }
    }

    private bool saveDocument(Document doc) {
        try {
            doc.save();
            message = format("Saved %s (%d bytes)", doc.path, doc.length);
            return true;
        } catch (Exception e) {
            message = "Save failed: " ~ e.msg;
            return false;
        }
    }

    // - Rendering ------------------------------------------------------------

    void refresh() {
        int rows = 24, cols = 80;
        getWindowSize(rows, cols);
        render(cols, rows);
        writeAll(screen.flush());
    }

    void render(int cols, int rows) {
        screen.resize(cols, rows);
        screen.clear();
        Canvas canvas = screen.canvas;
        split.draw(canvas.sub(Rect(0, 0, cols, rows - 2)), prompt.done is null);
        drawStatusBar(canvas.sub(Rect(0, rows - 2, cols, 1)));
        drawMessageBar(canvas.sub(Rect(0, rows - 1, cols, 1)));
    }

    void drawStatusBar(Canvas bar) {
        bar.fill(' ', inverted);
        string right = decoder.statusRight ~ " ";
        bar.text(bar.area.width - textWidth(right), 0, right, inverted);
        Document doc = buffer.source;
        string name = doc.path.length ? doc.path : "untitled";
        bar.text(0, 0, format(" %s%s", name, doc.dirty ? " [modified]" : ""), inverted);
    }

    void drawMessageBar(Canvas bar) {
        if (prompt.done is null) {
            bar.text(0, 0, message.length ? message : hint);
            return;
        }
        int x = bar.text(0, 0, prompt.label);
        size_t room = max(bar.area.width - x, 1);
        size_t first = prompt.cursor >= room ? prompt.cursor - room + 1 : 0; // keeps the cursor visible
        foreach (i, c; prompt.input[first .. $]) bar.put(x + cast(int) i, 0, c);
        bar.cursor(x + cast(int)(prompt.cursor - first), 0);
    }
}

private Buffer textBuffer(Document doc) { return new Buffer(doc, new TextDecoder(doc, new Utf8Codec)); }

private bool samePath(string a, string b) {
    return absolutePath(a).buildNormalizedPath == absolutePath(b).buildNormalizedPath;
}

version (unittest) {
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, writeFile = write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    private void type(Editor editor, string text) {
        foreach (dchar c; text) editor.processKey(c);
    }

    // A new directory, removed by the caller
    private string testDir(string name) {
        string dir = buildPath(tempDir, format("ve-%s-%s", name, thisProcessID));
        mkdirRecurse(dir);
        return dir;
    }
}

// One file: bars and the quit warning
unittest {
    import std.algorithm.searching : endsWith, startsWith;
    import std.string : stripRight;

    Editor editor = new Editor;
    editor.open("ve-editor-test-missing-file");
    assert(editor.message == "New file" && !editor.buffer.source.dirty);
    editor.render(64, 5);
    string[] rows = editor.screen.rows;
    assert(rows[0].stripRight == " ve-editor-test-missing-file" && editor.screen.cellAt(1, 0).style.inverse);
    assert(rows[1].stripRight == "" && rows[2].stripRight == "~");
    assert(rows[3].startsWith(" ve-editor-test-missing-file ") && rows[3].endsWith(" Ln 1/1, Col 1 · UTF-8 "));
    assert(editor.screen.cellAt(40, 3).style.inverse);
    assert(rows[4].stripRight == "New file");

    editor.type("hi");
    editor.processKey(keyLeft);
    editor.processKey('\r');
    assert(editor.buffer.source.slice(0, editor.buffer.source.length) == "h\ni" && editor.message is null);
    editor.render(64, 5);
    assert(editor.screen.rows[4].stripRight == hint);

    editor.processKey(ctrl('q'));
    assert(editor.running && editor.message == "ve-editor-test-missing-file has unsaved changes, quit again to discard");
    editor.processKey(keyRight); // any other key cancels
    editor.processKey(ctrl('q'));
    assert(editor.running);
    editor.processKey(alt('q'));
    assert(!editor.running);
}

// Several buffers: open, switch, close, quit
unittest {
    import std.algorithm.searching : startsWith;

    string dir = testDir("editor");
    scope(exit) rmdirRecurse(dir);
    string a = buildPath(dir, "a.txt"), b = buildPath(dir, "b.txt"), c = buildPath(dir, "c.txt");
    writeFile(a, "aaa\n");
    writeFile(b, "bbb\n");

    Editor editor = new Editor;
    editor.open(a);
    editor.open(b);
    editor.open(buildPath(dir, "sub", "..", ".", "a.txt")); // the same file: its buffer
    assert(editor.split.buffers.length == 2 && editor.buffer.source.path == a);
    editor.processKey(alt('.'));
    assert(editor.buffer.source.path == b);
    editor.processKey(alt('.'));
    assert(editor.buffer.source.path == a);
    editor.processKey(alt(','));
    assert(editor.buffer.source.path == b);

    editor.processKey(ctrl('o'));
    editor.type(c);
    editor.processKey('\r');
    assert(editor.message == "New file" && editor.split.buffers.length == 3 && editor.split.active == 2);
    editor.processKey(ctrl('o'));
    editor.type(dir);
    editor.processKey('\r');
    assert(editor.message.startsWith("Open failed: ") && editor.split.buffers.length == 3);

    // Closing a modified document asks once; another key cancels
    editor.type("x");
    editor.processKey(ctrl('w'));
    assert(editor.message == "c.txt has unsaved changes, close again to discard");
    editor.processKey(keyLeft);
    editor.processKey(ctrl('w'));
    assert(editor.split.buffers.length == 3);
    editor.processKey(ctrl('w'));
    assert(editor.split.buffers.length == 2 && editor.buffer.source.path == b && !exists(c));

    editor.type("y");
    editor.processKey(alt(','));
    editor.type("z");
    editor.processKey(ctrl('q'));
    assert(editor.message == "2 files have unsaved changes, quit again to discard");
    editor.processKey(ctrl('s'));
    assert(readText(a) == "zaaa\n");
    editor.processKey(ctrl('q'));
    assert(editor.message == "b.txt has unsaved changes, quit again to discard");

    // A clean buffer closes at once; closing the last one quits
    editor.processKey(ctrl('w'));
    assert(editor.split.buffers.length == 1 && editor.running);
    editor.processKey(ctrl('w'));
    editor.processKey(ctrl('w'));
    assert(!editor.running && readText(b) == "bbb\n");
}

// The prompt
unittest {
    Editor editor = new Editor;
    editor.openUntitled();
    string answer;
    editor.ask("Name: ", "abc", (string s) { answer = s; });
    editor.processKey(keyLeft);
    editor.processKey(0x7F);
    editor.processKey('X');
    editor.processKey(keyHome);
    editor.processKey(keyDelete);
    editor.processKey(ctrl('s')); // other commands are ignored
    editor.processKey(keyEnd);
    editor.type("dé");
    editor.render(20, 4);
    assert(editor.screen.rows[3] == "Name: Xcdé          " && editor.screen.cursorAt(10, 3));
    editor.processKey('\r');
    assert(answer == "Xcdé" && !editor.buffer.source.dirty);
    editor.render(20, 4);
    assert(editor.screen.cursorAt(0, 1));

    editor.ask("Open: ", "0123456789", (string s) { answer = s; });
    editor.render(12, 4);
    assert(editor.screen.rows[3] == "Open: 56789 " && editor.screen.cursorAt(11, 3));
    editor.processKey(0x1b); // Esc
    editor.render(12, 4);
    assert(editor.screen.rows[3] == hint[0 .. 12] && answer == "Xcdé");
}

// Untitled documents and save as
unittest {
    string dir = testDir("save-as");
    scope(exit) rmdirRecurse(dir);
    string a = buildPath(dir, "a.txt"), u = buildPath(dir, "u.txt");
    writeFile(a, "aaa");

    Editor editor = new Editor;
    editor.openUntitled();
    editor.type("hello");
    editor.processKey(ctrl('s')); // asks for a path
    editor.type(u);
    editor.processKey('\r');
    assert(readText(u) == "hello" && editor.buffer.source.path == u && !editor.buffer.source.dirty);
    assert(editor.message == format("Saved %s (5 bytes)", u));

    // Another file that exists needs a second save as
    editor.processKey(alt('S'));
    foreach (_; 0 .. u.length) editor.processKey(0x7F);
    editor.type(a);
    editor.processKey('\r');
    assert(editor.message == a ~ " exists, save as again to overwrite" && readText(a) == "aaa");
    editor.processKey(alt('S')); // starts with that path
    editor.processKey('\r');
    assert(readText(a) == "hello" && editor.buffer.source.path == a);

    // Its own path just saves
    editor.type("!");
    editor.processKey(alt('S'));
    editor.processKey('\r');
    assert(readText(a) == "hello!" && !editor.buffer.source.dirty);
}
