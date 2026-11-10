/++
Parameters of queries and procedure calls: `Parameter` (a D value converted to
a SQL Server type and its wire form), and the rewriting of `?` placeholders.

D types and the SQL Server types they are sent as:

$(TABLE
$(TR $(TH D type) $(TH SQL Server type))
$(TR $(TD `bool`) $(TD `bit`))
$(TR $(TD `ubyte`) $(TD `tinyint`))
$(TR $(TD `byte`, `short`) $(TD `smallint`))
$(TR $(TD `ushort`, `int`) $(TD `int`))
$(TR $(TD `uint`, `long`) $(TD `bigint`))
$(TR $(TD `ulong`) $(TD `bigint`, or `decimal(20,0)` above `long.max`))
$(TR $(TD `float`) $(TD `real`))
$(TR $(TD `double`, `real`) $(TD `float`))
$(TR $(TD `Decimal`) $(TD `decimal(38, s)` with the value's scale))
$(TR $(TD strings, `char`) $(TD `nvarchar(4000)`, or `nvarchar(max)` when longer))
$(TR $(TD `ubyte[]`) $(TD `varbinary(8000)`, or `varbinary(max)` when longer))
$(TR $(TD `Date`) $(TD `date`))
$(TR $(TD `TimeOfDay`, `Duration`) $(TD `time(7)` (a `Duration` from 0 to 24 hours)))
$(TR $(TD `DateTime`) $(TD `datetime2(7)`))
$(TR $(TD `SysTime`) $(TD `datetimeoffset(7)` with the time's UTC offset))
$(TR $(TD `UUID`) $(TD `uniqueidentifier`))
$(TR $(TD `Nullable!T`) $(TD NULL of T's type, or T's value))
$(TR $(TD `typeof(null)`) $(TD NULL `nvarchar(4000)`))
$(TR $(TD `Variant`) $(TD by its content; empty: NULL `nvarchar(4000)`))
)

A NULL needs a type the server can convert to the column's type: a NULL
`nvarchar` doesn't convert to `varbinary` implicitly; use `Parameter.nullOf!(ubyte[])`
(or `Nullable!(ubyte[])`) there.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.params;

import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.traits : isFloatingPoint, isIntegral, isSomeChar, isSomeString, Unqual;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;
import dbwire.io.buffer : toLittleEndian;
import dbwire.types.decimal : Decimal;
import mssql.exception : ClientException;
import mssql.types.typeinfo : TdsType, TypeInfo, ValueFormat;

/// A parameter: its name, SQL Server type, and value in wire form.
struct Parameter
{
    /// The name with its `@` (e.g. `@p1`); empty for a positional procedure parameter.
    string name;
    /// The wire type.
    TypeInfo type;
    /// The type as declared in T-SQL, e.g. `nvarchar(4000)`.
    string declaration;
    /// The value's bytes (without the length prefix); `null` for NULL.
    immutable(ubyte)[] data;
    /// Whether the value is NULL.
    bool isNull;
    /// Whether it is an output parameter (`OUTPUT`): its value comes back in the result's `outputs`.
    bool isOutput;

    /++
    The parameter for `value` (see the module documentation for the types).
    Attributes are inferred; `value` is taken by reference when it can be, so
    `@safe` code can pass a `Variant` (whose copies are `@system`).

    Throws: `ClientException` for values SQL Server can't hold (NaN and
    infinity, a `Decimal` with more than 38 digits or a scale above 38, a
    `Duration` outside 0 to 24 hours, a date before year 1).
    +/
    static Parameter of(T)(auto ref T value)
    {
        alias U = Unqual!T;
        static if (is(U == Parameter))
            return value;
        else static if (is(U == typeof(null)))
            return nullOf!string();
        else static if (is(U : Nullable!V, V))
            return value.isNull ? nullOf!V() : of(value.get);
        else static if (is(U == Variant))
            return ofVariant(value);
        else
            return make(value);
    }

    /// A NULL of the SQL Server type for D type `T`.
    static Parameter nullOf(T)()
    {
        auto p = typeOf!(Unqual!T)();
        p.isNull = true;
        return p;
    }

    /++
    An output parameter with the type of `T` and the initial value `initial`
    (procedures may read it); its value after the call is in the result's
    `outputs`.
    +/
    static Parameter output(T)(auto ref T initial)
    {
        auto p = of(initial);
        p.isOutput = true;
        return p;
    }

    /// An output parameter of the SQL Server type for D type `T`, initially NULL.
    static Parameter outputOf(T)()
    {
        auto p = nullOf!T();
        p.isOutput = true;
        return p;
    }

    /// This parameter with the name `name` (`@` is added if missing): for named procedure parameters.
    Parameter named(string name) const @safe pure nothrow
    {
        Parameter p = this;
        p.name = name.length && name[0] != '@' ? "@" ~ name : name;
        return p;
    }
}

///
@safe unittest
{
    const p = Parameter.of(42);
    assert(p.declaration == "int" && p.data == [42, 0, 0, 0] && !p.isNull);
    assert(Parameter.of("Grüße").declaration == "nvarchar(4000)");
    assert(Parameter.of(Decimal.fromString("-1.50")).declaration == "decimal(38,2)");
    assert(Parameter.nullOf!(ubyte[]).declaration == "varbinary(8000)");
    assert(Parameter.of(Nullable!int()).isNull && Parameter.of(null).declaration == "nvarchar(4000)");
    assert(Parameter.outputOf!long.named("total").name == "@total");
}

/// A parameter of type `t` without a value.
private Parameter typed(TdsType t, ValueFormat format, uint maxLength, string declaration,
        ubyte scale = 0) @safe pure nothrow
{
    Parameter p;
    p.type = TypeInfo(t, format, maxLength);
    p.type.scale = scale;
    p.declaration = declaration;
    return p;
}

/// The type of parameters of D type `T` (sizes for typical values).
private Parameter typeOf(T)()
{
    static if (is(T == bool))
        return typed(TdsType.bitN, ValueFormat.byteLength, 1, "bit");
    else static if (is(T == ubyte))
        return typed(TdsType.intN, ValueFormat.byteLength, 1, "tinyint");
    else static if (is(T == byte) || is(T == short))
        return typed(TdsType.intN, ValueFormat.byteLength, 2, "smallint");
    else static if (is(T == ushort) || is(T == int))
        return typed(TdsType.intN, ValueFormat.byteLength, 4, "int");
    else static if (isIntegral!T)
        return typed(TdsType.intN, ValueFormat.byteLength, 8, "bigint");
    else static if (is(T == float))
        return typed(TdsType.floatN, ValueFormat.byteLength, 4, "real");
    else static if (isFloatingPoint!T)
        return typed(TdsType.floatN, ValueFormat.byteLength, 8, "float");
    else static if (isSomeString!T || isSomeChar!T)
        return typed(TdsType.nvarchar, ValueFormat.ushortLength, 8000, "nvarchar(4000)");
    else static if (is(T : const(ubyte)[]))
        return typed(TdsType.bigVarbinary, ValueFormat.ushortLength, 8000, "varbinary(8000)");
    else static if (is(T == Decimal))
        return decimalType(0);
    else static if (is(T == Date))
        return typed(TdsType.dateN, ValueFormat.byteLength, 3, "date");
    else static if (is(T == TimeOfDay) || is(T == Duration))
        return typed(TdsType.timeN, ValueFormat.byteLength, 5, "time(7)", 7);
    else static if (is(T == DateTime))
        return typed(TdsType.datetime2N, ValueFormat.byteLength, 8, "datetime2(7)", 7);
    else static if (is(T == SysTime))
        return typed(TdsType.datetimeOffsetN, ValueFormat.byteLength, 10, "datetimeoffset(7)", 7);
    else static if (is(T == UUID))
        return typed(TdsType.guid, ValueFormat.byteLength, 16, "uniqueidentifier");
    else static if (is(T == typeof(null)))
        return typeOf!string();
    else
        static assert(0, "Parameters of type " ~ T.stringof ~ " are not supported");
}

private Parameter decimalType(int scale) @safe pure
{
    import std.conv : to;

    auto p = typed(TdsType.decimalN, ValueFormat.byteLength, 17,
            "decimal(38," ~ scale.to!string ~ ")", cast(ubyte) scale);
    p.type.precision = 38;
    return p;
}

/// The parameter for a value of a supported D type.
private Parameter make(T)(T value)
{
    alias U = Unqual!T;
    auto p = typeOf!U();
    static if (is(U == bool))
        p.data = [value ? 1 : 0];
    else static if (is(U == ulong))
    {
        if (value > long.max)
            return make(Decimal.fromBigInt(bigUnsigned(value), 0));
        p.data = littleEndian(cast(long) value, 8);
    }
    else static if (isIntegral!U)
        p.data = littleEndian(value, p.type.maxLength);
    else static if (isFloatingPoint!U)
    {
        import std.math : isFinite;

        if (!isFinite(value))
            throw new ClientException("SQL Server can't store NaN or infinity (a parameter of type " ~ U.stringof
                    ~ ")");
        static if (is(U == float))
            p.data = ieee(value);
        else
            p.data = ieee(cast(double) value);
    }
    else static if (isSomeString!U || isSomeChar!U)
    {
        import std.conv : to;
        import dbwire.charset.utf16 : encodeUtf16le;

        static if (isSomeChar!U)
            const text = [value].to!string;
        else
            const text = value.to!string;
        immutable(ubyte)[] bytes = encodeUtf16le(text); // a pure function's new array converts to immutable
        if (bytes.length > 8000)
            p = typed(TdsType.nvarchar, ValueFormat.plp, 0xFFFF, "nvarchar(max)");
        p.data = bytes;
    }
    else static if (is(U : const(ubyte)[]))
    {
        if (value.length > 8000)
            p = typed(TdsType.bigVarbinary, ValueFormat.plp, 0xFFFF, "varbinary(max)");
        p.data = value.idup;
    }
    else static if (is(U == Decimal))
        p = decimalParameter(value);
    else static if (is(U == Date))
        p.data = days(value);
    else static if (is(U == TimeOfDay))
        p.data = littleEndian((value.hour * 3600L + value.minute * 60 + value.second) * 10_000_000, 5);
    else static if (is(U == Duration))
    {
        const ticks = value.total!"hnsecs";
        if (ticks < 0 || ticks >= 864_000_000_000L)
            throw new ClientException("A time parameter must be from 0 to 24 hours");
        p.data = littleEndian(ticks, 5);
    }
    else static if (is(U == DateTime))
    {
        const t = value.timeOfDay;
        p.data = littleEndian((t.hour * 3600L + t.minute * 60 + t.second) * 10_000_000, 5) ~ days(value.date);
    }
    else static if (is(U == SysTime))
    {
        if (value.timezone is null)
            throw new ClientException("A SysTime parameter needs a time zone");
        const offset = value.utcOffset.total!"minutes";
        const std = value.stdTime; // 100 ns units since 0001-01-01 UTC
        if (std < 0 || std >= 3_652_059 * 864_000_000_000L)
            throw new ClientException("A SysTime parameter must be in the years 1 to 9999");
        p.data = littleEndian(std % 864_000_000_000L, 5) ~ littleEndian(std / 864_000_000_000L, 3) ~ littleEndian(
                offset, 2);
    }
    else static if (is(U == UUID))
    {
        const b = value.data;
        p.data = [
            b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13],
            b[14], b[15]
        ];
    }
    else
        static assert(0, "Parameters of type " ~ T.stringof ~ " are not supported");
    return p;
}

private Parameter decimalParameter(const Decimal value) @safe
{
    import std.bigint : BigInt;

    Decimal d = value.scale < 0 ? value.rescaled(0) : value;
    if (d.scale > 38)
        throw new ClientException("Decimal parameter " ~ value.toString() ~ ": scale above 38");
    auto p = decimalType(d.scale);
    // the unscaled value fits in a long: no BigInt needed (the common case)
    const w = d.unscaled.words;
    const high = (w[0] >> 63) != 0 ? ulong.max : 0;
    if (w[1] == high && w[2] == high && w[3] == high)
    {
        const v = cast(long) w[0];
        const magnitude = v < 0 ? -cast(ulong) v : cast(ulong) v;
        ubyte[17] small;
        small[0] = v < 0 ? 0 : 1;
        small[1 .. 9] = toLittleEndian(magnitude);
        p.data = small.idup;
        return p;
    }
    BigInt u = d.unscaled.toBigInt();
    const negative = u < 0;
    if (negative)
        u = -u;
    if (u >= BigInt(10) ^^ 38)
        throw new ClientException("Decimal parameter " ~ value.toString() ~ ": more than 38 digits");
    ubyte[17] data;
    data[0] = negative ? 0 : 1;
    data[1 .. 9] = toLittleEndian(u.getDigit!ulong(0));
    data[9 .. 17] = toLittleEndian(u.ulongLength > 1 ? u.getDigit!ulong(1) : 0); // below 10^38 < 2^128
    p.data = data.idup;
    return p;
}

private bool sameType(const object.TypeInfo a, const object.TypeInfo b) @trusted
{
    return a == b; // TypeInfo.opEquals is not annotated @safe; it compares the type names
}

private Parameter ofVariant(ref const Variant value) @safe
{
    import std.meta : AliasSeq;

    alias Types = AliasSeq!(bool, byte, ubyte, short, ushort, int, uint, long, ulong, float, double, real, char,
            wchar, dchar, string, wstring, dstring, char[], ubyte[], immutable(ubyte)[], const(ubyte)[], Decimal,
            Date, TimeOfDay, Duration, DateTime, SysTime, UUID);

    if (!value.hasValue)
        return Parameter.nullOf!string();
    const type = value.type;
    // the same TypeInfo object (a pointer comparison); then equal ones, which other shared libraries may have
    size_t index = Types.length;
    static foreach (i, T; Types)
        if (index == Types.length && type is typeid(T))
            index = i;
    static foreach (i, T; Types)
        if (index == Types.length && sameType(type, typeid(T)))
            index = i;
    switch (index)
    {
        static foreach (i, T; Types)
        {
    case i:
            return Parameter.of((() @trusted => value.get!T)()); // Variant.get is @system; the type was checked
        }
    default:
        throw new ClientException("Parameters of type " ~ type.toString() ~ " are not supported");
    }
}

/// Days since 0001-01-01, in 3 bytes.
private immutable(ubyte)[] days(const Date date) @safe pure
{
    const day = date.dayOfGregorianCal - 1;
    if (day < 0 || day > Date(9999, 12, 31).dayOfGregorianCal - 1) // 3 bytes would wrap around
        throw new ClientException("Date " ~ date.toISOExtString() ~ " is outside SQL Server's range (0001 to 9999)");
    return littleEndian(day, 3);
}

/// `value` as `n` (at most 8) little-endian bytes.
package(mssql) immutable(ubyte)[] littleEndian(long value, size_t n) @safe pure nothrow
in (n <= 8)
{
    const ubyte[8] b = toLittleEndian(value);
    return b[0 .. n].idup;
}

private immutable(ubyte)[] ieee(T)(T value)
{
    import std.bitmanip : nativeToLittleEndian;

    return nativeToLittleEndian(value).idup;
}

private auto bigUnsigned(ulong value) @safe
{
    import std.bigint : BigInt;

    return BigInt(value);
}

@safe unittest
{
    import std.array : replicate;
    import std.exception : assertThrown;
    import core.time : hours, hnsecs;
    import dbwire.types.wideint : Int256;

    // the wire forms (the inverse of mssql.types.values; golden bytes from SQL Server 2022)
    assert(Parameter.of(cast(ubyte) 200).data == [200]);
    assert(Parameter.of(cast(short)-2).data == [0xFE, 0xFF] && Parameter.of(-2L).data.length == 8);
    assert(Parameter.of(true).data == [1] && Parameter.of(true).declaration == "bit");
    assert(Parameter.of(1.5).data == [0, 0, 0, 0, 0, 0, 0xF8, 0x3F]);
    assert(Parameter.of(0.1f).data == [0xCD, 0xCC, 0xCC, 0x3D] && Parameter.of(0.1f).declaration == "real");
    assert(Parameter.of("xй").data == [0x78, 0x00, 0x39, 0x04]);
    assert(Parameter.of('x').data == [0x78, 0x00]);
    assert(Parameter.of(Decimal.fromString("-1234567.89")).data == [
        0x00, 0x15, 0xCD, 0x5B, 0x07, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]);
    assert(Parameter.of(Decimal(Int256(12), -3)).data[1 .. 3] == [0xE0, 0x2E]); // negative scale
    assertThrown!ClientException(Parameter.of(Decimal.fromString("1" ~ "0".replicate(38))));
    assert(Parameter.of(Date(2024, 1, 31)).data == [0x63, 0x46, 0x0B]);
    assert(Parameter.of(DateTime(2024, 1, 31, 12, 34, 56)).data == [
        0x00, 0x18, 0x85, 0x76, 0x69, 0x63, 0x46, 0x0B
    ]);
    assert(Parameter.of(hnsecs(452_961_234_567)).data == [0x87, 0xEE, 0x97, 0x76, 0x69]);
    assertThrown!ClientException(Parameter.of(hours(24)));
    assertThrown!ClientException(Parameter.of(double.nan));
    assertThrown!ClientException(Parameter.of(-float.infinity));
    assert(Parameter.of(UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff")).data == [
        0xFF, 0x19, 0x96, 0x6F, 0x86, 0x8B, 0x11, 0xD0, 0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF
    ]);
    assert(Parameter.of(ulong.max).declaration == "decimal(38,0)");
    assert(Parameter.of("x".replicate(4001)).declaration == "nvarchar(max)");
    assert(Parameter.of(new ubyte[8001]).declaration == "varbinary(max)");
}

@safe unittest
{
    import std.datetime.timezone : SimpleTimeZone;
    import core.time : hnsecs, minutes;

    // datetimeoffset '2024-01-31 12:34:56.1234567 -05:30': UTC time, UTC date, offset
    const tz = new immutable SimpleTimeZone(minutes(-330));
    const t = SysTime(DateTime(2024, 1, 31, 12, 34, 56), hnsecs(1_234_567), tz);
    assert(Parameter.of(t).data == [0x87, 0x2A, 0x50, 0x90, 0x97, 0x63, 0x46, 0x0B, 0xB6, 0xFE]);
}

/++
Rewrites the `?` placeholders of `sql` to `@p1`, `@p2`, ... and counts them.
A `?` inside a string literal (`'...'`, `N'...'`), a quoted identifier
(`"..."`, `[...]`) or a comment (`-- ...`, `/* ... */`, which nest in T-SQL)
is left alone.
+/
string rewritePlaceholders(string sql, out size_t count) @safe pure
{
    import std.array : appender;
    import std.conv : to;

    auto result = appender!string();
    size_t i;
    size_t copied;
    void flush(size_t upTo)
    {
        result ~= sql[copied .. upTo];
        copied = upTo;
    }

    while (i < sql.length)
    {
        const c = sql[i];
        if (c == '\'' || c == '"' || c == '[')
        {
            const close = c == '[' ? ']' : c;
            i++;
            while (i < sql.length)
            {
                if (sql[i] == close)
                {
                    if (i + 1 < sql.length && sql[i + 1] == close) // doubled: an escaped quote
                    {
                        i += 2;
                        continue;
                    }
                    break;
                }
                i++;
            }
            i++;
        }
        else if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-')
        {
            while (i < sql.length && sql[i] != '\n')
                i++;
        }
        else if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*')
        {
            int depth = 1;
            i += 2;
            while (i < sql.length && depth > 0)
            {
                if (sql[i] == '/' && i + 1 < sql.length && sql[i + 1] == '*')
                {
                    depth++;
                    i += 2;
                }
                else if (sql[i] == '*' && i + 1 < sql.length && sql[i + 1] == '/')
                {
                    depth--;
                    i += 2;
                }
                else
                    i++;
            }
        }
        else if (c == '?')
        {
            flush(i);
            result ~= "@p" ~ (++count).to!string;
            i++;
            copied = i;
        }
        else
            i++;
    }
    flush(sql.length < i ? sql.length : i);
    return result.data;
}

///
@safe unittest
{
    size_t n;
    assert(rewritePlaceholders("SELECT * FROM t WHERE a = ? AND b > ?", n)
            == "SELECT * FROM t WHERE a = @p1 AND b > @p2" && n == 2);
    assert(rewritePlaceholders("SELECT '?', N'it''s ?', [a?]]b], \"c?\" -- ?\n, ? /* ? /* ? */ ? */", n)
            == "SELECT '?', N'it''s ?', [a?]]b], \"c?\" -- ?\n, @p1 /* ? /* ? */ ? */" && n == 1);
    assert(rewritePlaceholders("SELECT 'unterminated ?", n) == "SELECT 'unterminated ?" && n == 0);
}

/++
`p` (a `decimal` parameter) with the scale `scale`, which is at least its
own. Rows of one `INSERT ... VALUES` statement need one scale per column:
SQL Server gives the column the union type of its rows, and `decimal(38,4)`
with `decimal(38,0)` becomes `decimal(38,0)`, truncating the fraction.

Throws: `ClientException` if the value then needs more than 38 digits.
+/
package Parameter withDecimalScale(const Parameter p, ubyte scale) @safe
{
    import mssql.types.values : decimalValue;

    if (p.type.scale == scale)
        return p;
    if (p.isNull)
    {
        auto n = decimalType(scale);
        n.isNull = true;
        n.isOutput = p.isOutput;
        n.name = p.name;
        return n;
    }
    auto r = decimalParameter(decimalValue(p.type, p.data).rescaled(scale));
    r.isOutput = p.isOutput;
    r.name = p.name;
    return r;
}

@safe unittest
{
    const p = withDecimalScale(Parameter.of(Decimal.fromString("-12")), 4);
    assert(p.declaration == "decimal(38,4)" && p.data[1 .. 4] == [0xC0, 0xD4, 0x01]); // -120000
    assert(withDecimalScale(Parameter.nullOf!Decimal, 2).declaration == "decimal(38,2)");
}

/++
The parameters for `args`, each converted with `Parameter.of`; a single
`Parameter[]` argument is taken as the parameters themselves.
+/
const(Parameter)[] parameters(Args...)(auto ref Args args)
{
    static if (Args.length == 1 && is(Args[0] : const(Parameter)[]) && !is(Args[0] == typeof(null)))
        return args[0];
    else
        return convertAll(args);
}

private Parameter[] convertAll(Args...)(auto ref Args args)
{
    auto result = new Parameter[Args.length];
    foreach (i, ref arg; args)
        result[i] = Parameter.of(arg);
    return result;
}

/// Copies of `params` named `@p1`, `@p2`, ... (the names of rewritten placeholders).
Parameter[] numbered(const Parameter[] params) @safe pure nothrow
{
    import std.conv : to;

    auto result = new Parameter[params.length];
    foreach (i, ref p; params)
    {
        result[i] = p;
        result[i].name = "@p" ~ (i + 1).to!string;
    }
    return result;
}

/// The `@params` declaration of `sp_executesql`: `@p1 int, @p2 nvarchar(4000) OUTPUT`.
string declarations(const Parameter[] params) @safe pure nothrow
{
    string s;
    foreach (i, ref p; params)
        s ~= (i ? "," : "") ~ p.name ~ " " ~ p.declaration ~ (p.isOutput ? " OUTPUT" : "");
    return s;
}
