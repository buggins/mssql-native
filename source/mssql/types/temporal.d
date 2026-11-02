/++
Date and time values on the wire ([MS-TDS] 2.2.5.5.1.7–2.2.5.5.1.8): `date`,
`time(n)`, `datetime2(n)`, `datetimeoffset(n)`, `datetime` and
`smalldatetime`, and their conversions to D values and text.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.types.temporal;

import core.time : Duration, hnsecs, minutes;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import mssql.exception : ClientException;
import mssql.types.typeinfo : TdsType, TypeInfo;

/// What a temporal value holds.
enum TemporalKind
{
    date, /// a date
    time, /// a time of day
    dateTime, /// a date and time without time zone
    dateTimeOffset, /// a date and time with an offset from UTC
}

/++
A decoded date/time value, in the local time of the value (for
`datetimeoffset`, the time at its offset).
+/
struct Temporal
{
    /// What the value holds.
    TemporalKind kind;
    /// Days since 0001-01-01 (0 for `time`).
    int days;
    /// Time of day in 100 ns units (0 for `date`).
    long ticks;
    /// Offset from UTC in minutes (`datetimeoffset`).
    short offset;
    /// Fraction digits of the text form: the scale, 3 for `datetime`, 0 for `smalldatetime`.
    ubyte digits;

    /// The date (the local date for `datetimeoffset`).
    @property Date date() const @safe pure nothrow
    {
        return Date(days + 1);
    }

    /// The time of day, without the fraction of a second.
    @property TimeOfDay timeOfDay() const @safe pure
    {
        const s = ticks / ticksPerSecond;
        return TimeOfDay(cast(int)(s / 3600), cast(int)(s / 60 % 60), cast(int)(s % 60));
    }

    /// The time of day as the exact time since midnight.
    @property Duration sinceMidnight() const @safe pure nothrow @nogc
    {
        return hnsecs(ticks);
    }

    /// The date and time, without the fraction of a second (local for `datetimeoffset`).
    @property DateTime dateTime() const @safe pure
    {
        return DateTime(date, timeOfDay);
    }

    /++
    The exact point in time: values without an offset are taken as UTC, a
    `datetimeoffset` gets a time zone with its offset.
    +/
    @property SysTime sysTime() const @safe
    {
        import std.datetime.timezone : SimpleTimeZone, UTC;

        const local = days * ticksPerDay + ticks;
        if (kind != TemporalKind.dateTimeOffset)
            return SysTime(local, UTC());
        return SysTime(local - offset * ticksPerMinute, new immutable SimpleTimeZone(minutes(offset)));
    }

    /++
    The value as SQL Server's `CONVERT(nvarchar, x)` writes it for `date`,
    `time`, `datetime2` and `datetimeoffset` (e.g. `2024-01-31 12:34:56.1234567 +01:00`),
    and with styles 121 and 120 for `datetime` and `smalldatetime`.
    +/
    string toString() const @safe pure
    {
        import std.format : format;

        string s;
        if (kind != TemporalKind.time)
        {
            const d = date;
            s = format("%04d-%02d-%02d", d.year, d.month, d.day);
            if (kind == TemporalKind.date)
                return s;
            s ~= ' ';
        }
        const seconds = ticks / ticksPerSecond;
        s ~= format("%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60);
        if (digits > 0)
            s ~= format(".%07d", ticks % ticksPerSecond)[0 .. 1 + digits];
        if (kind == TemporalKind.dateTimeOffset)
        {
            const int a = offset < 0 ? -cast(int) offset : offset;
            s ~= format(" %s%02d:%02d", offset < 0 ? '-' : '+', a / 60, a % 60);
        }
        return s;
    }
}

private enum long ticksPerSecond = 10_000_000;
private enum long ticksPerMinute = 60 * ticksPerSecond;
private enum long ticksPerDay = 86_400 * ticksPerSecond;
private enum int days1900 = 693_595; // days from 0001-01-01 to 1900-01-01

/// Whether values of type `t` are dates or times.
bool isTemporal(const ref TypeInfo t) @safe pure nothrow @nogc
{
    switch (t.type)
    {
    case TdsType.dateN:
    case TdsType.timeN:
    case TdsType.datetime2N:
    case TdsType.datetimeOffsetN:
    case TdsType.datetime:
    case TdsType.datetime4:
    case TdsType.datetimeN:
        return true;
    default:
        return false;
    }
}

/++
Decodes `bytes`, a value of the date/time type `t`.

Throws: `ClientException` if `t` is not a date/time type or the value is malformed.
+/
Temporal decodeTemporal(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe pure
{
    Temporal v;
    switch (t.type)
    {
    case TdsType.dateN:
        v.kind = TemporalKind.date;
        v.days = cast(int) le(t, bytes, 3);
        break;
    case TdsType.timeN:
        v.kind = TemporalKind.time;
        v.ticks = timeTicks(t, bytes);
        v.digits = t.scale;
        break;
    case TdsType.datetime2N:
        v.kind = TemporalKind.dateTime;
        v.ticks = timeTicks(t, bytes[0 .. checked(t, bytes, timeLength(t.scale) + 3) - 3]);
        v.days = cast(int) le(t, bytes[$ - 3 .. $], 3);
        v.digits = t.scale;
        break;
    case TdsType.datetimeOffsetN:
        v.kind = TemporalKind.dateTimeOffset;
        const n = checked(t, bytes, timeLength(t.scale) + 5);
        const utc = timeTicks(t, bytes[0 .. n - 5]) + le(t, bytes[n - 5 .. n - 2], 3) * ticksPerDay;
        v.offset = cast(short) le(t, bytes[n - 2 .. n], 2, true);
        if (v.offset < -14 * 60 || v.offset > 14 * 60)
            throw invalid(t);
        const local = utc + v.offset * ticksPerMinute;
        if (local < 0)
            throw invalid(t);
        v.days = cast(int)(local / ticksPerDay);
        v.ticks = local % ticksPerDay;
        v.digits = t.scale;
        break;
    case TdsType.datetime:
    case TdsType.datetime4:
    case TdsType.datetimeN:
        v.kind = TemporalKind.dateTime;
        if (bytes.length == 8)
        {
            // days since 1900-01-01 (negative back to 1753), then 1/300 s since midnight
            const day = le(t, bytes[0 .. 4], 4, true);
            const units = le(t, bytes[4 .. 8], 4);
            if (units >= 300L * 86_400 || day < -53_690 || day > 2_958_463)
                throw invalid(t);
            // to milliseconds as SQL Server rounds them (.000, .003, .007, ...)
            const ms = (units * 10 + 1) / 3;
            v.days = cast(int)(days1900 + day);
            v.ticks = ms * 10_000;
            v.digits = 3;
        }
        else
        {
            // smalldatetime: days since 1900-01-01, then minutes since midnight
            checked(t, bytes, 4);
            const day = le(t, bytes[0 .. 2], 2);
            const mins = le(t, bytes[2 .. 4], 2);
            if (mins >= 24 * 60)
                throw invalid(t);
            v.days = days1900 + cast(int) day;
            v.ticks = mins * ticksPerMinute;
        }
        break;
    default:
        throw new ClientException("Cannot read a " ~ t.name ~ " value as a date or time");
    }
    if (v.days > 3_652_058 || v.ticks >= ticksPerDay) // after 9999-12-31
        throw invalid(t);
    return v;
}

/// Bytes of the time part of `time(n)`, `datetime2(n)` and `datetimeoffset(n)`.
private size_t timeLength(uint scale) @safe pure nothrow @nogc
{
    return scale <= 2 ? 3 : scale <= 4 ? 4 : 5;
}

/// The time part (10^-scale s since midnight) in 100 ns units.
private long timeTicks(const ref TypeInfo t, scope const(ubyte)[] bytes) @safe pure
{
    const n = timeLength(t.scale);
    long v = le(t, bytes, n);
    foreach (_; t.scale .. 7)
        v *= 10;
    return v;
}

/// A little-endian integer of exactly `n` bytes (at most 5), sign-extended if `signed`.
private long le(const ref TypeInfo t, scope const(ubyte)[] bytes, size_t n, bool signed = false) @safe pure
{
    if (bytes.length != n)
        throw invalid(t);
    long v;
    foreach_reverse (b; bytes)
        v = (v << 8) | b;
    if (signed && (bytes[$ - 1] & 0x80))
        v -= 1L << (8 * n);
    return v;
}

private size_t checked(const ref TypeInfo t, scope const(ubyte)[] bytes, size_t n) @safe pure
{
    if (bytes.length != n)
        throw invalid(t);
    return n;
}

private ClientException invalid(const ref TypeInfo t) @safe pure
{
    return new ClientException("Invalid " ~ t.name ~ " value");
}

///
@safe unittest
{
    import mssql.types.typeinfo : ValueFormat;

    static TypeInfo type(TdsType t, ubyte scale = 0, uint length = 8)
    {
        auto info = TypeInfo(t, ValueFormat.byteLength, length);
        info.scale = scale;
        return info;
    }

    // golden bytes from SQL Server 2022
    // datetime2(7) '2024-01-31 12:34:56.1234567': time (5 bytes), then days since 0001-01-01 (3 bytes)
    const dt2 = type(TdsType.datetime2N, 7);
    const v = decodeTemporal(dt2, [0x87, 0xEE, 0x97, 0x76, 0x69, 0x63, 0x46, 0x0B]);
    assert(v.toString() == "2024-01-31 12:34:56.1234567");
    assert(v.date == Date(2024, 1, 31) && v.timeOfDay == TimeOfDay(12, 34, 56));
    assert(v.sysTime.toISOExtString() == "2024-01-31T12:34:56.1234567Z");

    // datetimeoffset(7) '2024-01-31 12:34:56.1234567 -05:30': UTC date and time, then the offset
    const dtoType = type(TdsType.datetimeOffsetN, 7);
    const dto = decodeTemporal(dtoType, [
        0x87, 0x2A, 0x50, 0x90, 0x97, 0x63, 0x46, 0x0B, 0xB6, 0xFE
    ]);
    assert(dto.toString() == "2024-01-31 12:34:56.1234567 -05:30");
    assert(dto.sysTime.toISOExtString() == "2024-01-31T12:34:56.1234567-05:30");
    assert(dto.sysTime.toUTC().toISOExtString() == "2024-01-31T18:04:56.1234567Z");

    const date = type(TdsType.dateN);
    assert(decodeTemporal(date, [0x63, 0x46, 0x0B]).toString() == "2024-01-31");
    const timeType = type(TdsType.timeN, 2);
    const time2 = decodeTemporal(timeType, [0xCC, 0x1D, 0x45]);
    assert(time2.toString() == "12:34:56.12" && time2.sinceMidnight == hnsecs(452_961_200_000));

    // datetime '2024-01-31 12:34:56.997': days since 1900-01-01, then 1/300 s
    const datetime = type(TdsType.datetimeN);
    const dt = decodeTemporal(datetime, [0x08, 0xB1, 0x00, 0x00, 0x6B, 0x5A, 0xCF, 0x00]);
    assert(dt.toString() == "2024-01-31 12:34:56.997");
    // smalldatetime '2024-01-31 12:34': days since 1900-01-01, then minutes
    const small = type(TdsType.datetimeN, 0, 4);
    assert(decodeTemporal(small, [0x08, 0xB1, 0xF2, 0x02]).toString() == "2024-01-31 12:34:00");
}

@safe unittest
{
    import std.exception : assertThrown;
    import mssql.types.typeinfo : ValueFormat;

    auto t = TypeInfo(TdsType.timeN, ValueFormat.byteLength, 5);
    t.scale = 7;
    assertThrown!ClientException(decodeTemporal(t, [0, 0, 0])); // wrong length
    assertThrown!ClientException(decodeTemporal(t, [0x00, 0xC0, 0x69, 0x2A, 0xC9])); // 24:00
    auto date = TypeInfo(TdsType.dateN, ValueFormat.byteLength, 3);
    assertThrown!ClientException(decodeTemporal(date, [0xFF, 0xFF, 0xFF])); // after 9999-12-31
    assert(decodeTemporal(date, [0xDA, 0xB9, 0x37]).toString() == "9999-12-31");
    assert(decodeTemporal(date, [0, 0, 0]).toString() == "0001-01-01");
    const int4 = TypeInfo(TdsType.int4, ValueFormat.fixed, 4);
    assertThrown!ClientException(decodeTemporal(int4, [0, 0, 0, 0]));
}
