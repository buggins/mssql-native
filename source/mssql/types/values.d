/++
Conversions of values on the wire to D values, for the getters of
`mssql.result.QueryResult`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.types.values;

import std.uuid : UUID;
import std.variant : Variant;
import dbwire.types.decimal : Decimal;
import mssql.exception : ClientException;
import dbwire.charset.utf16 : decodeUtf16le;
import mssql.types.temporal : TemporalKind, decodeTemporal, isTemporal;
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

/// Whether values of type `t` are `decimal`/`numeric`.
bool isDecimal(const ref TypeInfo t) @safe pure nothrow @nogc
{
    return t.type == TdsType.decimalN || t.type == TdsType.numericN || t.type == TdsType.decimal
        || t.type == TdsType.numeric;
}

/// Whether values of type `t` are `money`/`smallmoney`.
bool isMoney(const ref TypeInfo t) @safe pure nothrow @nogc
{
    return t.type == TdsType.money || t.type == TdsType.money4 || t.type == TdsType.moneyN;
}

/// Whether values of type `t` are `real`/`float`.
bool isFloat(const ref TypeInfo t) @safe pure nothrow @nogc
{
    return t.type == TdsType.float4 || t.type == TdsType.float8 || t.type == TdsType.floatN;
}

/// Whether values of type `t` are binary strings (`binary`, `varbinary`, `image`).
bool isBinary(const ref TypeInfo t) @safe pure nothrow @nogc
{
    switch (t.type)
    {
    case TdsType.binary:
    case TdsType.varbinary:
    case TdsType.bigBinary:
    case TdsType.bigVarbinary:
    case TdsType.image:
        return true;
    default:
        return false;
    }
}

/++
The integer in `bytes`, a value of type `t`. Decimals and money are truncated
towards zero.

Throws: `ClientException` for other types, or if a decimal doesn't fit in a `long`.
+/
long integerValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    if (isDecimal(t) || isMoney(t))
        return decimalValue(t, bytes).toLong();
    if (!isInteger(t))
        throw unsupported(t, "an integer");
    switch (bytes.length)
    {
    case 1:
        return bytes[0]; // tinyint is unsigned
    case 2:
    case 4:
    case 8:
        return littleEndian(bytes);
    default:
        throw new ClientException("Invalid integer of " ~ toText(bytes.length) ~ " bytes");
    }
}

/++
The floating-point value in `bytes`, a value of type `t` (`real`, `float`,
integers, decimals, money).

Throws: `ClientException` for other types.
+/
double floatValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    import std.bitmanip : littleEndianToNative;

    if (isInteger(t))
        return cast(double) integerValue(t, bytes);
    if (isDecimal(t) || isMoney(t))
        return decimalValue(t, bytes).toDouble();
    if (!isFloat(t))
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
The exact value in `bytes`, a value of type `t`: `decimal`/`numeric` with
their scale, `money`/`smallmoney` with scale 4, integers with scale 0.

Throws: `ClientException` for other types.
+/
Decimal decimalValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    import dbwire.types.wideint : Int256;

    if (isInteger(t))
        return Decimal.fromLong(integerValue(t, bytes));
    if (isMoney(t))
    {
        // money: the high 32 bits, then the low 32 bits of value × 10^4; smallmoney: an int
        long v;
        if (bytes.length == 8)
            v = (littleEndian(bytes[0 .. 4]) << 32) | (littleEndian(bytes[4 .. 8]) & 0xFFFF_FFFF);
        else if (bytes.length == 4)
            v = littleEndian(bytes);
        else
            throw new ClientException("Invalid " ~ t.name ~ " value");
        return Decimal(Int256(v), 4);
    }
    if (!isDecimal(t))
        throw unsupported(t, "a decimal");
    // a sign byte (1 positive, 0 negative), then the magnitude: little-endian, 4 to 16 bytes
    if (bytes.length < 2 || bytes.length > 17 || bytes[0] > 1)
        throw new ClientException("Invalid " ~ t.name ~ " value");
    Int256 unscaled;
    foreach (i, b; bytes[1 .. $])
        unscaled.words[i / 8] |= cast(ulong) b << (8 * (i % 8));
    if (bytes[0] == 0)
    {
        // two's complement: invert and add one (the magnitude is below 2^128)
        bool carry = true;
        foreach (ref w; unscaled.words)
        {
            w = ~w;
            if (carry)
                carry = ++w == 0;
        }
    }
    return Decimal(unscaled, t.scale);
}

/++
The `uniqueidentifier` in `bytes`. The first three groups are little-endian on
the wire, the rest is in order.

Throws: `ClientException` for other types.
+/
UUID uuidValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    if (t.type != TdsType.guid)
        throw unsupported(t, "a UUID");
    if (bytes.length != 16)
        throw new ClientException("Invalid uniqueidentifier value");
    ubyte[16] b = [
        bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ];
    return UUID(b);
}

/++
The value in `bytes` (of type `t`) as text, as SQL Server writes it:

$(UL
$(LI strings as they are; `char`/`varchar` decoded from the collation's code page;)
$(LI integers and decimals in decimal, decimals with all their `scale` digits;)
$(LI `money` with 4 fraction digits (`CONVERT` style 2);)
$(LI `real`/`float` as the shortest decimal that reads back as the same value,
    e.g. `0.1` (SQL Server's default `CONVERT` keeps only 6 digits);)
$(LI dates and times as `CONVERT(nvarchar, x)` writes them, `datetime` with style
    121 (`2024-01-31 12:34:56.997`), `smalldatetime` with style 120;)
$(LI `uniqueidentifier` in upper case, binary strings as `0x` and upper-case hex
    (`CONVERT` style 1).)
)

Throws: `ClientException` for types without a text form yet, and for
`char`/`varchar` in a code page that is not supported.
+/
string textValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    import std.conv : to;
    import std.uni : toUpper;

    switch (t.type)
    {
    case TdsType.nvarchar:
    case TdsType.nchar:
    case TdsType.ntext:
    case TdsType.xml: // UTF-16LE on the wire
        return decodeUtf16le(bytes);
    case TdsType.bigVarchar:
    case TdsType.bigChar:
    case TdsType.varchar:
    case TdsType.char_:
    case TdsType.text:
        return eightBitText(t, bytes);
    case TdsType.guid:
        return uuidValue(t, bytes).toString().toUpper;
    default:
        if (isInteger(t))
            return integerValue(t, bytes).to!string;
        if (isDecimal(t) || isMoney(t))
            return decimalValue(t, bytes).toFixedString();
        if (isFloat(t))
            return shortestText(floatValue(t, bytes), bytes.length == 4);
        if (isTemporal(t))
            return decodeTemporal(t, bytes).toString();
        if (isBinary(t))
            return hexText(bytes);
        throw unsupported(t, "text");
    }
}

/++
The value in `bytes` (of type `t`) as a `Variant` holding its natural D type:
`ubyte` (`tinyint`), `short`, `int`, `long`, `bool` (`bit`), `float`
(`real`), `double`, `Decimal` (decimals and money), `string`, `ubyte[]`
(binary strings), `Date`, `Duration` (`time`: since midnight), `SysTime`
(`datetime2`, `datetime`, `smalldatetime` in UTC; `datetimeoffset` with its
offset), `UUID`.

Throws: `ClientException` for types that are not supported yet.
+/
Variant variantValue(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    if (isInteger(t))
    {
        const v = integerValue(t, bytes);
        if (t.type == TdsType.bit || t.type == TdsType.bitN)
            return makeVariant(v != 0);
        switch (bytes.length)
        {
        case 1:
            return makeVariant(cast(ubyte) v);
        case 2:
            return makeVariant(cast(short) v);
        case 4:
            return makeVariant(cast(int) v);
        default:
            return makeVariant(v);
        }
    }
    if (isFloat(t))
    {
        const v = floatValue(t, bytes);
        return bytes.length == 4 ? makeVariant(cast(float) v) : makeVariant(v);
    }
    if (isDecimal(t) || isMoney(t))
        return makeVariant(decimalValue(t, bytes));
    if (isBinary(t))
        return makeVariant(bytes.dup);
    if (t.type == TdsType.guid)
        return makeVariant(uuidValue(t, bytes));
    if (isTemporal(t))
    {
        const v = decodeTemporal(t, bytes);
        final switch (v.kind)
        {
        case TemporalKind.date:
            return makeVariant(v.date);
        case TemporalKind.time:
            return makeVariant(v.sinceMidnight);
        case TemporalKind.dateTime:
        case TemporalKind.dateTimeOffset:
            return makeVariant(v.sysTime);
        }
    }
    return makeVariant(textValue(t, bytes));
}

/// Wraps `value` in a `Variant` (whose constructor is `@system` for some types).
Variant makeVariant(T)(T value) @trusted
{
    return Variant(value);
}

/// `char`/`varchar` text in the code page of the column collation.
private string eightBitText(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe
{
    import dbwire.charset.codepage : CodePage;
    import mssql.types.collations : codePageOf;

    foreach (b; bytes)
        if (b >= 0x80)
        {
            const number = codePageOf(t.collation);
            CodePage page;
            if (number <= 0 || !CodePage.find(number, page))
                throw new ClientException("Text in code page " ~ (number < 0 ? "?" : toText(number))
                        ~ " (collation LCID 0x" ~ hex(t.collation.lcid) ~ ", sort id " ~ toText(
                            t.collation.sortId) ~ ") is not supported; use nvarchar or a UTF-8 collation");
            return page.decode(bytes);
        }
    return (() @trusted => cast(string) bytes.idup)(); // ASCII is UTF-8
}

/// The shortest decimal text that reads back as `value` (as a `float` if `single`).
private string shortestText(double value, bool single) @safe
{
    import std.conv : ConvException, to;
    import std.format : format;

    foreach (precision; 1 .. 18)
    {
        auto s = format("%.*g", precision, value);
        try
        {
            if (single ? s.to!float == cast(float) value : s.to!double == value)
                return s;
        }
        catch (ConvException)
        {
            // rounded beyond the largest value (e.g. 2e+308): needs more digits
        }
    }
    return format("%.17g", value);
}

private string hexText(scope const(ubyte)[] bytes) @safe pure
{
    import std.format : format;

    return format("0x%(%02X%)", bytes);
}

/// A signed little-endian integer of 1 to 8 bytes.
private long littleEndian(scope const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    ulong v;
    foreach_reverse (b; bytes)
        v = (v << 8) | b;
    const bits = 8 * bytes.length;
    return bits < 64 && (v >> (bits - 1)) & 1 ? cast(long)(v | (ulong.max << bits)) : cast(long) v;
}

private ClientException unsupported(const ref TypeInfo t, string target) @safe pure
{
    return new ClientException("Cannot read a " ~ t.name ~ " value as " ~ target);
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
    varchar.collation = Collation(0x409, 0x0D, 0, 52); // SQL_Latin1_General_CP1_CI_AS
    assert(textValue(varchar, cast(const(ubyte)[]) "plain") == "plain");
    assert(textValue(varchar, [0x63, 0x61, 0x66, 0xE9, 0x80]) == "café€"); // code page 1252
    varchar.collation.flags |= 0x40; // a UTF-8 collation
    assert(textValue(varchar, [0xC3, 0xA9]) == "é");
    varchar.collation = Collation(0x411, 0x0D, 0, 0); // Japanese_CI_AS: code page 932
    assertThrown!ClientException(textValue(varchar, [0x82, 0xA0]));

    const float8 = TypeInfo(TdsType.floatN, ValueFormat.byteLength, 8);
    assert(floatValue(float8, [0, 0, 0, 0, 0, 0, 0xF8, 0x3F]) == 1.5);
    assert(textValue(float8, [0x9A, 0x99, 0x99, 0x99, 0x99, 0x99, 0xB9, 0x3F]) == "0.1");
    const float4 = TypeInfo(TdsType.floatN, ValueFormat.byteLength, 4);
    assert(textValue(float4, [0xCD, 0xCC, 0xCC, 0x3D]) == "0.1");
    assert(textValue(float8, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF, 0x7F]) == "1.7976931348623157e+308"); // double.max
    assert(textValue(float4, [0xFF, 0xFF, 0x7F, 0x7F]) == "3.4028235e+38"); // float.max
    assertThrown!ClientException(integerValue(nvarchar, [1, 0]));
}

@safe unittest
{
    import mssql.types.typeinfo : ValueFormat;

    // golden bytes from SQL Server 2022
    auto dec = TypeInfo(TdsType.decimalN, ValueFormat.byteLength, 5);
    dec.precision = 9;
    dec.scale = 2;
    const d = decimalValue(dec, [0x00, 0x15, 0xCD, 0x5B, 0x07]); // sign 0: negative
    assert(d.toFixedString() == "-1234567.89" && textValue(dec, [0x00, 0x15, 0xCD, 0x5B, 0x07]) == "-1234567.89");
    assert(integerValue(dec, [0x00, 0x15, 0xCD, 0x5B, 0x07]) == -1_234_567); // truncated
    dec.precision = 38;
    dec.scale = 0;
    const ubyte[] max38 = [
        0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x3F, 0x22, 0x8A, 0x09, 0x7A, 0xC4, 0x86, 0x5A, 0xA8, 0x4C, 0x3B,
        0x4B
    ];
    assert(textValue(dec, max38) == "99999999999999999999999999999999999999");
    dec.scale = 3;
    assert(textValue(dec, [0x01, 0xDC, 0x05, 0, 0]) == "1.500"); // all scale digits

    const money = TypeInfo(TdsType.moneyN, ValueFormat.byteLength, 8);
    const ubyte[] minMoney = [0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00]; // high half first
    assert(textValue(money, minMoney) == "-922337203685477.5808");
    assert(decimalValue(money, [0, 0, 0, 0, 0x4E, 0x61, 0xBC, 0x00]).toString() == "1234.5678");
    const smallMoney = TypeInfo(TdsType.moneyN, ValueFormat.byteLength, 4);
    assert(textValue(smallMoney, [0x00, 0x00, 0x00, 0x80]) == "-214748.3648");

    const guid = TypeInfo(TdsType.guid, ValueFormat.byteLength, 16);
    const ubyte[] g = [
        0xFF, 0x19, 0x96, 0x6F, 0x86, 0x8B, 0x11, 0xD0, 0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF
    ];
    assert(textValue(guid, g) == "6F9619FF-8B86-D011-B42D-00C04FC964FF");
    assert(uuidValue(guid, g) == UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff"));

    const varbinary = TypeInfo(TdsType.bigVarbinary, ValueFormat.ushortLength, 4);
    assert(textValue(varbinary, [0x01, 0xAB]) == "0x01AB" && textValue(varbinary, []) == "0x");
}

unittest  // Variant.get is @system
{
    import std.datetime.date : Date;
    import mssql.types.typeinfo : ValueFormat;

    // natural D types
    const tiny = TypeInfo(TdsType.intN, ValueFormat.byteLength, 1);
    assert(variantValue(tiny, [200]).get!ubyte == 200);
    const bit = TypeInfo(TdsType.bitN, ValueFormat.byteLength, 1);
    assert(variantValue(bit, [1]).get!bool);
    const float4 = TypeInfo(TdsType.floatN, ValueFormat.byteLength, 4);
    assert(variantValue(float4, [0, 0, 0xC0, 0x3F]).get!float == 1.5f);
    const money = TypeInfo(TdsType.moneyN, ValueFormat.byteLength, 4);
    assert(variantValue(money, [0x10, 0x27, 0, 0]).get!Decimal.toString() == "1");
    const date = TypeInfo(TdsType.dateN, ValueFormat.byteLength, 3);
    assert(variantValue(date, [0x63, 0x46, 0x0B]).get!Date == Date(2024, 1, 31));
    auto varchar = TypeInfo(TdsType.bigVarchar, ValueFormat.ushortLength, 10);
    assert(variantValue(varchar, cast(const(ubyte)[]) "abc").get!string == "abc");
}
