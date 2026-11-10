/++
The high-level API: connection strings, the connection pool, struct mapping.
+/
module integrationtests.highlevel;

import core.time : msecs, seconds;
import std.conv : to;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.exception : collectException, enforce;
import std.process : environment;
import std.string : indexOf;
import std.typecons : Nullable;
import std.uuid : UUID;
import mssql;
import integrationtests.server : connectToServer, scalar, serverDsn;

/// The test server as an ADO-style connection string.
string serverAdoString(string extra = null)
{
    const host = environment.get("MSSQL_HOST", "");
    const colon = host.indexOf(':');
    const server = colon < 0 ? host : host[0 .. colon] ~ "," ~ host[colon + 1 .. $];
    string s = "Server=tcp:" ~ server ~ "; Database=master; User Id=" ~ environment.get("MSSQL_USER", "sa")
        ~ "; Password={" ~ environment.get("MSSQL_PASSWORD", "") ~ "}";
    if (environment.get("MSSQL_VERIFY", "") != "1")
        s ~= "; TrustServerCertificate=True";
    return s ~ (extra.length ? "; " ~ extra : "");
}

/// Both forms of connection string open a connection.
void testConnectionStrings()
{
    auto ado = new Connection(serverAdoString("Application Name=ado test; Packet Size=8000"));
    scope (exit)
        ado.close();
    enforce(scalar(ado, "SELECT APP_NAME()") == "ado test" && ado.packetSize == 8000, "ADO string");
    auto url = new Connection(serverDsn("app_name=url%20test"));
    scope (exit)
        url.close();
    enforce(scalar(url, "SELECT APP_NAME()") == "url test", "URL string");
    auto e = collectException!ClientException(new Connection(serverAdoString("Colour=blue")));
    enforce(e !is null && e.msg == "Unknown connection string key 'Colour'", e is null ? "accepted" : e.msg);
}

/// The pool reuses connections, resets their sessions, waits for a free one, and drops broken ones.
void testPool()
{
    auto pool = new ConnectionPool(serverAdoString("Max Pool Size=2"));
    scope (exit)
        pool.close();
    {
        auto c = pool.lockConnection();
        c.exec("CREATE TABLE #pooled (v int); SET NOCOUNT ON; USE tempdb");
        enforce(pool.activeConnections == 1, "one active");
    }
    enforce(pool.idleConnections == 1 && pool.activeConnections == 0, "returned");
    {
        auto c = pool.lockConnection();
        enforce(collectException!ServerException(c.exec("SELECT * FROM #pooled")) !is null, "temp table reset");
        enforce(c.database == "master" && scalar(c, "SELECT DB_NAME()") == "master", "database reset");
        enforce(c.exec("CREATE TABLE #n (v int); INSERT INTO #n VALUES (1)") == 1, "NOCOUNT reset");
    }

    // a returned connection is rolled back at once (its locks are not held while it is idle) and loses its
    // message callback
    auto other = connectToServer();
    scope (exit)
        other.close();
    other.exec("IF OBJECT_ID('tempdb..##itest_pool') IS NOT NULL DROP TABLE ##itest_pool;"
            ~ " CREATE TABLE ##itest_pool (v int)");
    scope (exit)
        other.exec("DROP TABLE ##itest_pool");
    {
        auto c = pool.lockConnection();
        c.exec("BEGIN TRANSACTION; INSERT INTO ##itest_pool VALUES (1)");
        enforce(c.inTransaction, "in a transaction");
        void listener(ServerMessage) @safe
        {
        }

        c.onMessage = &listener;
    }
    other.exec("SET LOCK_TIMEOUT 2000");
    enforce(scalar(other, "SELECT COUNT(*) FROM ##itest_pool") == "0", "rolled back on release (no lock left)");
    {
        auto c = pool.lockConnection();
        enforce(c.onMessage is null && !c.inTransaction, "the callback cleared");
    }

    // a connection returned busy (an unread result) is closed, not reused
    {
        auto c = pool.lockConnection();
        c.query("SELECT 1 UNION ALL SELECT 2"); // not read
    }
    enforce(pool.idleConnections == 0, "the busy connection was dropped");

    // two in use: a third waits, then fails
    auto pool2 = new ConnectionPool(serverOptions(), PoolOptions(2, 300.msecs));
    scope (exit)
        pool2.close();
    auto a = pool2.lockConnection();
    auto b = pool2.lockConnection();
    auto e = collectException!ClientException(pool2.lockConnection());
    enforce(e !is null, "the third waits and fails");
    b.release();
    auto c = pool2.lockConnection();
    enforce(scalar(c, "SELECT 1") == "1", "a freed connection");
    a.release();
    c.release();
    pool2.close();
    enforce(collectException!ClientException(pool2.lockConnection()) !is null, "a closed pool");
}

private ConnectionOptions serverOptions()
{
    import integrationtests.server : serverOptions;

    return serverOptions();
}

private enum Color
{
    red = 1,
    green = 2,
}

private struct Everything
{
    int id;
    bool flag;
    ubyte tiny;
    short small;
    long big;
    float single;
    double precise;
    string text;
    @column("bytes") ubyte[] data;
    Decimal amount;
    Date day;
    TimeOfDay time;
    DateTime moment;
    SysTime instant;
    UUID guid;
    Color color;
    @column("color_name") Color namedColor;
    Nullable!int maybe;
    @ignore string notStored;
}

/// Structs inserted and read back with every field type; names, NULLs, errors.
void testStructMapping()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #e (id int, flag bit, tiny tinyint, small smallint, big bigint, single real, "
            ~ "precise float, text nvarchar(100), bytes varbinary(100), amount decimal(18,4), day date, "
            ~ "time time, moment datetime2, instant datetimeoffset, guid uniqueidentifier, color int, "
            ~ "color_name varchar(10), maybe int)");
    const tz = UTC();
    Everything[] rows = [
        Everything(1, true, 255, -32_768, long.max, 1.5f, -0.1, "Grüße", [1, 2], Decimal.fromString("-12.3456"),
                Date(2024, 2, 29), TimeOfDay(23, 59, 59), DateTime(2024, 1, 31, 12, 0, 0),
                SysTime(DateTime(2024, 1, 31, 12, 0, 0), tz), UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff"),
                Color.green, Color.red, Nullable!int(5), "not stored"),
        Everything(2),
    ];
    rows[1].single = 0; // float fields start as NaN, which SQL Server can't store
    rows[1].precise = 0;
    enforce(collectException!ClientException(conn.insert("#e", Everything(3))) !is null, "NaN refused");
    // color_name holds the enum's name: insert it as text
    conn.exec("ALTER TABLE #e ALTER COLUMN color_name varchar(10)");
    enforce(conn.insert("#e", rows) == 2, "inserted");
    conn.exec("UPDATE #e SET color_name = 'red' WHERE id = 1");
    auto read = conn.query!Everything("SELECT * FROM #e WHERE id = ?", 1);
    enforce(!read.empty, "a row");
    const r = read.front;
    read.close();
    enforce(r.flag && r.tiny == 255 && r.small == -32_768 && r.big == long.max, "integers");
    enforce(r.single == 1.5f && r.precise == -0.1 && r.text == "Grüße" && r.data == [1, 2], "floats, text, bytes");
    enforce(r.amount == Decimal.fromString("-12.3456") && r.day == Date(2024, 2, 29), "decimal, date: " ~ r
            .amount.toString() ~ " " ~ r.day.toISOExtString());
    enforce(r.time == TimeOfDay(23, 59, 59) && r.moment == DateTime(2024, 1, 31, 12, 0, 0), "time, datetime2");
    enforce(r.instant == SysTime(DateTime(2024, 1, 31, 12, 0, 0), tz) && r.guid == rows[0].guid, "offset, guid");
    enforce(r.color == Color.green && r.namedColor == Color.red && r.maybe.get == 5, "enums, Nullable");
    enforce(r.notStored == "", "ignored field");
    const empty = conn.queryRow!Everything("SELECT * FROM #e WHERE id = 2");
    enforce(empty.maybe.isNull && empty.text == "" && empty.data == null, "NULLs");

    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #e") == 2, "queryValue");
    enforce(conn.queryValue!(Nullable!int)("SELECT maybe FROM #e WHERE id = ?", 2).isNull, "NULL value");
    enforce(collectException!ClientException(
            conn.queryRow!Everything("SELECT * FROM #e WHERE id = 3")) !is null,
            "no row");
    auto e = collectException!ClientException(conn.query!Everything("SELECT id FROM #e"));
    enforce(e !is null && e.msg.indexOf("'flag'") >= 0, "a missing column");
    enforce(!conn.isBusy, "released after a missing column");
    enforce(collectException!ClientException(conn.queryValue!ubyte("SELECT 300")) !is null, "doesn't fit");
}

private struct Item
{
    int id;
    string name;
}

/// Many rows go in several statements, all in one transaction: a bad row leaves nothing inserted.
void testInsertMany()
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.range : iota;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #items (id int PRIMARY KEY, name nvarchar(20))");
    auto items = iota(0, 2500).map!(i => Item(i, "item " ~ i.to!string)).array;
    enforce(conn.insert("#items", items) == 2500 && !conn.inTransaction, "2500 rows");
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #items") == 2500, "all there");

    items = iota(2500, 4000).map!(i => Item(i, "x")).array;
    items[1200].id = 0; // a duplicate key in the second statement
    enforce(collectException!ServerException(conn.insert("#items", items)) !is null, "a duplicate");
    enforce(!conn.inTransaction && conn.queryValue!long("SELECT COUNT(*) FROM #items") == 2500, "all or nothing");

    // inside the caller's transaction, the caller decides
    conn.begin();
    conn.insert("#items", Item(5000, "in a transaction"));
    conn.rollback();
    enforce(conn.queryValue!long("SELECT COUNT(*) FROM #items") == 2500, "rolled back by the caller");
}
