/++
Text encodings of the protocol: UTF-16LE (`nvarchar`, names, messages).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.protocol.text;

/++
Encodes `text` (UTF-8) as UTF-16LE bytes.

Throws: `std.utf.UTFException` if `text` is not valid UTF-8.
+/
ubyte[] toUtf16le(scope const(char)[] text) @safe pure
{
    import std.utf : byWchar;

    ubyte[] result;
    result.reserve(text.length * 2);
    foreach (wchar c; text.byWchar)
    {
        result ~= cast(ubyte) c;
        result ~= cast(ubyte)(c >> 8);
    }
    return result;
}

/++
Decodes UTF-16LE bytes as UTF-8. Unpaired surrogates, which SQL Server's
UCS-2 data may contain, become U+FFFD; an odd trailing byte is ignored.
+/
string fromUtf16le(scope const(ubyte)[] bytes) @safe pure nothrow
{
    char[] result;
    result.reserve(bytes.length / 2 * 3 / 2 + 1);
    const units = bytes.length / 2;
    size_t i;
    while (i < units)
    {
        dchar c = bytes[2 * i] | (bytes[2 * i + 1] << 8);
        i++;
        if (c >= 0xD800 && c <= 0xDBFF && i < units)
        {
            const low = bytes[2 * i] | (bytes[2 * i + 1] << 8);
            if (low >= 0xDC00 && low <= 0xDFFF)
            {
                c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                i++;
            }
        }
        if (c >= 0xD800 && c <= 0xDFFF)
            c = 0xFFFD;
        // UTF-8 (c is a valid code point here)
        if (c < 0x80)
            result ~= cast(char) c;
        else if (c < 0x800)
        {
            result ~= cast(char)(0xC0 | (c >> 6));
            result ~= cast(char)(0x80 | (c & 0x3F));
        }
        else if (c < 0x10000)
        {
            result ~= cast(char)(0xE0 | (c >> 12));
            result ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
            result ~= cast(char)(0x80 | (c & 0x3F));
        }
        else
        {
            result ~= cast(char)(0xF0 | (c >> 18));
            result ~= cast(char)(0x80 | ((c >> 12) & 0x3F));
            result ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
            result ~= cast(char)(0x80 | (c & 0x3F));
        }
    }
    return (() @trusted => cast(string) result)(); // result is unique: built here
}

///
@safe unittest
{
    assert(toUtf16le("Ab") == [0x41, 0, 0x62, 0]);
    assert(fromUtf16le(toUtf16le("Grüße, мир 😀")) == "Grüße, мир 😀"); // a surrogate pair too
    assert(fromUtf16le([0x00, 0xD8, 0x41, 0x00]) == "�A"); // an unpaired surrogate
    assert(fromUtf16le([0x41, 0x00, 0x42]) == "A"); // an odd byte is ignored
}
