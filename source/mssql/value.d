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
import mssql.types.typeinfo : TdsType, TypeInfo;
import mssql.types.values : decimalValue, floatValue, integerValue, textValue, unwrapVariant, uuidValue,
    variantValue;

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
        return isNull ? 0 : integerValue(base.type, base.bytes);
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
        return isNull ? 0 : floatValue(base.type, base.bytes);
    }

    /++
    As an exact `Decimal`: `decimal`/`numeric` with their scale,
    `money`/`smallmoney` with scale 4, integers with scale 0.

    Throws: `ClientException` for other types.
    +/
    Decimal getDecimal() const @safe
    {
        return isNull ? Decimal.init : decimalValue(base.type, base.bytes);
    }

    /++
    As text, as SQL Server writes it (see `mssql.types.values.textValue`):
    strings as they are, numbers in decimal, dates like `2024-01-31 12:34:56.1234567`.

    Throws: `ClientException` for types without a text form yet.
    +/
    string getString() const @safe
    {
        return isNull ? null : textValue(base.type, base.bytes);
    }

    /// The raw bytes, as the server sent them (a copy).
    ubyte[] getBytes() const @safe pure nothrow
    {
        return isNull ? null : bytes.dup;
    }

    /++
    The date: `date`, `datetime2`, `datetimeoffset` (its local date),
    `datetime`, `smalldatetime`.

    Throws: `ClientException` for other types.
    +/
    Date getDate() const @safe pure
    {
        Temporal t;
        return temporal(t) ? t.date : Date.init;
    }

    /++
    The time of day, without the fraction of a second (see `getDuration`):
    `time`, `datetime2`, `datetimeoffset` (its local time), `datetime`, `smalldatetime`.

    Throws: `ClientException` for other types.
    +/
    TimeOfDay getTime() const @safe pure
    {
        Temporal t;
        return temporal(t) ? t.timeOfDay : TimeOfDay.init;
    }

    /++
    The time of day as the exact time since midnight (100 ns precision); for
    the same types as `getTime`.

    Throws: `ClientException` for other types.
    +/
    Duration getDuration() const @safe pure
    {
        Temporal t;
        return temporal(t) ? t.sinceMidnight : Duration.zero;
    }

    /++
    As a `DateTime`, without the fraction of a second: `datetime2`,
    `datetimeoffset` (its local time), `datetime`, `smalldatetime`, `date` (at midnight).

    Throws: `ClientException` for other types.
    +/
    DateTime getDateTime() const @safe pure
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
    SysTime getSysTime() const @safe pure
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
        return isNull ? UUID.init : uuidValue(base.type, base.bytes);
    }

    /++
    As a `Variant` of the type's natural D type (see
    `mssql.types.values.variantValue`); an empty `Variant` for NULL.

    Throws: `ClientException` for types that are not supported yet.
    +/
    Variant getVariant() const @safe
    {
        return isNull ? Variant.init : variantValue(base.type, base.bytes);
    }

    /++
    The value with its base type for a `sql_variant` (e.g. an `int` and its
    four bytes); any other value as it is. The getters convert this one.

    Throws: `ClientException` if a `sql_variant` value is malformed.
    +/
    @property Value base() const @safe pure
    {
        if (isNull || type.type != TdsType.variant)
            return Value(type, bytes, isNull);
        TypeInfo inner;
        const(ubyte)[] data;
        unwrapVariant(bytes, inner, data);
        return Value(inner, data, false);
    }

    private bool temporal(out Temporal t) const @safe pure
    {
        if (isNull)
            return false;
        t = decodeTemporal(base.type, base.bytes);
        return true;
    }
}

///
@safe unittest
{
    import mssql.types.typeinfo : ValueFormat;

    auto v = Value(TypeInfo(TdsType.intN, ValueFormat.byteLength, 4), [0x2A, 0, 0, 0], false);
    assert(v.getInt() == 42 && v.getString() == "42" && v.getDecimal() == Decimal.fromLong(42));
    v = Value(v.type);
    assert(v.isNull && v.getLong() == 0 && v.getString() is null);

    // sql_variant values carry their base type (golden bytes from SQL Server 2022)
    const variant = TypeInfo(TdsType.variant, ValueFormat.longLength, 8016);
    assert(Value(variant, [0x38, 0x00, 0x2A, 0x00, 0x00, 0x00], false).getInt() == 42);
    const ubyte[] dec = [
        0x6A, 0x02, 0x05, 0x02, 0x00, 0x96, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]; // decimal(5,2) -1.50
    assert(Value(variant, dec, false).getString() == "-1.50" && Value(variant, dec, false).base.type.name == "decimal");
    const ubyte[] text = [
        0xE7, 0x07, 0x09, 0x04, 0xD0, 0x00, 0x34, 0x04, 0x00, 0x78, 0x00, 0x39, 0x04
    ];
    assert(Value(variant, text, false).getString() == "xй"); // nvarchar: collation, max length, UTF-16
    const ubyte[] dt2 = [0x2A, 0x01, 0x07, 0x87, 0xEE, 0x97, 0x76, 0x69, 0x63, 0x46, 0x0B];
    assert(Value(variant, dt2, false).getString() == "2024-01-31 12:34:56.1234567");
    const ubyte[] money = [0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4E, 0x61, 0xBC, 0x00];
    assert(Value(variant, money, false).getDecimal().toFixedString() == "1234.5678");

    // rowversion: binary(8) with user type 80, a big-endian counter
    auto rv = TypeInfo(TdsType.bigBinary, ValueFormat.ushortLength, 8);
    rv.userType = 80;
    const ubyte[] counter = [0, 0, 0, 0, 0, 0, 0x07, 0xD1];
    assert(rv.name == "timestamp" && Value(rv, counter, false).getLong() == 2001);
    assert(Value(rv, counter, false).getString() == "0x00000000000007D1");
}
