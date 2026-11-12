/++
Data types against the server: every value's `getString` is compared with the
text SQL Server itself produces (`CONVERT(nvarchar, x, style)`).
+/
module integrationtests.types;

import std.conv : to;
import std.exception : collectException, enforce;
import std.array : split;
import std.format : format;
import mssql;
import integrationtests.server : connectToServer, scalar;

/// A value and the `CONVERT` style giving the text `getString` must match (-1: default).
private struct Case
{
    string type;
    string literal;
    int style = -1;
}

private immutable Case[] cases = [
    Case("tinyint", "0"), Case("tinyint", "255"), Case("smallint", "-32768"),
    Case("int", "-2147483648"), Case("bigint", "9223372036854775807"), Case("bit", "1"),
    Case("decimal(9,2)", "-1234567.89"), Case("decimal(10,3)", "1.5"), Case("numeric(5,0)", "0"),
    Case("decimal(19,4)", "-123456789012345.6789"),
    Case("decimal(28,10)", "123456789012345678.0123456789"),
    Case("decimal(38,0)", "99999999999999999999999999999999999999"),
    Case("decimal(38,0)", "-99999999999999999999999999999999999999"),
    Case("decimal(38,38)", "0.12345678901234567890123456789012345678"),
    Case("decimal(38,38)", "-0.00000000000000000000000000000000000001"),
    Case("money", "922337203685477.5807", 2), Case("money", "-922337203685477.5808", 2),
    Case("money", "0.0001", 2), Case("money", "-1.5", 2), Case("smallmoney", "214748.3647", 2),
    Case("smallmoney", "-214748.3648", 2), Case("smallmoney", "0", 2),
    Case("date", "'0001-01-01'"), Case("date", "'9999-12-31'"), Case("date", "'2024-02-29'"),
    Case("time", "'00:00:00'"), Case("time", "'23:59:59.9999999'"), Case("time(0)", "'12:34:56'"),
    Case("time(3)", "'01:02:03.4'"), Case("datetime2", "'0001-01-01 00:00:00'"),
    Case("datetime2", "'9999-12-31 23:59:59.9999999'"), Case("datetime2(0)", "'2024-01-31 12:34:56'"),
    Case("datetimeoffset", "'2024-01-31 12:34:56.1234567 -05:30'"),
    Case("datetimeoffset(0)", "'2024-01-31 00:00:00 +14:00'"),
    Case("datetimeoffset(3)", "'2024-01-01 01:00:00.5 -14:00'"),
    Case("datetimeoffset", "'0001-01-01 00:00:00 +00:00'"),
    Case("datetimeoffset", "'9999-12-31 23:59:59.9999999 +00:00'"),
    Case("datetime", "'1753-01-01 00:00:00'", 121), Case("datetime", "'9999-12-31 23:59:59.997'", 121),
    Case("datetime", "'1899-12-31 23:59:59.003'", 121),
    Case("datetime", "'2024-01-31 12:34:56.007'", 121),
    Case("smalldatetime", "'1900-01-01 00:00'", 120), Case("smalldatetime", "'2079-06-06 23:59'", 120),
    Case("smalldatetime", "'2024-01-31 12:34:29'", 120),
    Case("uniqueidentifier", "'6F9619FF-8B86-D011-B42D-00C04FC964FF'"),
    Case("uniqueidentifier", "'00000000-0000-0000-0000-000000000000'"),
    Case("binary(4)", "0x01", 1), Case("varbinary(10)", "0x", 1),
    Case("varbinary(max)", "0x00FF7F80", 1),
    Case("char(5)", "'ab'"), Case("varchar(20)", "'Grüße'"), Case("nchar(3)", "N'й'"),
    Case("nvarchar(max)", "N'мир 😀'"), Case("varchar(max)", "REPLICATE('x', 9000)"),
];

/// Every value's text equals the server's, and NULLs of every type read as NULL.
void testTextMatchesServer()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    string sql = "SELECT ";
    foreach (i, c; cases)
    {
        const value = format("CAST(%s AS %s)", c.literal, c.type);
        sql ~= format("%s%s, CONVERT(nvarchar(max), %s%s), CAST(NULL AS %s)", i ? ", " : "", value,
                value, c.style >= 0 ? ", " ~ c.style.to!string : "", c.type);
    }
    auto r = conn.query(sql);
    scope (exit)
        r.close();
    enforce(!r.empty, "a row");
    foreach (i, c; cases)
    {
        const mine = r.getString(3 * i);
        const server = r.getString(3 * i + 1);
        enforce(mine == server, format("%s %s: '%s', the server writes '%s'", c.type, c.literal, mine, server));
        enforce(r.isNull(3 * i + 2) && r.getString(3 * i + 2) is null, c.type ~ " NULL");
        enforce(!r.getVariant(3 * i + 2).hasValue, c.type ~ " NULL as a Variant");
    }
}

/// `datetime` keeps 1/300 s; every millisecond is shown rounded as the server rounds it.
void testDatetimeRounding()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("WITH n AS (SELECT TOP 1000 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1 AS ms "
            ~ "FROM sys.all_objects a CROSS JOIN sys.all_objects b), d AS (SELECT DATEADD(ms, ms, "
            ~ "CAST('2024-01-31 23:59:59' AS datetime)) AS v FROM n) "
            ~ "SELECT v, CONVERT(nvarchar(30), v, 121), CAST(v AS smalldatetime), "
            ~ "CONVERT(nvarchar(30), CAST(v AS smalldatetime), 120) FROM d");
    size_t rows;
    while (r.next())
    {
        enforce(r.getString(0) == r.getString(1), r.getString(0) ~ " vs " ~ r.getString(1));
        enforce(r.getString(2) == r.getString(3), r.getString(2) ~ " vs " ~ r.getString(3));
        rows++;
    }
    enforce(rows == 1000, "rows");
}

/// Every scale of `time`, `datetime2` and `datetimeoffset`, and the exact getters.
void testTimeScales()
{
    import core.time : hnsecs, minutes;
    import std.datetime.date : Date, DateTime, TimeOfDay;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    foreach (scale; 0 .. 8)
    {
        auto r = conn.query(format(
                "DECLARE @t time(%1$d) = '23:59:58.1234567', "
                ~ "@d datetime2(%1$d) = '2024-12-31 23:59:58.1234567', "
                ~ "@o datetimeoffset(%1$d) = '2024-12-31 23:59:58.1234567 +05:45'; "
                ~ "SELECT @t, CONVERT(nvarchar(50), @t), @d, CONVERT(nvarchar(50), @d), @o, CONVERT(nvarchar(50), @o)",
                scale));
        scope (exit)
            r.close();
        enforce(!r.empty, "a row");
        foreach (c; [0, 2, 4])
            enforce(r.getString(c) == r.getString(c + 1), r.getString(c) ~ " vs " ~ r.getString(c + 1));
        // the server rounds .1234567 to the scale
        long unit = 1;
        foreach (_; scale .. 7)
            unit *= 10;
        const fraction = (1_234_567 + unit / 2) / unit * unit;
        const ticks = (23 * 3600 + 59 * 60 + 58) * 10_000_000L + fraction;
        enforce(r.getDuration(0) == hnsecs(ticks), "time as a Duration");
        enforce(r.getTime(0) == TimeOfDay(23, 59, 58) && r.getTime(2) == TimeOfDay(23, 59, 58), "getTime");
        enforce(r.getDate(2) == Date(2024, 12, 31) && r.getDate(4) == Date(2024, 12, 31), "getDate");
        enforce(r.getDateTime(4) == DateTime(2024, 12, 31, 23, 59, 58), "local DateTime of a datetimeoffset");
        const st = r.getSysTime(4);
        enforce(st.utcOffset == minutes(345), "offset +05:45");
        enforce(st.toUTC().toISOExtString()[0 .. 19] == "2024-12-31T18:14:58", st.toUTC().toISOExtString());
        enforce(r.getSysTime(2).stdTime % 10_000_000 == fraction, "exact datetime2 fraction");
        enforce(collectException!ClientException(r.getSysTime(0)) !is null, "a time is not a point in time");
    }
}

/// `char`/`varchar` in every supported code page: all bytes and byte pairs decode as the server converts them.
void testCodePages()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    const major = conn.serverVersion.split(".")[0].to!int;
    string[] collations = [
        "SQL_Latin1_General_CP437_BIN", "SQL_Latin1_General_CP850_BIN", "Thai_BIN", "Czech_BIN",
        "Cyrillic_General_BIN", "Latin1_General_BIN", "SQL_Latin1_General_CP1_CI_AS", "Greek_BIN",
        "Turkish_BIN", "Hebrew_BIN", "Arabic_BIN", "Lithuanian_BIN", "Vietnamese_BIN",
        "SQL_Czech_CP1250_CS_AS", "SQL_Latin1_General_CP1251_CS_AS"
    ];
    string bytes = "0x";
    foreach (b; 1 .. 256)
        bytes ~= format("%02X", b);
    foreach (collation; collations)
    {
        conn.exec("CREATE TABLE #cp (v varchar(300) COLLATE " ~ collation ~ ", c char(300) COLLATE "
                ~ collation ~ ")");
        scope (exit)
            conn.exec("DROP TABLE #cp");
        conn.exec("INSERT INTO #cp VALUES (CAST(" ~ bytes ~ " AS varbinary(300)), CAST(" ~ bytes
                ~ " AS varbinary(300)))");
        auto r = conn.query("SELECT v, CONVERT(nvarchar(300), v), c, CONVERT(nvarchar(300), c) FROM #cp");
        scope (exit)
            r.close();
        enforce(!r.empty, "a row");
        enforce(r.getString(0) == r.getString(1), collation ~ ": text differs from the server's");
        enforce(r.getString(2) == r.getString(3), collation ~ ": char(300) differs from the server's");
    }
    // double-byte code pages: every lead byte with every non-zero trail byte, as the server converts them
    string pairs = "0x";
    foreach (lead; 0x81 .. 0xFF)
        foreach (trail; 1 .. 256)
            pairs ~= format("%02X%02X", lead, trail);
    foreach (collation; [
        "Japanese_CI_AS", "Chinese_PRC_CI_AS", "Korean_Wansung_CI_AS",
        "Chinese_Taiwan_Stroke_CI_AS"
    ])
    {
        conn.exec("CREATE TABLE #cjk (v varchar(max) COLLATE " ~ collation ~ ")");
        scope (exit)
            conn.exec("DROP TABLE #cjk");
        conn.exec("INSERT INTO #cjk VALUES (CAST(" ~ pairs ~ " AS varbinary(max)))");
        auto r = conn.query("SELECT v, CONVERT(nvarchar(max), v) FROM #cjk");
        scope (exit)
            r.close();
        enforce(r.next() && r.getString(0) == r.getString(1), collation ~ ": text differs from the server's");
    }
    auto r = conn.query("SELECT CAST(N'日本語' COLLATE Japanese_CI_AS AS varchar(10)), "
            ~ "CAST(N'한국어' COLLATE Korean_Wansung_CI_AS AS varchar(10))");
    enforce(r.next() && r.getString(0) == "日本語" && r.getString(1) == "한국어", "Japanese and Korean text");
    r.close();
    if (major >= 15) // UTF-8 collations: SQL Server 2019 and later
    {
        enforce(scalar(conn, "SELECT CAST(N'Grüße мир 😀' COLLATE Latin1_General_100_CI_AS_SC_UTF8 AS varchar(40))")
                == "Grüße мир 😀", "a UTF-8 collation");
    }
}

/// The typed getters: decimals, money, UUIDs, dates, Variants, and conversions between them.
void testTypedGetters()
{
    import core.time : Duration;
    import std.datetime.date : Date;
    import std.datetime.systime : SysTime;
    import std.uuid : UUID;
    import std.variant : Variant;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT CAST(-12.345 AS decimal(10,3)), CAST(1234.5678 AS money), "
            ~ "CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier), CAST('2024-02-29' AS date), "
            ~ "CAST('2024-02-29 01:02:03.5' AS datetime2(1)), CAST(200 AS tinyint), CAST(0.5 AS real), "
            ~ "CAST('13:14:15' AS time(0)), CAST(0x0102 AS varbinary(2)), CAST(42 AS int)");
    scope (exit)
        r.close();
    enforce(!r.empty, "a row");
    enforce(r.getDecimal(0) == Decimal.fromString("-12.345") && r.getDecimal(0).scale == 3, "decimal");
    enforce(r.getLong(0) == -12 && r.getDouble(0) == -12.345, "decimal as long and double");
    enforce(r.getDecimal(1).toFixedString() == "1234.5678" && r.getDecimal(1).scale == 4, "money");
    enforce(r.getUUID(2) == UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff"), "uniqueidentifier");
    enforce(r.getDate(3) == Date(2024, 2, 29) && r.getDateTime(3).hour == 0, "date");
    enforce(r.getSysTime(4).toISOExtString() == "2024-02-29T01:02:03.5Z", r.getSysTime(4).toISOExtString());
    enforce(r.getDecimal(9) == Decimal.fromLong(42), "int as decimal");

    Variant v = r.getVariant(0);
    enforce(v.type == typeid(Decimal), "decimal Variant");
    enforce(r.getVariant(2).type == typeid(UUID), "UUID Variant");
    enforce(r.getVariant(3).type == typeid(Date), "date Variant");
    enforce(r.getVariant(4).type == typeid(SysTime), "datetime2 Variant");
    enforce(r.getVariant(5).type == typeid(ubyte), "tinyint Variant");
    enforce(r.getVariant(6).type == typeid(float), "real Variant");
    enforce(r.getVariant(7).type == typeid(Duration), "time Variant");
    enforce(r.getVariant(8).type == typeid(ubyte[]), "varbinary Variant");

    enforce(collectException!ClientException(r.getUUID(9)) !is null, "an int is not a UUID");
    enforce(collectException!ClientException(r.getDate(9)) !is null, "an int is not a date");
    enforce(collectException!ClientException(r.getDecimal(2)) !is null, "a UUID is not a decimal");
    enforce(collectException!ClientException(r.getLong(3)) !is null, "a date is not an integer");
    enforce(collectException!ClientException(r.getDateTime(7)) !is null, "a time has no date");
}

/// Float values read back exactly, and their text reads back as the same value.
void testFloats()
{
    import core.stdc.stdlib : strtod, strtof;
    import std.string : toStringz;

    // read back as C does (correctly rounded; Phobos's parser isn't always)
    double readDouble(string s)
    {
        return strtod(s.toStringz, null);
    }

    float readFloat(string s)
    {
        return strtof(s.toStringz, null);
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query(
            "SELECT v, CONVERT(nvarchar(40), v, 3), CAST(v AS real), CONVERT(nvarchar(40), CAST(v AS real), 3) "
            ~ "FROM (VALUES (CAST(0.1 AS float)), (3.4e38), (-1.17549435e-38), (123456789.125), "
            ~ "(1.0/3), (0), (-1.5)) t(v)");
    size_t rows;
    while (r.next())
    {
        enforce(r.getDouble(0) == readDouble(r.getString(1)), r.getString(1));
        enforce(readDouble(r.getString(0)) == r.getDouble(0), r.getString(0));
        enforce(r.getDouble(2) == readFloat(r.getString(3)), r.getString(3));
        enforce(readFloat(r.getString(2)) == cast(float) r.getDouble(2), r.getString(2));
        rows++;
    }
    enforce(rows == 7, "rows");
    // doubles beyond the range of real
    r = conn.query("SELECT v, CONVERT(nvarchar(40), v, 3) FROM (VALUES (CAST(1e300 AS float)), "
            ~ "(-2.2250738585072014e-308), (4.9406564584124654e-324), (1.7976931348623157e308)) t(v)");
    while (r.next())
    {
        enforce(r.getDouble(0) == readDouble(r.getString(1)), r.getString(1));
        enforce(readDouble(r.getString(0)) == r.getDouble(0), r.getString(0));
        rows++;
    }
    enforce(rows == 11, "rows");

    // plain up to 15 digits before the point (6 for real), as the server's own text writes 100
    r = conn.query("SELECT CAST(100 AS float), CAST(100 AS real), CAST(1e15 AS float), CAST(1.5e-5 AS float)");
    enforce(r.next(), "a row");
    enforce(r.getString(0) == "100" && r.getString(1) == "100" && r.getString(2) == "1e+15"
            && r.getString(3) == "1.5e-05", r.getString(0) ~ " " ~ r.getString(1) ~ " " ~ r.getString(2));
    r.close();

    // the text reads back on the server too, also where the shortest digits would be a tie (SQL Server reads
    // -3.668192745606422e+16 as the lower neighbour of -36681927456064224); not subnormals: the server's text
    // parser makes every subnormal 0 (even 4.9406564584124654e-324)
    foreach (v; [
        -36_681_927_456_064_224.0, 1e23, 0.1, double.min_normal, 2.0 ^^ -24, 123_456_789.125
    ])
    {
        auto t = conn.query("SELECT CAST(? AS float)", v);
        enforce(t.next(), "a row");
        const text = t.getString(0);
        t.close();
        enforce(conn.queryValue!double("SELECT CAST(CAST(? AS nvarchar(40)) AS float)", text) == v,
                "the server reads " ~ text ~ " back");
    }
}

/// A table with a column of every type: values and NULL rows (NBCROW) read back.
void testTableRoundTrip()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    string columns, values, nulls;
    foreach (i, c; cases)
    {
        columns ~= format("%sc%d %s NULL", i ? ", " : "", i, c.type);
        values ~= format("%s%s", i ? ", " : "", c.literal);
        nulls ~= i ? ", NULL" : "NULL";
    }
    conn.exec("CREATE TABLE #all (id int, " ~ columns ~ ")");
    scope (exit)
        conn.exec("DROP TABLE #all");
    enforce(conn.exec("INSERT INTO #all VALUES (1, " ~ values ~ "), (2, " ~ nulls ~ ")") == 2, "inserted");
    string select = "SELECT id";
    foreach (i, c; cases)
        select ~= format(", c%1$d, CONVERT(nvarchar(max), c%1$d%2$s)", i, c.style >= 0 ? ", " ~ c.style.to!string : "");
    auto r = conn.query(select ~ " FROM #all ORDER BY id");
    scope (exit)
        r.close();
    enforce(r.next() && r.getInt(0) == 1, "row 1");
    foreach (i, c; cases)
        enforce(r.getString(1 + 2 * i) == r.getString(2 + 2 * i), format("%s: '%s' vs '%s'", c.type,
                r.getString(1 + 2 * i), r.getString(2 + 2 * i)));
    enforce(r.next() && r.getInt(0) == 2, "row 2");
    foreach (i, c; cases)
        enforce(r.isNull(1 + 2 * i), c.type ~ " NULL");
    enforce(!r.next(), "two rows");
}
