/++
One value as the server sent it, with getters converting it to D types:
`Value` (a cell of a row, an output parameter).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.value;

import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.variant : Variant;
import dbwire.types.decimal : Decimal;
import mssql.exception : ClientException;
import mssql.types.temporal : Temporal, TemporalKind, decodeTemporal;
import mssql.types.typeinfo : TypeInfo;
import mssql.types.values : decimalValue, floatValue, integerValue, textValue, uuidValue, variantValue;

/++
A value of type `type` in its wire form. The getters convert it; a NULL gives
the getter's zero value (`0`, `null`, `T.init`), so check `isNull` to tell NULL
apart. A getter that can't convert the type throws a `ClientException`.

The bytes may belong to a buffer that is reused for the next row: a `Value`
of a row is valid until the result moves on (output parameters keep theirs).
+/
struct Value
{
    /// The type.
    TypeInfo type;
    /// The bytes as the server sent them (joined chunks for `(max)` types); `null` for NULL.
    const(ubyte)[] bytes;
    /// Whether the value is NULL.
    bool isNull = true;

    /++
    As a `long`: integers and `bit`; decimals and money truncated towards zero.

    Throws: `ClientException` for other types, or if a decimal doesn't fit.
    +/
    long getLong() const @safe
    {
        return isNull ? 0 : integerValue(type, bytes);
    }

    /++
    As an `int` (see `getLong`).

    Throws: `ClientException` for other types, or if the value does not fit.
    +/
    int getInt() const @safe
    {
        import std.conv : to;

        const v = getLong();
        if (v < int.min || v > int.max)
            throw new ClientException("Value " ~ v.to!string ~ " does not fit in an int");
        return cast(int) v;
    }

    /// As a `bool` (see `getLong`: non-zero is true).
    bool getBool() const @safe
    {
        return getLong() != 0;
    }

    /++
    As a `double`: `real`, `float`, integers, decimals and money.

    Throws: `ClientException` for other types.
    +/
    double getDouble() const @safe
    {
        return isNull ? 0 : floatValue(type, bytes);
    }

    /++
    As an exact `Decimal`: `decimal`/`numeric` with their scale,
    `money`/`smallmoney` with scale 4, integers with scale 0.

    Throws: `ClientException` for other types.
    +/
    Decimal getDecimal() const @safe
    {
        return isNull ? Decimal.init : decimalValue(type, bytes);
    }

    /++
    As text, as SQL Server writes it (see `mssql.types.values.textValue`):
    strings as they are, numbers in decimal, dates like `2024-01-31 12:34:56.1234567`.

    Throws: `ClientException` for types without a text form yet.
    +/
    string getString() const @safe
    {
        return isNull ? null : textValue(type, bytes);
    }

    /// The raw bytes, as the server sent them (a copy).
    ubyte[] getBytes() const @safe
    {
        return isNull ? null : bytes.dup;
    }

    /++
    The date: `date`, `datetime2`, `datetimeoffset` (its local date),
    `datetime`, `smalldatetime`.

    Throws: `ClientException` for other types.
    +/
    Date getDate() const @safe
    {
        Temporal t;
        return temporal(t) ? t.date : Date.init;
    }

    /++
    The time of day, without the fraction of a second (see `getDuration`):
    `time`, `datetime2`, `datetimeoffset` (its local time), `datetime`, `smalldatetime`.

    Throws: `ClientException` for other types.
    +/
    TimeOfDay getTime() const @safe
    {
        Temporal t;
        return temporal(t) ? t.timeOfDay : TimeOfDay.init;
    }

    /++
    The time of day as the exact time since midnight (100 ns precision); for
    the same types as `getTime`.

    Throws: `ClientException` for other types.
    +/
    Duration getDuration() const @safe
    {
        Temporal t;
        return temporal(t) ? t.sinceMidnight : Duration.zero;
    }

    /++
    As a `DateTime`, without the fraction of a second: `datetime2`,
    `datetimeoffset` (its local time), `datetime`, `smalldatetime`, `date` (at midnight).

    Throws: `ClientException` for other types.
    +/
    DateTime getDateTime() const @safe
    {
        Temporal t;
        if (!temporal(t))
            return DateTime.init;
        if (t.kind == TemporalKind.time)
            throw new ClientException("Cannot read a time value as a date and time");
        return t.dateTime;
    }

    /++
    As an exact `SysTime`: `datetimeoffset` with a time zone of its offset;
    `datetime2`, `datetime`, `smalldatetime` and `date` (at midnight) taken as
    UTC, as they have no time zone.

    Throws: `ClientException` for other types.
    +/
    SysTime getSysTime() const @safe
    {
        Temporal t;
        if (!temporal(t))
            return SysTime.init;
        if (t.kind == TemporalKind.time)
            throw new ClientException("Cannot read a time value as a point in time");
        return t.sysTime;
    }

    /++
    The `uniqueidentifier`.

    Throws: `ClientException` for other types.
    +/
    UUID getUUID() const @safe
    {
        return isNull ? UUID.init : uuidValue(type, bytes);
    }

    /++
    As a `Variant` of the type's natural D type (see
    `mssql.types.values.variantValue`); an empty `Variant` for NULL.

    Throws: `ClientException` for types that are not supported yet.
    +/
    Variant getVariant() const @safe
    {
        return isNull ? Variant.init : variantValue(type, bytes);
    }

    private bool temporal(out Temporal t) const @safe
    {
        if (isNull)
            return false;
        t = decodeTemporal(type, bytes);
        return true;
    }
}

///
@safe unittest
{
    import mssql.types.typeinfo : TdsType, ValueFormat;

    auto v = Value(TypeInfo(TdsType.intN, ValueFormat.byteLength, 4), [0x2A, 0, 0, 0], false);
    assert(v.getInt() == 42 && v.getString() == "42" && v.getDecimal() == Decimal.fromLong(42));
    v = Value(v.type);
    assert(v.isNull && v.getLong() == 0 && v.getString() is null);
}
