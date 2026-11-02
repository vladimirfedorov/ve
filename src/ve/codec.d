module ve.codec;

import std.utf : isValidDchar, replacementDchar, encodeUtf8 = encode;
import ve.document;

interface Codec {
    string name();
    size_t prevBoundary(const Document doc, size_t pos); // start of the character ending at pos
    size_t encode(dchar c, ref ubyte[4] buf);            // bytes written, 0 if c can't be encoded

    // Decodes character at pos, moves pos past it
    // invalid characters return U+FFFD and set invalid true
    dchar decode(const Document doc, ref size_t pos, out bool invalid);

    final dchar decode(const Document doc, ref size_t pos) {
        bool invalid;
        return decode(doc, pos, invalid);
    }
}

final class Utf8Codec : Codec {
    string name() { return "UTF-8"; }

    dchar decode(const Document doc, ref size_t pos, out bool invalid) {
        ubyte b = doc[pos];
        if (b < 0x80) {
            pos++;
            return b;
        }

        size_t n;                   // continuation bytes
        ubyte lo = 0x80, hi = 0xBF; // range of the first one
        if (b >= 0xC2 && b <= 0xDF) n = 1;
        else if (b >= 0xE0 && b <= 0xEF) n = 2;
        else if (b >= 0xF0 && b <= 0xF4) n = 3;
        if (b == 0xE0) lo = 0xA0;   // overlong
        if (b == 0xED) hi = 0x9F;   // surrogates
        if (b == 0xF0) lo = 0x90;   // overlong
        if (b == 0xF4) hi = 0x8F;   // above U+10FFFF

        if (n == 0 || n >= doc.length - pos) {
            pos++;
            invalid = true;
            return replacementDchar;
        }
        uint c = b & (0x3F >> n);   // payload bits of the lead byte
        foreach (i; 1 .. n + 1) {
            ubyte next = doc[pos + i];
            if (next < lo || next > hi) {
                pos++;
                invalid = true;
                return replacementDchar;
            }
            c = (c << 6) | (next & 0x3F);
            lo = 0x80;
            hi = 0xBF;
        }
        pos += n + 1;
        return c;
    }

    size_t prevBoundary(const Document doc, size_t pos) {
        size_t start = pos - 1;
        while (start > 0 && pos - start < 4 && (doc[start] & 0xC0) == 0x80) start--;
        size_t end = start;
        bool invalid;
        decode(doc, end, invalid);
        return end == pos ? start : pos - 1;
    }

    size_t encode(dchar c, ref ubyte[4] buf) {
        if (!isValidDchar(c)) return 0;
        char[4] utf;
        size_t n = encodeUtf8(utf, c);
        buf[0 .. n] = cast(ubyte[]) utf[0 .. n];
        return n;
    }
}

version (unittest) {
    // Decodes all of bytes, counting invalid ones, and checks that stepping back finds the same character starts
    private dchar[] decodeAll(const(ubyte)[] bytes, out size_t invalid) {
        Codec codec = new Utf8Codec;
        Document doc = new Document;
        doc.insert(0, bytes);
        dchar[] chars;
        size_t[] starts;
        for (size_t pos = 0; pos < doc.length; ) {
            starts ~= pos;
            bool bad;
            chars ~= codec.decode(doc, pos, bad);
            if (bad) {
                assert(chars[$ - 1] == replacementDchar && pos - starts[$ - 1] == 1);
                invalid++;
            }
        }
        size_t pos = doc.length;
        foreach_reverse (start; starts) {
            pos = codec.prevBoundary(doc, pos);
            assert(pos == start);
        }
        return chars;
    }
}

// Every code point
unittest {
    Codec codec = new Utf8Codec;
    assert(codec.name == "UTF-8");

    dchar[] chars;
    ubyte[] bytes;
    foreach (uint c; 0 .. 0x110000) {
        if (!isValidDchar(c)) continue;
        char[4] utf;
        ubyte[4] mine;
        size_t n = encodeUtf8(utf, c);
        assert(codec.encode(c, mine) == n && mine[0 .. n] == cast(ubyte[]) utf[0 .. n]);
        chars ~= c;
        bytes ~= mine[0 .. n];
    }
    size_t invalid;
    assert(decodeAll(bytes, invalid) == chars && invalid == 0);
}

// Invalid input
unittest {
    static struct Case { immutable(ubyte)[] bytes; dstring chars; size_t invalid; }
    immutable Case[] cases = [
        Case([0xEF, 0xBF, 0xBD],       "�"d, 0),            // a real U+FFFD
        Case([0xE0, 0xA0, 0x80],       "ࠀ"d, 0),           // smallest after E0
        Case([0xED, 0x9F, 0xBF],       "퟿"d, 0),           // largest after ED
        Case([0xF0, 0x90, 0x80, 0x80], "\U00010000"d, 0),   // smallest after F0
        Case([0xF4, 0x8F, 0xBF, 0xBF], "\U0010FFFF"d, 0),   // largest after F4
        Case([0xC0, 0x80],             "��"d, 2),           // overlong
        Case([0xC1, 0xBF],             "��"d, 2),           // overlong
        Case([0xE0, 0x9F, 0xBF],       "���"d, 3),          // overlong
        Case([0xF0, 0x8F, 0xBF, 0xBF], "����"d, 4),         // overlong
        Case([0xED, 0xA0, 0x80],       "���"d, 3),          // surrogate
        Case([0xF4, 0x90, 0x80, 0x80], "����"d, 4),         // above U+10FFFF
        Case([0xF5, 0x80, 0x80, 0x80], "����"d, 4),         // above U+10FFFF
        Case([0xFF],                   "�"d, 1),
        Case([0x80, 'A'],              "�A"d, 1),           // stray continuation byte
        Case([0xC3, 0xA9, 0xA9],       "é�"d, 1),
        Case([0xE2, 0x82, 'A'],        "��A"d, 2),          // cut short
        Case(['A',  0xE2, 0x82],       "A��"d, 2),          // cut off by the end
        Case([0xE2, 0xE2, 0x82, 0xAC], "�€"d, 1),
    ];
    foreach (t; cases) {
        size_t invalid;
        dchar[] chars = decodeAll(t.bytes, invalid);
        assert(chars == t.chars && invalid == t.invalid);
    }
}

// Validate random bytes against std.utf
unittest {
    import std.exception : collectException;
    import std.random : Random, choice, uniform;
    import std.utf : validate;

    // range edges; the repeats make about 3% of the strings valid
    immutable ubyte[] alphabet = ['A', 'A', 'A', 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xBF,
                                  0xC0, 0xC2, 0xDF, 0xE0, 0xE1, 0xED, 0xF0, 0xF3, 0xF4, 0xF5, 0xFF];
    Random rnd = Random(1);
    foreach (_; 0 .. 20000) {
        ubyte[] bytes = new ubyte[](uniform(1, 9, rnd));
        foreach (ref b; bytes) b = alphabet.choice(rnd);
        size_t invalid;
        decodeAll(bytes, invalid);
        assert((invalid == 0) == (collectException(validate(cast(const(char)[]) bytes)) is null));
    }
}

// A character split by the gap; encode
unittest {
    Codec codec = new Utf8Codec;
    Document doc = new Document;
    doc.insert(0, [0xE2, 0xAC]);
    doc.insert(1, [0x82]); // the gap is now inside the character
    size_t pos = 0;
    assert(codec.decode(doc, pos) == '€' && pos == 3);
    assert(codec.prevBoundary(doc, 3) == 0);

    ubyte[4] buf;
    assert(codec.encode('A', buf) == 1 && buf[0] == 'A');
    assert(codec.encode('я', buf) == 2 && buf[0 .. 2] == [0xD1, 0x8F]);
    assert(codec.encode('€', buf) == 3 && buf[0 .. 3] == [0xE2, 0x82, 0xAC]);
    assert(codec.encode('😀', buf) == 4 && buf[0 .. 4] == [0xF0, 0x9F, 0x98, 0x80]);
    assert(codec.encode(cast(dchar) 0xD800, buf) == 0);
    assert(codec.encode(cast(dchar) 0x110000, buf) == 0);
}
