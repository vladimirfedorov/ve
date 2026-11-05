module ve.commands;

import std.algorithm.searching : canFind;
import std.array : split;
import std.conv : to, ConvException;
import std.file : exists, readText;
import std.format : format;
import std.process : environment;
import std.string : lineSplitter, strip;
import ve.keys;

// Editor actions that keys are bound to
enum Cmd {
    none, // unbinds action
    quit, save, saveAs,
    open, closeBuffer, nextBuffer, prevBuffer,
    cursorLeft, cursorRight, cursorUp, cursorDown,
    lineStart, lineEnd, pageUp, pageDown,
    newline, deleteBack, deleteForward, insertTab,
}

// Key bindings by section
// "global"  every decoder
// "text"    code/text
// "hex"     raw hex editor
struct Keymap {
    Cmd[int][string] sections;

    // Command for `key` in the `decoder` section, else in "global"
    // Cmd.none in the decoder's section hides the global one
    Cmd lookup(string decoder, int key) const {
        if (auto section = decoder in sections)
            if (auto cmd = key in *section) return *cmd;
        if (auto section = "global" in sections)
            if (auto cmd = key in *section) return *cmd;
        return Cmd.none;
    }
}

// Built-in key bindings
Keymap defaultKeymap() {
    Keymap keymap;
    keymap.sections["global"] = [
        alt('q'):       Cmd.quit,
        ctrl('q'):      Cmd.quit,
        alt('s'):       Cmd.save,
        ctrl('s'):      Cmd.save,
        alt('S'):       Cmd.saveAs,
        alt('o'):       Cmd.open,
        ctrl('o'):      Cmd.open,
        alt('w'):       Cmd.closeBuffer,
        ctrl('w'):      Cmd.closeBuffer,
        alt('.'):       Cmd.nextBuffer,
        alt(','):       Cmd.prevBuffer,
    ];
    keymap.sections["text"] = [
        keyLeft:        Cmd.cursorLeft,
        keyRight:       Cmd.cursorRight,
        keyUp:          Cmd.cursorUp,
        keyDown:        Cmd.cursorDown,
        keyHome:        Cmd.lineStart,
        keyEnd:         Cmd.lineEnd,
        keyPageUp:      Cmd.pageUp,
        keyPageDown:    Cmd.pageDown,
        '\r':           Cmd.newline, // Enter arrives as CR because ICRNL is off
        0x7F:           Cmd.deleteBack,
        ctrl('h'):      Cmd.deleteBack, // Backspace
        keyDelete:      Cmd.deleteForward,
        '\t':           Cmd.insertTab,
    ];
    return keymap;
}

// Path for ~/.config/ve/keys
string keysPath() {
    string dir = environment.get("XDG_CONFIG_HOME");
    if (dir.length == 0) dir = environment.get("HOME", "") ~ "/.config";
    return dir ~ "/ve/keys";
}

// Applies the keys file
// Returns the first error or null
string loadKeys(ref Keymap keymap) {
    string path = keysPath();
    if (!exists(path)) return null;
    try {
        return parseKeys(keymap, readText(path));
    } catch (Exception e) {
        return "keys: " ~ e.msg;
    }
}

// Parses and assigns keys
//   # comment       <- comment
//   ctrl+s  save    <- goes to global
//   [text]          <- section
//   tab     none    <- goes to text
// Returns the first error or null.
string parseKeys(ref Keymap keymap, string text) {
    string section = "global";
    string error;
    int lineNo = 0;
    foreach (line; text.lineSplitter) {
        lineNo++;
        line = line.strip;
        if (line.length == 0 || line[0] == '#') continue;

        string problem;
        if (line[0] == '[') {
            if (line.length > 2 && line[$ - 1] == ']' && ["global", "text", "hex"].canFind(line[1 .. $ - 1])) {
                section = line[1 .. $ - 1];
            } else {
                section = line;
                problem = format("unknown section '%s'", line);
            }
        } else {
            string[] words = line.split;
            if (words.length != 2) {
                problem = "expected 'key command'";
            } else {
                int key = parseKey(words[0]);
                Cmd cmd;
                try {
                    cmd = words[1].to!Cmd;
                } catch (ConvException) {
                    problem = format("unknown command '%s'", words[1]);
                }
                if (key == keyNone) problem = format("unknown key '%s'", words[0]);
                if (problem is null) keymap.sections[section][key] = cmd;
            }
        }
        if (problem !is null && error is null) error = format("keys:%d: %s", lineNo, problem);
    }
    return error;
}

unittest {
    Keymap keymap = defaultKeymap();
    assert(keymap.lookup("text", ctrl('s')) == Cmd.save);
    assert(keymap.lookup("text", keyLeft)   == Cmd.cursorLeft);
    assert(keymap.lookup("text", 'a')       == Cmd.none);

    string error = parseKeys(keymap, ` 
        # comment
        f2      save
        
        [text]
          ctrl+s  quit  
        tab     none
        [global]
        ctrl+q  none
        f3      save
        [hex]
        tab     deleteBack
        [text]
        f3      none
        `);
    assert(error is null, error);
    assert(keymap.lookup("text", keyF2)     == Cmd.save);       // before any section: global
    assert(keymap.lookup("hex", keyF2)      == Cmd.save);
    assert(keymap.lookup("text", ctrl('s')) == Cmd.quit);
    assert(keymap.lookup("hex", ctrl('s'))  == Cmd.save);
    assert(keymap.lookup("text", '\t')      == Cmd.none);        // none unbinds
    assert(keymap.lookup("hex", '\t')       == Cmd.deleteBack);
    assert(keymap.lookup("text", ctrl('q')) == Cmd.none);
    assert(keymap.lookup("text", alt('q'))  == Cmd.quit);
    assert(keymap.lookup("text", keyF3)     == Cmd.none);       // none in a decoder's section hides global
    assert(keymap.lookup("hex", keyF3)      == Cmd.save);

    keymap = defaultKeymap();
    assert(parseKeys(keymap, "ctrl+s sav")          == "keys:1: unknown command 'sav'");
    assert(parseKeys(keymap, "\nctrl+shift+s save") == "keys:2: unknown key 'ctrl+shift+s'");
    assert(parseKeys(keymap, "save")                == "keys:1: expected 'key command'");
    assert(parseKeys(keymap, "f2 save # comment")   == "keys:1: expected 'key command'");
    assert(parseKeys(keymap, "[Text]\nf2 save")     == "keys:1: unknown section '[Text]'");
    assert(keymap.lookup("text", keyF2)             == Cmd.none);
    assert(parseKeys(keymap, "[\nf2 save")          == "keys:1: unknown section '['");
    assert(keymap.lookup("text", keyF2)             == Cmd.none);

    // Only the first error is reported, and the good lines still apply
    assert(parseKeys(keymap, "f5 sav\nf6 save\nf7 qit") == "keys:1: unknown command 'sav'");
    assert(keymap.lookup("text", keyF6)                 == Cmd.save);
    assert(keymap.lookup("text", ctrl('s'))             == Cmd.save);
}
