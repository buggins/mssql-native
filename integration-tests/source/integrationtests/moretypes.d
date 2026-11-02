/++
The types of M6: sql_variant, rowversion, (max) types and xml, the legacy
text/ntext/image types, and CLR types (UDTs) as bytes.
+/
module integrationtests.moretypes;

import std.conv : to;
import std.exception : collectException, enforce;
import std.format : format;
import std.string : indexOf;
import mssql;
import integrationtests.server : connectToServer, scalar;

/// sql_variant values of every base type: text as the server writes it, the base type, NULL.
void testSqlVariant()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #v (id int IDENTITY, v sql_variant)");
    // one statement per value: a multi-row VALUES would convert them to one common type
    string insert;
    foreach (literal; [
        "CAST(42 AS int)", "CAST(200 AS tinyint)", "CAST(-7 AS smallint)",
        "CAST(9223372036854775807 AS bigint)", "CAST(1 AS bit)", "CAST(-1.50 AS decimal(5,2))",
        "CAST(1234.5678 AS money)", "CAST(-12.5 AS smallmoney)", "CAST(0.5 AS float)",
        "CAST(0.25 AS real)",
        "CAST('2024-01-31' AS date)", "CAST('12:34:56.12' AS time(2))",
        "CAST('2024-01-31 12:34:56.1234567' AS datetime2)",
        "CAST('2024-01-31 12:34:56.997' AS datetime)",
        "CAST('2024-01-31 12:34' AS smalldatetime)",
        "CAST('2024-01-31 12:34:56.5 -05:30' AS datetimeoffset(1))",
        "CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier)", "N'Grüße мир'",
        "CAST('café' AS varchar(10))", "CAST('ab' AS char(4))", "CAST(0x01AB AS varbinary(10))",
        "CAST(0x01 AS binary(3))", "NULL"
    ])
        insert ~= "INSERT INTO #v (v) VALUES (" ~ literal ~ "); ";
    conn.exec(insert);
    // the server's text of the value cast to its base type (CONVERT of a sql_variant writes dates in
    // style 0), with the lossless styles of getString
    auto r = conn.query("SELECT v, CAST(SQL_VARIANT_PROPERTY(v, 'BaseType') AS nvarchar(30)), "
            ~ "CASE CAST(SQL_VARIANT_PROPERTY(v, 'BaseType') AS nvarchar(30)) "
            ~ "WHEN 'money' THEN CONVERT(nvarchar(100), CAST(v AS money), 2) "
            ~ "WHEN 'smallmoney' THEN CONVERT(nvarchar(100), CAST(v AS smallmoney), 2) "
            ~ "WHEN 'datetime' THEN CONVERT(nvarchar(100), CAST(v AS datetime), 121) "
            ~ "WHEN 'smalldatetime' THEN CONVERT(nvarchar(100), CAST(v AS smalldatetime), 120) "
            ~ "WHEN 'varbinary' THEN CONVERT(nvarchar(100), CAST(v AS varbinary(100)), 1) "
            ~ "WHEN 'binary' THEN CONVERT(nvarchar(100), CAST(v AS varbinary(100)), 1) "
            ~ "WHEN 'date' THEN CONVERT(nvarchar(100), CAST(v AS date)) "
            ~ "WHEN 'time' THEN CONVERT(nvarchar(100), CAST(v AS time(2))) "
            ~ "WHEN 'datetime2' THEN CONVERT(nvarchar(100), CAST(v AS datetime2(7))) "
            ~ "WHEN 'datetimeoffset' THEN CONVERT(nvarchar(100), CAST(v AS datetimeoffset(1))) "
            ~ "WHEN 'float' THEN NULL WHEN 'real' THEN NULL "
            ~ "ELSE CONVERT(nvarchar(100), v) END FROM #v ORDER BY id");
    size_t rows;
    while (r.next())
    {
        rows++;
        if (r.isNull(0))
        {
            enforce(r.getString(0) is null && r.isNull(1), "NULL");
            continue;
        }
        const baseType = r.getString(1);
        enforce(r[0].base.type.name == baseType, "base type " ~ r[0].base.type.name ~ " vs " ~ baseType);
        if (!r.isNull(2))
            enforce(r.getString(0) == r.getString(2), format("%s: '%s' vs '%s'", baseType, r.getString(0),
                    r.getString(2)));
    }
    enforce(rows == 23, "rows");
    r = conn.query("SELECT CAST(CAST(0.5 AS float) AS sql_variant), CAST(CAST(-1.5 AS decimal(5,2)) AS sql_variant), "
            ~ "CAST(CAST(7 AS int) AS sql_variant)");
    enforce(r.next() && r.getDouble(0) == 0.5 && r.getDecimal(1) == Decimal.fromString("-1.5") && r.getInt(2) == 7,
            "typed getters");
    enforce(r.getVariant(2).type == typeid(int) && r.getVariant(1).type == typeid(Decimal), "Variants");
    r.close();
}

/// rowversion: binary(8) named timestamp, its counter with getLong.
void testRowversion()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #rv (id int, rv rowversion)");
    conn.exec("INSERT INTO #rv (id) VALUES (1), (2)");
    auto r = conn.query(
            "SELECT rv, CAST(rv AS bigint), CONVERT(nvarchar(20), CAST(rv AS varbinary(8)), 1) FROM #rv ORDER BY id");
    while (r.next())
    {
        enforce(r.columns[0].type.name == "timestamp", "type name " ~ r.columns[0].type.name);
        enforce(r.getLong(0) == r.getLong(1) && r.getString(0) == r.getString(2), "counter and text");
        enforce(r.getBytes(0).length == 8, "eight bytes");
    }
}

/// Long values of the (max) types and xml, read and sent.
void testLargeValues()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto bytes = new ubyte[10 * 1024 * 1024];
    foreach (i, ref b; bytes)
        b = cast(ubyte)(i * 31 + (i >> 9));
    string text;
    foreach (i; 0 .. 300_000)
        text ~= "Grüße мир ";
    conn.exec(
            "CREATE TABLE #big (b varbinary(max), n nvarchar(max), "
            ~ "v varchar(max) COLLATE Latin1_General_CI_AS, x xml)");
    conn.exec("INSERT INTO #big VALUES (?, ?, ?, ?)", bytes, text, "café " ~ "x".replicate(9000),
            "<root a=\"1\"><item>мир</item></root>");
    auto r = conn.query("SELECT b, n, v, x, CONVERT(nvarchar(max), x), DATALENGTH(b), DATALENGTH(n) FROM #big");
    enforce(r.next(), "a row");
    enforce(r.getLong(5) == bytes.length && r.getBytes(0) == bytes, "10 MB varbinary(max)");
    enforce(r.getLong(6) == 6_000_000 && r.getString(1) == text, "nvarchar(max)");
    enforce(r.getString(2) == "café " ~ "x".replicate(9000), "varchar(max) in code page 1252");
    enforce(r.getString(3) == r.getString(4) && r.getString(3).indexOf("<item>мир</item>") > 0, "xml");
    enforce(r.columns[3].type.name == "xml", "xml type");
    r.close();
}

/// The legacy text, ntext and image types, also in another code page.
void testLegacyTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #legacy (t text COLLATE Cyrillic_General_CI_AS, n ntext, i image)");
    conn.exec("INSERT INTO #legacy VALUES (?, ?, ?)", "мир " ~ "x".replicate(10_000), "Grüße 😀", cast(ubyte[])[
        1, 2, 3
    ]);
    conn.exec("INSERT INTO #legacy VALUES (NULL, NULL, NULL)");
    auto r = conn.query("SELECT t, n, i, CONVERT(nvarchar(max), t), CONVERT(nvarchar(max), n) FROM #legacy "
            ~ "ORDER BY CASE WHEN t IS NULL THEN 1 ELSE 0 END");
    enforce(r.next(), "a row");
    enforce(r.columns[0].type.name == "text" && r.columns[1].type.name == "ntext" && r.columns[2].type.name == "image",
            "type names");
    enforce(r.getString(0) == r.getString(3) && r.getString(0)[0 .. 6] == "мир", "text in code page 1251");
    enforce(r.getString(1) == r.getString(4) && r.getString(1) == "Grüße 😀", "ntext");
    enforce(r.getBytes(2) == [1, 2, 3] && r.getString(2) == "0x010203", "image");
    enforce(r.next() && r.isNull(0) && r.isNull(1) && r.isNull(2), "NULLs");
    enforce(!r.next(), "two rows");
}

/// CLR types (hierarchyid, geometry, geography) are read as bytes; text needs a conversion in the query.
void testClrTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT hierarchyid::Parse('/1/2/') AS h, geometry::STGeomFromText('POINT (1 2)', 0) AS g, "
            ~ "geography::Point(47.65, -122.34, 4326) AS gg, CAST(hierarchyid::Parse('/1/2/') AS varbinary(100)), "
            ~ "CAST(geometry::STGeomFromText('POINT (1 2)', 0) AS varbinary(max)), 7 AS after");
    scope (exit)
        r.close();
    enforce(r.next() && r.getLong(5) == 7, "the value after them");
    enforce(r.columns[0].type.name == "hierarchyid" && r.columns[1].type.name == "geometry"
            && r.columns[2].type.name == "geography", "type names");
    enforce(r.getBytes(0) == r.getBytes(3) && r.getBytes(1) == r.getBytes(4), "bytes as the server serializes them");
    enforce(r.getBytes(2).length > 0, "geography bytes");
    auto e = collectException!ClientException(r.getString(0));
    enforce(e !is null && e.msg.indexOf("getBytes") >= 0, e is null ? "no error" : e.msg);
}

private string replicate(string s, size_t n)
{
    string r;
    foreach (_; 0 .. n)
        r ~= s;
    return r;
}
