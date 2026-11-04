module ve.view;

import ve.commands;
import ve.document;
import ve.screen;

// A representation of a document
abstract class View {
    Document doc;

    this(Document doc) { this.doc = doc; }

    abstract string kind();                          // keymap section
    abstract bool execute(Cmd cmd);                  // false if the view has no such command
    abstract void input(dchar c);                    // a printable key with no binding
    abstract void draw(Canvas canvas, bool focused); // scrolls to the cursor; shows it when focused
    abstract string statusRight();
}
