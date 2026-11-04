module ve.editor;

import std.file : exists;
import std.format : format;
import std.range : walkLength;
import ve.codec;
import ve.commands;
import ve.document;
import ve.keys;
import ve.screen;
import ve.terminal;
import ve.textview;
import ve.view;

private immutable Style inverted = {inverse: true};

final class Editor {
    Document doc;
    View view;
    Screen screen;
    Keymap keymap;
    string message;
    bool quitPending; // quit was pressed once with unsaved changes
    bool running = true;

    this() {
        keymap = defaultKeymap();
        screen = new Screen(0, 0);
    }

    void open(string path) {
        doc = new Document(path);
        view = new TextView(doc, new Utf8Codec);
        if (!exists(path)) message = "New file";
    }

    void save() {
        try {
            doc.save();
            message = format("Saved %s (%d bytes)", doc.path, doc.length);
        } catch (Exception e) {
            message = "Save failed: " ~ e.msg;
        }
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
        bool confirmQuit = quitPending;
        quitPending = false;
        message = null;

        Cmd cmd = keymap.lookup(view.kind, key);
        switch (cmd) {
            case Cmd.none:
                // display unbound printable characters
                if (key >= 0x20 && key != 0x7F && key < 0x110000) view.input(cast(dchar) key);
                break;
            case Cmd.quit:
                if (doc.dirty && !confirmQuit) {
                    message = "Unsaved changes, Alt+q again to quit without saving, Alt+s to save.";
                    quitPending = true;
                } else {
                    running = false;
                }
                break;
            case Cmd.save:
                save();
                break;
            default:
                view.execute(cmd);
                break;
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
        view.draw(canvas.sub(Rect(0, 0, cols, rows - 2)), true);
        drawStatusBar(canvas.sub(Rect(0, rows - 2, cols, 1)));
        drawMessageBar(canvas.sub(Rect(0, rows - 1, cols, 1)));
    }

    void drawStatusBar(Canvas bar) {
        bar.fill(' ', inverted);
        string right = view.statusRight ~ " ";
        bar.text(bar.area.width - cast(int) right.walkLength, 0, right, inverted);
        bar.text(0, 0, format(" %s%s", doc.path, doc.dirty ? " [modified]" : ""), inverted);
    }

    void drawMessageBar(Canvas bar) {
        bar.text(0, 0, message.length ? message : "Alt+s save | Alt+q quit");
    }
}

unittest {
    import std.algorithm.searching : endsWith, startsWith;
    import std.string : stripRight;

    Editor editor = new Editor;
    editor.open("ve-editor-test-missing-file");
    assert(editor.message == "New file" && !editor.doc.dirty);
    editor.render(64, 4);
    string[] rows = editor.screen.rows;
    assert(rows[0].stripRight == "" && rows[1].stripRight == "~");
    assert(rows[2].startsWith(" ve-editor-test-missing-file ") && rows[2].endsWith(" Ln 1/1, Col 1 · UTF-8 "));
    assert(editor.screen.cellAt(40, 2).style.inverse);
    assert(rows[3].stripRight == "New file");

    editor.processKey('h');
    editor.processKey('i');
    editor.processKey(keyLeft);
    editor.processKey('\r');
    assert(editor.doc.slice(0, editor.doc.length) == "h\ni" && editor.message is null);

    editor.processKey(ctrl('q'));
    assert(editor.running && editor.quitPending);
    editor.render(64, 4);
    rows = editor.screen.rows;
    assert(rows[2].startsWith(" ve-editor-test-missing-file [modified] ") && rows[2].endsWith(" Ln 2/2, Col 1 · UTF-8 "));
    assert(rows[3].startsWith("Unsaved changes, Alt+q again"));
    editor.processKey(keyRight); // any other key cancels
    assert(!editor.quitPending);
    editor.processKey(ctrl('q'));
    editor.processKey(alt('q'));
    assert(!editor.running);
}
