/++
Conversions of values on the wire to D values, for the getters of
`mssql.result.QueryResult`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.types.values;

import mssql.exception : ClientException;
import mssql.protocol.text : fromUtf16le;
import mssql.types.typeinfo : TdsType, TypeInfo;

/// Whether values of type `t` are integers (or `bit`).
bool isInteger(const ref TypeInfo t) @safe pure nothrow @nogc
{
    switch (t.type)
    {
    case TdsType.int1:
    case TdsType.int2:
    case TdsType.int4:
    case TdsType.int8:
    case TdsType.intN:
    case TdsType.bit:
    case TdsType.bitN:
        return true;
    default:
        return false;
    }
}

/++
The integer in `bytes`, a value of type `t`.

Throws: `ClientException` if `t` is not an integer type.
+/
long integerValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    if (!isInteger(t))
        throw unsupported(t, "an integer");
    switch (bytes.length)
    {
    case 1:
        return t.type == TdsType.int1 || t.type == TdsType.intN || t.type == TdsType.bit || t.type == TdsType.bitN
            ? bytes[0] : cast(byte) bytes[0]; // tinyint is unsigned
    case 2:
        return cast(short)(bytes[0] | (bytes[1] << 8));
    case 4:
        return cast(int)(bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (cast(uint) bytes[3] << 24));
    case 8:
        ulong v;
        foreach_reverse (b; bytes)
            v = (v << 8) | b;
        return cast(long) v;
    default:
        throw new ClientException("Invalid integer of " ~ toText(bytes.length) ~ " bytes");
    }
}

/++
The floating-point value in `bytes`, a value of type `t` (`real`, `float`, or an integer).

Throws: `ClientException` for other types.
+/
double floatValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    import std.bitmanip : littleEndianToNative;

    if (isInteger(t))
        return cast(double) integerValue(t, bytes);
    if (t.type != TdsType.float4 && t.type != TdsType.float8 && t.type != TdsType.floatN)
        throw unsupported(t, "a floating-point number");
    if (bytes.length == 4)
    {
        const ubyte[4] b = bytes[0 .. 4];
        return littleEndianToNative!float(b);
    }
    if (bytes.length == 8)
    {
        const ubyte[8] b = bytes[0 .. 8];
        return littleEndianToNative!double(b);
    }
    throw new ClientException("Invalid floating-point value of " ~ toText(bytes.length) ~ " bytes");
}

/++
The value in `bytes` (of type `t`) as text: strings as they are, numbers in
decimal.

Throws: `ClientException` for types without a text form yet, and for
`char`/`varchar` in a collation whose code page is not supported yet.
+/
string textValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    import std.conv : to;

    switch (t.type)
    {
    case TdsType.nvarchar:
    case TdsType.nchar:
    case TdsType.ntext:
    case TdsType.xml: // UTF-16LE on the wire
        return fromUtf16le(bytes);
    case TdsType.bigVarchar:
    case TdsType.bigChar:
    case TdsType.varchar:
    case TdsType.char_:
    case TdsType.text:
        return eightBitText(t, bytes);
    case TdsType.float4:
    case TdsType.float8:
    case TdsType.floatN:
        return floatValue(t, bytes).to!string;
    default:
        if (isInteger(t))
            return integerValue(t, bytes).to!string;
        throw unsupported(t, "text");
    }
}

/// `char`/`varchar` text: UTF-8 collations, and ASCII text in any collation.
private string eightBitText(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    if (t.collation.utf8)
        return bytes.idup.validUtf8(t);
    foreach (b; bytes)
        if (b >= 0x80)
            throw new ClientException("Text in the code page of collation LCID 0x" ~ hex(
                    t.collation.lcid)
                    ~ " (sort id " ~ toText(
                        t.collation.sortId) ~ ") is not supported yet; "
                    ~ "use nvarchar or a UTF-8 collation");
    return (() @trusted => cast(string) bytes.idup)(); // ASCII is UTF-8
}

private string validUtf8(immutable(ubyte)[] bytes, const ref TypeInfo t) @safe
{
    import std.utf : UTFException, validate;

    auto s = cast(string) bytes;
    try
        validate(s);
    catch (UTFException)
        throw new ClientException("Invalid UTF-8 in a " ~ t.name ~ " value");
    return s;
}

private ClientException unsupported(const ref TypeInfo t, string target) @safe pure
{
    return new ClientException("Cannot read a " ~ t.name ~ " value as " ~ target
            ~ " (this type is not supported yet)");
}

private string hex(uint v) @safe pure
{
    import std.format : format;

    return format("%X", v);
}

private string toText(T)(T value) @safe pure
{
    import std.conv : to;

    return value.to!string;
}

///
@safe unittest
{
    import std.exception : assertThrown;
    import mssql.types.typeinfo : Collation, ValueFormat;

    const int4 = TypeInfo(TdsType.int4, ValueFormat.fixed, 4);
    const intN = TypeInfo(TdsType.intN, ValueFormat.byteLength, 8);
    const tiny = TypeInfo(TdsType.int1, ValueFormat.fixed, 1);
    assert(integerValue(int4, [0xFE, 0xFF, 0xFF, 0xFF]) == -2);
    assert(integerValue(intN, [0x05, 0, 0, 0, 0, 0, 0, 0x80]) == long.min + 5);
    assert(integerValue(intN, [0xC8]) == 200 && integerValue(tiny, [0xC8]) == 200); // tinyint is unsigned
    assert(textValue(int4, [0x2A, 0, 0, 0]) == "42");

    const nvarchar = TypeInfo(TdsType.nvarchar, ValueFormat.ushortLength, 20);
    assert(textValue(nvarchar, [0x78, 0x00, 0x39, 0x04]) == "xй");

    auto varchar = TypeInfo(TdsType.bigVarchar, ValueFormat.ushortLength, 20);
    varchar.collation = Collation(0x409, 0x0D, 0, 52);
    assert(textValue(varchar, cast(const(ubyte)[]) "plain") == "plain");
    assertThrown!ClientException(textValue(varchar, [0xE9])); // é in code page 1252: not yet
    varchar.collation.flags |= 0x40; // a UTF-8 collation
    assert(textValue(varchar, [0xC3, 0xA9]) == "é");

    const float8 = TypeInfo(TdsType.floatN, ValueFormat.byteLength, 8);
    assert(floatValue(float8, [0, 0, 0, 0, 0, 0, 0xF8, 0x3F]) == 1.5);
    assertThrown!ClientException(integerValue(nvarchar, [1, 0]));
}
