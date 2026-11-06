// ve: code editor
//
// Build:  ldc2 -O -i -Isrc src/ve/main.d -of=ve
// Usage:  ./ve [file...]
//
// Keys:   arrows, Home/End, PgUp/PgDn  move the cursor
//         Alt+s or Ctrl+s  save; Alt+S save as
//         Alt+o or Ctrl+o  open a file in a new buffer (bottom tab)
//         Alt+, / Alt+.    previous/next buffer
//         Alt+w or Ctrl+w  close the buffer; asks again if there are unsaved changes
//         Alt+t            new tab
//         Alt+] / Alt+}    next/previous tab
//         Alt+\ / Alt+|    split side by side / stacked
//         Alt+' / Alt+"    next/previous split
//         Alt+q or Ctrl+q  quit; asks again if there are unsaved changes
// Custom keys: ~/.config/ve/keys

module ve.main;

import core.sys.posix.unistd : isatty, STDIN_FILENO, STDOUT_FILENO;
import std.stdio : stderr;
import ve.commands;
import ve.editor;

int main(string[] args) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        stderr.writeln("ve: must be run in a terminal");
        return 1;
    }
    try {
        Editor editor = new Editor;
        foreach (path; args[1 .. $]) editor.open(path);
        if (editor.split.buffers.length == 0) editor.openUntitled();
        editor.split.active = 0;
        if (string error = loadKeys(editor.keymap)) editor.message = error;
        editor.run();
    } catch (Exception e) {
        stderr.writeln("ve: ", e.msg);
        return 1;
    }
    return 0;
}
