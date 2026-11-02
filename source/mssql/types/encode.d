/++
Values in a column's own type, for bulk loads: a parameter value (as
`mssql.params.Parameter.of` encodes it) converted to the exact type of a
table column (`varchar` in the column's code page, `decimal(p,s)` at its
scale, `datetime` ticks, ...), and the TYPE_INFO, declarations and framing of
those types.

Conversions round as SQL Server does when it converts between the types
(decimals and money half away from zero, times to the column's scale,
`datetime` to 1/300 s, `smalldatetime` to the minute), and refuse what doesn't
fit (out of range, too long, a character the code page lacks, a fraction in an
integer column).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.types.encode;

import dbwire.types.decimal : Decimal, RoundingMode;
import mssql.exception : ClientException;
import mssql.params : Parameter;
import mssql.types.temporal : Temporal, TemporalKind, decodeTemporal;
import mssql.types.typeinfo : TdsType, TypeInfo, ValueFormat, rowversionUserType;
import mssql.types.values : decimalValue, floatValue, integerValue, isDecimal, isFloat, isInteger;

/++
The type in which bulk data for a column of type `column` is sent: the type
the server reports for it (fixed-size types such as INT4 for `NOT NULL`
columns, which take no NULLs; their nullable forms such as INTN otherwise),
with the wire format set; `xml` columns take `nvarchar(max)` data.

Throws: `ClientException` for types that can't be bulk loaded yet (`text`,
`ntext`, `image`, `sql_variant`, CLR types, `timestamp`).
+/
TypeInfo bulkType(const TypeInfo column) @safe
{
    TypeInfo t = column;
    if (t.userType == rowversionUserType)
        throw new ClientException("timestamp (rowversion) columns can't be bulk loaded");
    switch (t.type)
    {
    case TdsType.int1:
    case TdsType.bit:
        t.format = ValueFormat.fixed;
        t.maxLength = 1;
        break;
    case TdsType.int2:
        t.format = ValueFormat.fixed;
        t.maxLength = 2;
        break;
    case TdsType.int4:
    case TdsType.float4:
    case TdsType.money4:
    case TdsType.datetime4:
        t.format = ValueFormat.fixed;
        t.maxLength = 4;
        break;
    case TdsType.int8:
    case TdsType.float8:
    case TdsType.money:
    case TdsType.datetime:
        t.format = ValueFormat.fixed;
        t.maxLength = 8;
        break;
    case TdsType.intN:
    case TdsType.bitN:
    case TdsType.floatN:
    case TdsType.moneyN:
    case TdsType.datetimeN:
    case TdsType.decimalN:
    case TdsType.numericN:
    case TdsType.guid:
    case TdsType.dateN:
    case TdsType.timeN:
    case TdsType.datetime2N:
    case TdsType.datetimeOffsetN:
        t.format = ValueFormat.byteLength;
        break;
    case TdsType.bigVarchar:
    case TdsType.bigChar:
    case TdsType.nvarchar:
    case TdsType.nchar:
    case TdsType.bigVarbinary:
    case TdsType.bigBinary:
        t.format = t.maxLength == 0xFFFF ? ValueFormat.plp : ValueFormat.ushortLength;
        break;
    case TdsType.xml:
        // bulk load data can't be of type xml: it goes as nvarchar(max), which the server parses
        t.type = TdsType.nvarchar;
        t.maxLength = 0xFFFF;
        t.format = ValueFormat.plp;
        break;
    default:
        throw new ClientException(t.name ~ " columns can't be bulk loaded yet");
    }
    return t;
}

/// The nullable form of a fixed-size type (INT4 -> INTN of 4 bytes, ...), for the conversions.
private TdsType nullableForm(TdsType type) @safe pure nothrow @nogc
{
    switch (type)
    {
    case TdsType.int1:
    case TdsType.int2:
    case TdsType.int4:
    case TdsType.int8:
        return TdsType.intN;
    case TdsType.bit:
        return TdsType.bitN;
    case TdsType.float4:
    case TdsType.float8:
        return TdsType.floatN;
    case TdsType.money:
    case TdsType.money4:
        return TdsType.moneyN;
    case TdsType.datetime:
    case TdsType.datetime4:
        return TdsType.datetimeN;
    default:
        return type;
    }
}

/// The T-SQL type of `t` (a `bulkType`), as `INSERT BULK` declares it, e.g. `decimal(18,2)`, `nvarchar(50)`.
string declaration(const ref TypeInfo t) @safe pure
{
    import std.conv : to;

    const type = nullableForm(t.type);

    string length(uint bytes, uint unit = 1)
    {
        return t.maxLength == 0xFFFF ? "(max)" : "(" ~ (bytes / unit).to!string ~ ")";
    }

    switch (type)
    {
    case TdsType.intN:
        return t.maxLength == 1 ? "tinyint" : t.maxLength == 2 ? "smallint" : t.maxLength == 4 ? "int" : "bigint";
    case TdsType.bitN:
        return "bit";
    case TdsType.floatN:
        return t.maxLength == 4 ? "real" : "float";
    case TdsType.moneyN:
        return t.maxLength == 4 ? "smallmoney" : "money";
    case TdsType.datetimeN:
        return t.maxLength == 4 ? "smalldatetime" : "datetime";
    case TdsType.decimalN:
    case TdsType.numericN:
        return (t.type == TdsType.decimalN ? "decimal(" : "numeric(") ~ t.precision.to!string ~ ","
            ~ t.scale.to!string ~ ")";
    case TdsType.guid:
        return "uniqueidentifier";
    case TdsType.dateN:
        return "date";
    case TdsType.timeN:
        return "time(" ~ t.scale.to!string ~ ")";
    case TdsType.datetime2N:
        return "datetime2(" ~ t.scale.to!string ~ ")";
    case TdsType.datetimeOffsetN:
        return "datetimeoffset(" ~ t.scale.to!string ~ ")";
    case TdsType.bigVarchar:
        return "varchar" ~ length(t.maxLength);
    case TdsType.bigChar:
        return "char" ~ length(t.maxLength);
    case TdsType.nvarchar:
        return "nvarchar" ~ length(t.maxLength, 2);
    case TdsType.nchar:
        return "nchar" ~ length(t.maxLength, 2);
    case TdsType.bigVarbinary:
        return "varbinary" ~ length(t.maxLength);
    case TdsType.bigBinary:
        return "binary" ~ length(t.maxLength);
    case TdsType.xml:
        return "xml";
    default:
        assert(0, "not a bulk type");
    }
}

/// Appends the TYPE_INFO of `t` (a `bulkType`) to `buffer`.
void appendTypeInfo(ref ubyte[] buffer, const ref TypeInfo t) @safe pure
{
    buffer ~= t.type;
    if (t.format == ValueFormat.fixed)
        return; // fixed-size types: the type byte only
    switch (t.type)
    {
    case TdsType.dateN:
        break;
    case TdsType.timeN:
    case TdsType.datetime2N:
    case TdsType.datetimeOffsetN:
        buffer ~= t.scale;
        break;
    case TdsType.decimalN:
    case TdsType.numericN:
        buffer ~= [cast(ubyte) t.maxLength, t.precision, t.scale];
        break;
    case TdsType.bigVarchar:
    case TdsType.bigChar:
    case TdsType.nvarchar:
    case TdsType.nchar:
        appendLE(buffer, t.maxLength, 2);
        const c = t.collation;
        appendLE(buffer, c.lcid | (cast(uint) c.flags << 20) | (cast(uint) c.version_ << 28), 4);
        buffer ~= c.sortId;
        break;
    case TdsType.bigVarbinary:
    case TdsType.bigBinary:
        appendLE(buffer, t.maxLength, 2);
        break;
    case TdsType.xml:
        buffer ~= 0; // no schema
        break;
    default:
        buffer ~= cast(ubyte) t.maxLength;
        break;
    }
}

/++
Appends the value of `p` converted to the column type `t` (a `bulkType`) to
`buffer`, with its length prefix (or as PLP chunks for `(max)` types and
`xml`); NULL as the type's NULL.

Throws: `ClientException` if the value can't be converted to the column's
type, or doesn't fit.
+/
void appendValue(ref ubyte[] buffer, const ref TypeInfo t, const ref Parameter p, string column) @safe
{
    if (p.isNull)
    {
        final switch (t.format)
        {
        case ValueFormat.fixed:
            throw new ClientException("Column '" ~ column ~ "' doesn't take NULLs (NOT NULL)");
        case ValueFormat.byteLength:
            buffer ~= 0;
            return;
        case ValueFormat.ushortLength:
            buffer ~= [0xFF, 0xFF];
            return;
        case ValueFormat.plp:
            appendLE(buffer, ulong.max, 8);
            return;
        case ValueFormat.textPointer:
        case ValueFormat.longLength:
        case ValueFormat.none:
            assert(0, "not a bulk format");
        }
    }
    const data = convert(t, p, column);
    final switch (t.format)
    {
    case ValueFormat.fixed:
        buffer ~= data;
        return;
    case ValueFormat.byteLength:
        buffer ~= cast(ubyte) data.length;
        buffer ~= data;
        return;
    case ValueFormat.ushortLength:
        appendLE(buffer, data.length, 2);
        buffer ~= data;
        return;
    case ValueFormat.plp:
        // "unknown length": SQL Server's bulk load refuses PLP values sent with their total length (error 4804)
        appendLE(buffer, 0xFFFF_FFFF_FFFF_FFFE, 8);
        if (data.length)
        {
            appendLE(buffer, data.length, 4); // one chunk
            buffer ~= data;
        }
        appendLE(buffer, 0, 4); // terminator
        return;
    case ValueFormat.textPointer:
    case ValueFormat.longLength:
    case ValueFormat.none:
        assert(0, "not a bulk format");
    }
}

/// The bytes of `p`'s value in column type `t`.
private const(ubyte)[] convert(const ref TypeInfo t, const ref Parameter p, string column) @safe
{
    const source = p.type;
    ClientException mismatch()
    {
        return new ClientException(
                "Column '" ~ column ~ "' (" ~ declaration(t) ~ ") can't take a " ~ p.declaration
                ~ " value");
    }

    ClientException outOfRange(string value)
    {
        return new ClientException("Value " ~ value ~ " doesn't fit in column '" ~ column ~ "' (" ~ declaration(
                t) ~ ")");
    }

    switch (nullableForm(t.type))
    {
    case TdsType.intN:
    case TdsType.bitN:
        long v;
        if (isInteger(source))
            v = integerValue(source, p.data);
        else if (isDecimal(source))
        {
            const d = decimalValue(source, p.data);
            const whole = d.rescaled(0);
            if (whole != d)
                throw outOfRange(d.toString());
            v = whole.toLong();
        }
        else
            throw mismatch();
        if (nullableForm(t.type) == TdsType.bitN)
            return [v != 0 ? 1 : 0];
        const n = t.maxLength;
        const bool fits = n == 1 ? v >= 0 && v <= 255 : n == 2 ? v >= short.min && v <= short.max : n == 4 ? v >= int
            .min && v <= int.max : true;
        if (!fits)
            throw outOfRange(toText(v));
        return le(v, n);
    case TdsType.floatN:
        double v;
        if (isInteger(source) || isFloat(source) || isDecimal(source))
            v = floatValue(source, p.data);
        else
            throw mismatch();
        if (t.maxLength == 4)
        {
            import std.bitmanip : nativeToLittleEndian;
            import std.math : isFinite;

            const f = cast(float) v;
            if (!isFinite(f))
                throw outOfRange(toText(v));
            return nativeToLittleEndian(f).dup;
        }
        import std.bitmanip : nativeToLittleEndian;

        return nativeToLittleEndian(v).dup;
    case TdsType.decimalN:
    case TdsType.numericN:
    case TdsType.moneyN:
        const money = nullableForm(t.type) == TdsType.moneyN;
        const scale = money ? 4 : t.scale;
        const small = smallDecimal(source, p.data, scale);
        if (small.ok)
            return money ? smallMoneyBytes(small.negative, small.magnitude, t.maxLength, outOfRange(p.declaration))
                : smallDecimalBytes(small.negative, small.magnitude, t.precision, outOfRange(p.declaration));
        Decimal d;
        if (isInteger(source))
            d = Decimal.fromLong(integerValue(source, p.data));
        else if (isDecimal(source))
            d = decimalValue(source, p.data);
        else if (isFloat(source))
            d = Decimal.fromDouble(floatValue(source, p.data), scale, RoundingMode.halfUp);
        else
            throw mismatch();
        d = d.rescaled(scale, RoundingMode.halfUp);
        return money ? moneyBytes(d, t.maxLength, outOfRange(d.toString())) : decimalBytes(d, t.precision, outOfRange(
                d.toString()));
    case TdsType.nvarchar:
    case TdsType.nchar:
    case TdsType.xml:
        if (source.type != TdsType.nvarchar)
            throw mismatch();
        if (t.maxLength != 0xFFFF && t.type != TdsType.xml && p.data.length > t.maxLength)
            throw new ClientException("A text of " ~ toText(
                    p.data.length / 2) ~ " characters is too long for column '"
                    ~ column ~ "' (" ~ declaration(t) ~ ")");
        return p.data;
    case TdsType.bigVarchar:
    case TdsType.bigChar:
        if (source.type != TdsType.nvarchar)
            throw mismatch();
        const bytes = eightBit(t, p.data, column);
        if (t.maxLength != 0xFFFF && bytes.length > t.maxLength)
            throw new ClientException("A text of " ~ toText(
                    bytes.length) ~ " bytes is too long for column '"
                    ~ column ~ "' (" ~ declaration(t) ~ ")");
        return bytes;
    case TdsType.bigVarbinary:
    case TdsType.bigBinary:
        if (source.type != TdsType.bigVarbinary)
            throw mismatch();
        if (t.maxLength != 0xFFFF && p.data.length > t.maxLength)
            throw new ClientException(toText(
                    p.data.length) ~ " bytes are too long for column '" ~ column ~ "' ("
                    ~ declaration(t) ~ ")");
        return p.data;
    case TdsType.guid:
        if (source.type != TdsType.guid)
            throw mismatch();
        return p.data;
    case TdsType.dateN:
    case TdsType.timeN:
    case TdsType.datetime2N:
    case TdsType.datetimeOffsetN:
    case TdsType.datetimeN:
        if (source.type != TdsType.dateN && source.type != TdsType.timeN && source.type != TdsType.datetime2N
                && source.type != TdsType.datetimeOffsetN)
            throw mismatch();
        return temporalBytes(t, decodeTemporal(source, p.data), mismatch(), outOfRange(p.declaration));
    default:
        throw mismatch();
    }
}

/// `char`/`varchar` bytes of UTF-16LE `utf16` in the code page of column type `t`.
private immutable(ubyte)[] eightBit(const ref TypeInfo t, scope const(ubyte)[] utf16, string column) @safe
{
    import dbwire.charset.codepage : CodePage;
    import dbwire.charset.utf16 : decodeUtf16le;
    import mssql.types.collations : codePageOf;

    const text = decodeUtf16le(utf16);
    if (t.collation.utf8)
        return cast(immutable(ubyte)[]) text;
    const number = codePageOf(t.collation);
    CodePage page;
    if (number <= 0 || !CodePage.find(number, page))
        throw new ClientException("Column '" ~ column ~ "': the code page of its collation is not supported");
    try
        return (() @trusted => cast(immutable(ubyte)[]) page.encode(text))(); // unique: built by encode
    catch (ClientException e)
        throw new ClientException("Column '" ~ column ~ "': " ~ e.msg);
}

/// A decimal of precision `precision`: sign, then 4, 8, 12 or 16 bytes of magnitude.
private immutable(ubyte)[] decimalBytes(const Decimal d, uint precision, lazy ClientException tooLarge) @safe
{
    import std.bigint : BigInt;

    BigInt u = d.unscaled.toBigInt();
    const negative = u < 0;
    if (negative)
        u = -u;
    if (u >= BigInt(10) ^^ precision)
        throw tooLarge;
    const size = precision <= 9 ? 4 : precision <= 19 ? 8 : precision <= 28 ? 12 : 16;
    auto b = new ubyte[1 + size];
    b[0] = negative ? 0 : 1;
    foreach (i; 0 .. size)
    {
        b[1 + i] = cast(ubyte)(u % BigInt(256)).toLong();
        u >>= 8;
    }
    return (() @trusted => cast(immutable(ubyte)[]) b)(); // unique: built here
}

/// A decimal's sign and magnitude, when the magnitude fits in 64 bits (`ok`).
private struct SmallDecimal
{
    bool ok;
    bool negative;
    ulong magnitude;
}

private static immutable ulong[20] powersOf10 = () {
    ulong[20] p;
    p[0] = 1;
    foreach (i; 1 .. 20)
        p[i] = p[i - 1] * 10;
    return p;
}();

/++
The value of `data` (an integer, or a decimal of type `source`) at scale
`scale`, rounded half away from zero, when its magnitude fits in 64 bits: the
fast path of the decimal conversions (`Decimal` arithmetic needs `BigInt`).
Not `ok` when it doesn't fit (or for other source types).
+/
private SmallDecimal smallDecimal(const ref TypeInfo source, scope const(ubyte)[] data, uint scale) @safe
{
    SmallDecimal r;
    uint from;
    if (isInteger(source))
    {
        const v = integerValue(source, data);
        r.negative = v < 0;
        r.magnitude = r.negative ? -cast(ulong) v : v;
    }
    else if ((source.type == TdsType.decimalN || source.type == TdsType.numericN) && data.length >= 2)
    {
        const end = data.length < 9 ? data.length : 9; // the sign byte, then up to 8 bytes
        foreach (b; data[end .. $])
            if (b != 0)
                return r; // above 64 bits
        foreach_reverse (b; data[1 .. end])
            r.magnitude = (r.magnitude << 8) | b;
        r.negative = data[0] == 0 && r.magnitude != 0;
        from = source.scale;
    }
    else
        return r;
    if (scale >= from)
    {
        if (scale - from >= 20)
        {
            r.ok = r.magnitude == 0;
            return r;
        }
        const factor = powersOf10[scale - from];
        if (r.magnitude > ulong.max / factor)
            return r;
        r.magnitude *= factor;
        r.ok = true;
        return r;
    }
    if (from - scale >= 20)
        return r;
    const divisor = powersOf10[from - scale];
    const remainder = r.magnitude % divisor;
    r.magnitude /= divisor;
    if (remainder >= divisor - remainder) // half away from zero
        r.magnitude++;
    r.negative = r.negative && r.magnitude != 0;
    r.ok = true;
    return r;
}

/// A decimal of precision `precision` from its sign and 64-bit magnitude.
private immutable(ubyte)[] smallDecimalBytes(bool negative, ulong magnitude, uint precision,
        lazy ClientException tooLarge) @safe
{
    if (precision < 20 && magnitude >= powersOf10[precision])
        throw tooLarge;
    const size = precision <= 9 ? 4 : precision <= 19 ? 8 : precision <= 28 ? 12 : 16;
    auto b = new ubyte[1 + size];
    b[0] = negative ? 0 : 1;
    foreach (i; 0 .. 8 < size ? 8 : size)
        b[1 + i] = cast(ubyte)(magnitude >> (8 * i));
    return (() @trusted => cast(immutable(ubyte)[]) b)(); // unique: built here
}

/// money or smallmoney from a sign and magnitude at scale 4.
private immutable(ubyte)[] smallMoneyBytes(bool negative, ulong magnitude, uint size,
        lazy ClientException tooLarge) @safe
{
    const limit = size == 4 ? cast(ulong) int.max : cast(ulong) long.max;
    if (magnitude > limit + (negative ? 1 : 0))
        throw tooLarge;
    const v = negative ? -cast(long) magnitude : cast(long) magnitude;
    return size == 4 ? le(v, 4) : le(v >> 32, 4) ~ le(v & 0xFFFF_FFFF, 4);
}

/// money (8 bytes: high half, then low half) or smallmoney (4 bytes) of `d` at scale 4.
private immutable(ubyte)[] moneyBytes(const Decimal d, uint size, lazy ClientException tooLarge) @safe
{
    import std.bigint : BigInt;

    const u = d.unscaled.toBigInt();
    if (size == 4)
    {
        if (u < int.min || u > int.max)
            throw tooLarge;
        return le(u.toLong(), 4);
    }
    if (u < long.min || u > long.max)
        throw tooLarge;
    const v = u.toLong();
    return le(v >> 32, 4) ~ le(v & 0xFFFF_FFFF, 4);
}

private enum long ticksPerDay = 864_000_000_000L;
private enum int days1900 = 693_595; // days from 0001-01-01 to 1900-01-01

/// A date/time value in the column type `t` (date, time(n), datetime2(n), datetimeoffset(n), datetime, smalldatetime).
private immutable(ubyte)[] temporalBytes(const ref TypeInfo t, const Temporal v, lazy ClientException mismatch,
        lazy ClientException outOfRange) @safe
{
    const hasDate = v.kind != TemporalKind.time;
    const hasTime = v.kind != TemporalKind.date;
    long days = v.days;
    long ticks = v.ticks;
    switch (nullableForm(t.type))
    {
    case TdsType.dateN:
        if (!hasDate)
            throw mismatch;
        return le(days, 3);
    case TdsType.timeN:
        if (!hasTime)
            throw mismatch;
        ticks = roundTicks(ticks, t.scale);
        if (ticks >= ticksPerDay)
            throw outOfRange;
        return le(ticks / unitOf(t.scale), timeLength(t.scale));
    case TdsType.datetime2N:
        if (!hasDate)
            throw mismatch;
        ticks = roundTicks(ticks, t.scale);
        carry(days, ticks);
        if (days > 3_652_058)
            throw outOfRange;
        return le(ticks / unitOf(t.scale), timeLength(t.scale)) ~ le(days, 3);
    case TdsType.datetimeOffsetN:
        if (!hasDate)
            throw mismatch;
        // stored as UTC; values without an offset are taken as UTC (as they are read)
        long utc = days * ticksPerDay + ticks - v.offset * 600_000_000L;
        utc = roundTicks(utc, t.scale);
        if (utc < 0 || utc >= 3_652_059 * ticksPerDay)
            throw outOfRange;
        return le((utc % ticksPerDay) / unitOf(t.scale), timeLength(t.scale)) ~ le(utc / ticksPerDay, 3) ~ le(
                v.offset, 2);
    case TdsType.datetimeN:
        if (!hasDate)
            throw mismatch;
        if (t.maxLength == 4)
        {
            // smalldatetime: to the minute, 29.998 seconds and more round up
            long minutes = (ticks + 299_990_000) / 600_000_000L;
            if (minutes >= 1440)
            {
                minutes -= 1440;
                days++;
            }
            const day = days - days1900;
            if (day < 0 || day > 65_535 || (day == 65_535 && minutes > 0))
                throw outOfRange;
            return le(day, 2) ~ le(minutes, 2);
        }
        // datetime: 1/300 s
        long units = (ticks * 3 + 50_000) / 100_000;
        if (units >= 300L * 86_400)
        {
            units -= 300L * 86_400;
            days++;
        }
        const day = days - days1900;
        if (day < -53_690 || day > 2_958_463)
            throw outOfRange;
        return le(day, 4) ~ le(units, 4);
    default:
        throw mismatch;
    }
}

/// `ticks` (100 ns) rounded half up to `scale` fraction digits.
private long roundTicks(long ticks, uint scale) @safe pure nothrow @nogc
{
    const unit = unitOf(scale);
    return (ticks + unit / 2) / unit * unit;
}

private void carry(ref long days, ref long ticks) @safe pure nothrow @nogc
{
    if (ticks >= ticksPerDay)
    {
        ticks -= ticksPerDay;
        days++;
    }
}

private long unitOf(uint scale) @safe pure nothrow @nogc
{
    long unit = 1;
    foreach (_; scale .. 7)
        unit *= 10;
    return unit;
}

private size_t timeLength(uint scale) @safe pure nothrow @nogc
{
    return scale <= 2 ? 3 : scale <= 4 ? 4 : 5;
}

private immutable(ubyte)[] le(long value, size_t n) @safe pure nothrow
{
    auto b = new ubyte[n];
    foreach (i; 0 .. n)
        b[i] = cast(ubyte)(value >> (8 * i));
    return (() @trusted => cast(immutable(ubyte)[]) b)(); // unique: built here
}

private void appendLE(ref ubyte[] buffer, ulong value, size_t n) @safe pure nothrow
{
    foreach (i; 0 .. n)
        buffer ~= cast(ubyte)(value >> (8 * i));
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
    import std.datetime.date : DateTime;
    import mssql.types.typeinfo : Collation;

    static TypeInfo column(TdsType type, uint length, ubyte precision = 0, ubyte scale = 0)
    {
        auto t = TypeInfo(type, ValueFormat.fixed, length);
        t.precision = precision;
        t.scale = scale;
        return bulkType(t);
    }

    ubyte[] b;
    const dec = column(TdsType.decimalN, 9, 10, 2);
    assert(declaration(dec) == "decimal(10,2)");
    auto p = Parameter.of(Decimal.fromString("-1.255")); // rounded half away from zero to -1.26
    appendValue(b, dec, p, "d");
    assert(b == [9, 0x00, 0x7E, 0, 0, 0, 0, 0, 0, 0]);

    const tiny = column(TdsType.intN, 1);
    b = null;
    p = Parameter.of(200);
    appendValue(b, tiny, p, "t");
    assert(b == [1, 200] && declaration(tiny) == "tinyint");
    p = Parameter.of(300);
    assertThrown!ClientException(appendValue(b, tiny, p, "t"));

    auto varchar = TypeInfo(TdsType.bigVarchar, ValueFormat.ushortLength, 10);
    varchar.collation = Collation(0x419, 0x0D, 0, 0); // Cyrillic_General_CI_AS: code page 1251
    varchar = bulkType(varchar);
    b = null;
    p = Parameter.of("мир");
    appendValue(b, varchar, p, "v");
    assert(b == [3, 0, 0xEC, 0xE8, 0xF0]);
    p = Parameter.of("日本");
    assertThrown!ClientException(appendValue(b, varchar, p, "v")); // not in code page 1251

    const datetime = column(TdsType.datetime, 8);
    b = null;
    p = Parameter.of(DateTime(2024, 1, 31, 12, 34, 56)); // golden bytes from SQL Server (M2)
    appendValue(b, datetime, p, "dt");
    assert(b == [0x08, 0xB1, 0x00, 0x00, 0x40, 0x59, 0xCF, 0x00]); // fixed DATETIME (NOT NULL): no length
    b = null;
    const nullableDatetime = column(TdsType.datetimeN, 8);
    appendValue(b, nullableDatetime, p, "dt");
    assert(b[0] == 8 && b.length == 9);
    b = null;
    p = Parameter.nullOf!int;
    appendValue(b, tiny, p, "t");
    assert(b == [0]);
    // the 64-bit fast path and the BigInt path agree, and round the same way
    foreach (text; ["-1.255", "1.245", "0.005", "-0.004", "99999999.995", "12345678901234567.891"])
    {
        ubyte[] fast, slow;
        p = Parameter.of(Decimal.fromString(text));
        const wide = column(TdsType.decimalN, 17, 38, 2);
        appendValue(fast, wide, p, "d");
        slow ~= cast(ubyte) 17;
        slow ~= decimalBytes(Decimal.fromString(text).rescaled(2, RoundingMode.halfUp), 38, null);
        assert(fast == slow, text);
    }
    const money = column(TdsType.moneyN, 8);
    b = null;
    p = Parameter.of(Decimal.fromString("-922337203685477.5808"));
    appendValue(b, money, p, "m");
    assert(b == [8, 0x00, 0x00, 0x00, 0x80, 0, 0, 0, 0]); // long.min: the high half first
    p = Parameter.of(Decimal.fromString("922337203685477.5808"));
    assertThrown!ClientException(appendValue(b, money, p, "m"));

    const notNull = column(TdsType.int4, 4);
    assertThrown!ClientException(appendValue(b, notNull, p, "n")); // NOT NULL
}
