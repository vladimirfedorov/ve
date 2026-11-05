module ve.decoder;

import ve.commands;
import ve.document;
import ve.screen;

abstract class Decoder {
    Document doc;

    this(Document doc) { this.doc = doc; }

    abstract string kind();                          // keymap section
    abstract bool execute(Cmd cmd);                  // false if the decoder has no such command
    abstract void input(dchar c);                    // a printable key with no binding
    abstract void draw(Canvas canvas, bool focused); // scrolls to the cursor; shows it when focused
    abstract string statusRight();
    void close() {}
}
