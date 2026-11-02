/++
Bulk insert (INSERT BULK with bulk load data).
+/
module integrationtests.bulk;

import core.time : hnsecs, minutes;
import std.conv : to;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.datetime.timezone : SimpleTimeZone, UTC;
import std.exception : collectException, enforce;
import std.format : format;
import std.typecons : Nullable;
import std.uuid : UUID;
import mssql;
import integrationtests.server : connectToServer, scalar;

/// Every column type, NOT NULL and nullable: values arrive as the server would store them from an INSERT.
void testBulkTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #bt (id int IDENTITY PRIMARY KEY, i int NOT NULL, ti tinyint, si smallint NOT NULL, "
            ~ "bi bigint, b bit NOT NULL, r real, f float NOT NULL, d decimal(10,2) NOT NULL, n numeric(38,10), "
            ~ "m money NOT NULL, sm smallmoney, dt datetime NOT NULL, sdt smalldatetime, da date NOT NULL, "
            ~ "t time(3), d2 datetime2(3) NOT NULL, o datetimeoffset(7), g uniqueidentifier NOT NULL, "
            ~ "v varchar(20) COLLATE Cyrillic_General_CI_AS NOT NULL, c char(5), nv nvarchar(20), "
            ~ "nc nchar(3) NOT NULL, "
            ~ "vb varbinary(10), bn binary(4) NOT NULL, vm varchar(max), nm nvarchar(max), bm varbinary(max), x xml)");
    auto bulk = conn.bulkInsert("#bt");
    enforce(bulk.columns.length == 28 && bulk.columns[0] == "i", "the identity column is left out");
    const tz = new immutable SimpleTimeZone(minutes(-330));
    auto big = new ubyte[100_000];
    foreach (k, ref x; big)
        x = cast(ubyte) k;
    bulk.addRow(-2_147_483_648, cast(ubyte) 255, short.min, long.max, true, 1.5f, -0.1, Decimal.fromString(
            "-12345678.905"),
            Decimal.fromString("0.0000000001"), Decimal.fromString("922337203685477.5807"), Decimal.fromString(
            "-1.23456"),
            DateTime(2024, 1, 31, 12, 34, 56), DateTime(2024, 1, 31, 12, 34, 29), Date(9999, 12, 31),
            TimeOfDay(23, 59, 59), SysTime(DateTime(2024, 2, 29, 1, 2, 3), hnsecs(4_567_890), UTC()),
            SysTime(DateTime(2024, 1, 31, 12, 34, 56), hnsecs(1_234_567), tz), UUID(
            "6f9619ff-8b86-d011-b42d-00c04fc964ff"),
            "Привет, мир", "ab", "Grüße 😀", "й", cast(ubyte[])[1, 2], cast(ubyte[])[
        0xFF
    ], "x".replicate(9000),
            "é".replicate(5000), big, "<a>мир</a>");
    // the second row: NULLs where allowed, and conversions (int into decimal, Decimal into int, double into decimal)
    bulk.addRow(Decimal.fromString("7"), null, 1, null, 0, null, 2, 3, null, 4, null, Date(2024, 1, 1), null,
            Date(1, 1, 1), null, DateTime(2024, 1, 1, 0, 0, 0), null, UUID("00000000-0000-0000-0000-000000000001"), "",
            null, null, "abc", null, cast(ubyte[])[], null, null, null, null);
    enforce(bulk.finish() == 2, "two rows");

    // the same values through INSERT, for the server's text of each
    conn.exec("SELECT * INTO #expected FROM #bt WHERE 1 = 0; SET IDENTITY_INSERT #expected ON");
    conn.exec("INSERT INTO #expected (id, i, ti, si, bi, b, r, f, d, n, m, sm, dt, sdt, da, t, d2, o, g, v, c, nv, "
            ~ "nc, vb, bn, vm, nm, bm, x) VALUES (1, -2147483648, 255, -32768, 9223372036854775807, 1, 1.5, -0.1, "
            ~ "-12345678.905, "
            ~ "0.0000000001, 922337203685477.5807, -1.23456, '2024-01-31 12:34:56', '2024-01-31 12:34:29', "
            ~ "'9999-12-31', '23:59:59', '2024-02-29 01:02:03.4567890', '2024-01-31 12:34:56.1234567 -05:30', "
            ~ "'6F9619FF-8B86-D011-B42D-00C04FC964FF', N'Привет, мир', 'ab', N'Grüße 😀', N'й', 0x0102, 0xFF, "
            ~ "REPLICATE(CAST('x' AS varchar(max)), 9000), REPLICATE(CAST(N'é' AS nvarchar(max)), 5000), NULL, "
            ~ "N'<a>мир</a>'), "
            ~ "(2, 7, NULL, 1, NULL, 0, NULL, 2, 3, NULL, 4, NULL, '2024-01-01', NULL, '0001-01-01', NULL, "
            ~ "'2024-01-01', NULL, '00000000-0000-0000-0000-000000000001', '', NULL, NULL, N'abc', NULL, 0x, NULL, "
            ~ "NULL, "
            ~ "NULL, NULL)");
    auto a = conn.query("SELECT * FROM #bt ORDER BY id");
    string[][] got;
    while (a.next())
    {
        string[] row;
        foreach (c; 0 .. a.columns.length)
            row ~= a.columns[c].name == "bm" ? (a.isNull(c) ? "NULL" : a.getBytes(c) == big ? "big" : "?") : a.isNull(
                    c) ? "NULL" : a.getString(c);
        got ~= row;
    }
    auto e = conn.query("SELECT * FROM #expected ORDER BY id");
    size_t r;
    while (e.next())
    {
        foreach (c; 0 .. e.columns.length)
        {
            const want = e.columns[c].name == "bm" ? (r == 0 ? "big" : "NULL") : e.isNull(c) ? "NULL" : e.getString(c);
            enforce(got[r][c] == want, format("row %s, column %s: '%s', INSERT gives '%s'", r + 1, e.columns[c].name,
                    got[r][c].length > 60 ? got[r][c][0 .. 60] : got[r][c], want.length > 60 ? want[0 .. 60] : want));
        }
        r++;
    }
    enforce(r == 2, "rows");
}

/// Client-side errors skip the row and keep the inserter usable; server errors end the batch.
void testBulkErrors()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #be (id int PRIMARY KEY, name varchar(5) COLLATE Latin1_General_CI_AS NOT NULL, "
            ~ "small tinyint, CHECK (id < 1000))");
    auto bulk = conn.bulkInsert("#be");
    bulk.addRow(1, "one", 1);
    void refused(string what, void delegate() add)
    {
        auto e = collectException!ClientException(add());
        enforce(e !is null, what ~ " accepted");
    }

    refused("a NULL in a NOT NULL column", { bulk.addRow(2, null, 1); });
    refused("a too long string", { bulk.addRow(2, "toolong", 1); });
    refused("a character outside the code page", { bulk.addRow(2, "мир", 1); });
    refused("an out-of-range tinyint", { bulk.addRow(2, "two", 256); });
    refused("a wrong value count", { bulk.addRow(2, "two"); });
    refused("a type that doesn't fit", { bulk.addRow("two", "two", 2); });
    bulk.addRow(2, "two", null);
    enforce(bulk.finish() == 2 && conn.queryValue!long("SELECT COUNT(*) FROM #be") == 2, "the valid rows");

    // the server checks when the batch ends: a duplicate key fails the whole batch
    bulk = conn.bulkInsert("#be");
    bulk.addRow(3, "three", 3);
    bulk.addRow(1, "dup", 1);
    enforce(collectException!ServerException(bulk.finish()) !is null, "duplicate key");
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #be") == 2, "nothing of the failed batch");

    // CHECK constraints only with checkConstraints
    BulkOptions check;
    check.checkConstraints = true;
    bulk = conn.bulkInsert("#be", null, check);
    bulk.addRow(5000, "big", 1);
    enforce(collectException!ServerException(bulk.finish()) !is null, "the CHECK constraint");
    bulk = conn.bulkInsert("#be");
    bulk.addRow(5000, "big", 1);
    enforce(bulk.finish() == 1, "CHECK constraints are not checked by default");
    enforce(scalar(conn, "SELECT 1") == "1", "usable");

    // the connection is busy while rows are being sent
    bulk = conn.bulkInsert("#be");
    bulk.addRow(10, "ten", 1);
    enforce(conn.isBusy && collectException!ClientException(conn.exec("SELECT 1")) !is null, "busy");
    bulk.abort();
    enforce(!conn.isBusy && conn.queryValue!long("SELECT COUNT(*) FROM #be WHERE id = 10") == 0, "aborted");
    enforce(collectException!ClientException(bulk.addRow(11, "x", 1)) !is null, "finished");
}

/// Batches commit on their own; a user transaction covers them all; abort drops only the current batch.
void testBulkBatches()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #bb (id int PRIMARY KEY, v nvarchar(20))");
    BulkOptions options;
    options.batchSize = 1000;
    options.tableLock = true;
    auto bulk = conn.bulkInsert("#bb", ["id", "v"], options);
    foreach (i; 0 .. 5500)
        bulk.addRow(i, "row " ~ i.to!string);
    enforce(bulk.rowCount == 5500 && bulk.finish() == 5500, "5500 rows in batches");
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #bb") == 5500, "all there");

    // an error in the third batch: the first two stay
    conn.exec("TRUNCATE TABLE #bb");
    bulk = conn.bulkInsert("#bb", ["id", "v"], options);
    foreach (i; 0 .. 2500)
        bulk.addRow(i == 2400 ? 0 : i, "x");
    enforce(collectException!ServerException(bulk.finish()) !is null, "a duplicate in the last batch");
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #bb") == 2000, "the first two batches");

    // abort: the batches before stay
    conn.exec("TRUNCATE TABLE #bb");
    bulk = conn.bulkInsert("#bb", ["id", "v"], options);
    foreach (i; 0 .. 1500)
        bulk.addRow(i, "x");
    bulk.abort();
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #bb") == 1000, "abort drops only the open batch");

    // inside a transaction, the caller decides
    conn.begin();
    bulk = conn.bulkInsert("#bb", ["id", "v"], options);
    foreach (i; 5000 .. 7500)
        bulk.addRow(i, "tx");
    bulk.finish();
    conn.rollback();
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #bb") == 1000, "rolled back");
}

private struct Reading
{
    @column("sensor_id") int sensor;
    DateTime at;
    Decimal value;
    Nullable!string note;
}

/// Structs, defaults, KEEP_NULLS, triggers, a three-part table name.
void testBulkStructs()
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.range : iota;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #readings (id int IDENTITY, sensor_id int NOT NULL, at datetime2(0), value decimal(9,3), "
            ~ "note varchar(20) DEFAULT 'none')");
    auto readings = iota(0, 3000).map!(i => Reading(i % 7, DateTime(2024, 1, 1) + minutes(i), Decimal.fromLong(i),
            i % 2 ? Nullable!string("odd") : Nullable!string())).array;
    enforce(conn.bulkInsert("#readings", readings) == 3000, "structs");
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #readings WHERE note IS NULL") == 0, "defaults for NULLs");
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #readings WHERE note = 'none'") == 1500, "the default");
    BulkOptions keepNulls;
    keepNulls.keepNulls = true;
    auto bulk = conn.bulkInsert!Reading("#readings", keepNulls);
    bulk.add(Reading(1, DateTime(2024, 6, 1), Decimal.fromString("1.5")));
    bulk.finish();
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #readings WHERE note IS NULL") == 1, "KEEP_NULLS");
    const r = conn.queryRow!Reading("SELECT * FROM #readings WHERE sensor_id = ? AND value = ?", 3, 10);
    enforce(r.at == DateTime(2024, 1, 1, 0, 10, 0) && r.note.get == "none", "read back");

    // triggers run only with fireTriggers; a permanent table in tempdb, by a three-part name
    conn.exec("USE tempdb; IF OBJECT_ID('dbo.bulk_trigger_test') IS NOT NULL DROP TABLE dbo.bulk_trigger_test; "
            ~ "CREATE TABLE dbo.bulk_trigger_test (v varchar(10) COLLATE Japanese_CI_AS); USE master");
    scope (exit)
        conn.exec("DROP TABLE tempdb.dbo.bulk_trigger_test");
    conn.exec("CREATE TABLE #fired (n int)");
    conn.exec("USE tempdb; EXEC('CREATE TRIGGER dbo.bulk_trigger ON dbo.bulk_trigger_test AFTER INSERT AS "
            ~ "INSERT INTO #fired SELECT COUNT(*) FROM inserted'); USE master");
    bulk = conn.bulkInsert("tempdb.dbo.bulk_trigger_test");
    bulk.addRow("日本語");
    bulk.finish();
    BulkOptions fire;
    fire.fireTriggers = true;
    bulk = conn.bulkInsert("[tempdb].[dbo].[bulk_trigger_test]", null, fire);
    bulk.addRow("テスト");
    bulk.finish();
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #fired") == 1, "the trigger ran once");
    enforce(conn.queryValue!string("SELECT v FROM tempdb.dbo.bulk_trigger_test WHERE v LIKE N'日%'") == "日本語",
            "code page 932 through a three-part name");
}

private string replicate(string s, size_t n)
{
    string r;
    foreach (_; 0 .. n)
        r ~= s;
    return r;
}
