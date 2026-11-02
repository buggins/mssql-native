/++
Parameters against the server: every D type sent and read back, NULLs, output
parameters, stored procedures, prepared statements.
+/
module integrationtests.params;

import core.time : Duration, hnsecs, minutes;
import std.conv : to;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.datetime.timezone : SimpleTimeZone, UTC;
import std.exception : collectException, enforce;
import std.format : format;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;
import mssql;
import integrationtests.server : connectToServer, scalar;

/// Every D type goes out and comes back with the same value.
void testParameterValues()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    const plus545 = new immutable SimpleTimeZone(minutes(345));
    const minus14 = new immutable SimpleTimeZone(minutes(-14 * 60));
    const longText = "é".replicate(5000); // nvarchar(max)
    auto longBytes = new ubyte[9000];
    foreach (i, ref b; longBytes)
        b = cast(ubyte) i;
    auto r = conn.query("SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?",
            true, cast(ubyte) 255, cast(byte)-128, short.min, ushort.max, int.min, uint.max, long.max, ulong.max,
            float.max, -double.min_normal, "Grüße мир 😀", "", longText, cast(ubyte[])[
        0, 0xFF
    ], cast(ubyte[])[],
            longBytes, Decimal.fromString("-99999999999999999999999999999999999999"),
            Decimal.fromString("0.00000000000000000000000000000000000001"), Date(1, 1, 1), Date(9999, 12, 31),
            TimeOfDay(23, 59, 59), hnsecs(863_999_999_999L), DateTime(2024, 2, 29, 1, 2, 3),
            SysTime(DateTime(2024, 12, 31, 23, 59, 58), hnsecs(1_234_567), plus545),
            SysTime(DateTime(1, 1, 1, 14, 0, 0), minus14), UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff"), 'й');
    scope (exit)
        r.close();
    enforce(!r.empty, "a row");
    size_t c;
    enforce(r.getBool(c++) && r.getLong(c++) == 255 && r.getLong(c++) == -128, "small integers");
    enforce(r.getLong(c++) == short.min && r.getLong(c++) == ushort.max && r.getLong(c++) == int.min, "integers");
    enforce(r.getLong(c++) == uint.max && r.getLong(c++) == long.max, "bigint");
    enforce(r.getDecimal(c++) == Decimal.fromString("18446744073709551615"), "ulong.max as decimal");
    enforce(r.getDouble(c) == float.max && r.getVariant(c++).type == typeid(float), "real");
    enforce(r.getDouble(c++) == -double.min_normal, "float");
    enforce(r.getString(c++) == "Grüße мир 😀" && r.getString(c++) == "", "nvarchar");
    enforce(r.getString(c++) == longText, "nvarchar(max)");
    enforce(r.getBytes(c++) == [0, 0xFF] && r.getBytes(c++) == [], "varbinary");
    enforce(r.getBytes(c++) == longBytes, "varbinary(max)");
    enforce(r.getString(c++) == "-99999999999999999999999999999999999999", "decimal(38,0)");
    enforce(r.getString(c++) == "0.00000000000000000000000000000000000001", "decimal(38,38)");
    enforce(r.getDate(c++) == Date(1, 1, 1) && r.getDate(c++) == Date(9999, 12, 31), "date");
    enforce(r.getString(c++) == "23:59:59.0000000" && r.getString(c++) == "23:59:59.9999999", "time");
    enforce(r.getDateTime(c++) == DateTime(2024, 2, 29, 1, 2, 3), "datetime2");
    enforce(r.getString(c++) == "2024-12-31 23:59:58.1234567 +05:45", "datetimeoffset");
    enforce(r.getString(c++) == "0001-01-01 14:00:00.0000000 -14:00", "datetimeoffset at the lower limit");
    enforce(r.getString(c++) == "6F9619FF-8B86-D011-B42D-00C04FC964FF", "uniqueidentifier");
    enforce(r.getString(c++) == "й", "char");
    enforce(r.columns[c - 1].type.name == "nvarchar", "char as nvarchar");
}

/// Values into typed table columns and back, through every conversion the server makes.
void testParametersIntoColumns()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #p (i int, s varchar(20), n nvarchar(20), d decimal(10,2), m money, "
            ~ "dt datetime, sd smalldatetime, d2 datetime2(3), b varbinary(10), g uniqueidentifier, f real)");
    scope (exit)
        conn.exec("DROP TABLE #p");
    const inserted = conn.exec("INSERT INTO #p VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", 7, "café", "мир",
            Decimal.fromString("1234.5"), Decimal.fromString("-0.0001"), DateTime(2024, 1, 31, 12, 34, 56),
            DateTime(2024, 1, 31, 12, 34, 0), SysTime(DateTime(2024, 1, 31, 12, 0, 0), hnsecs(5_000_000), UTC()),
            cast(ubyte[])[1, 2, 3], UUID("00000000-0000-0000-0000-000000000001"), 0.25);
    enforce(inserted == 1, "inserted");
    auto r = conn.query("SELECT * FROM #p WHERE i = ? AND s = ? AND n = ?", 7, "café", "мир");
    scope (exit)
        r.close();
    enforce(!r.empty, "the row found by its parameters");
    enforce(r.getString(1) == "café" && r.getString(2) == "мир", "strings");
    enforce(r.getString(3) == "1234.50" && r.getString(4) == "-0.0001", "decimal and money");
    enforce(r.getString(5) == "2024-01-31 12:34:56.000" && r.getString(6) == "2024-01-31 12:34:00", "datetime");
    enforce(r.getString(7) == "2024-01-31 12:00:00.500", "datetimeoffset into datetime2 keeps the local time");
    enforce(r.getBytes(8) == [1, 2, 3] && r.getString(9) == "00000000-0000-0000-0000-000000000001", "binary, guid");
    enforce(r.getDouble(10) == 0.25, "real");
}

/// NULLs: typed (`Nullable!T`, `Parameter.nullOf!T`), untyped (`null`, an empty `Variant`).
void testNullParameters()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec(
            "CREATE TABLE #n (i int, s nvarchar(10), d decimal(10,2), b varbinary(10), t datetime2, "
            ~ "g uniqueidentifier)");
    scope (exit)
        conn.exec("DROP TABLE #n");
    conn.exec("INSERT INTO #n VALUES (?, ?, ?, ?, ?, ?)", Nullable!int(), null, Nullable!Decimal(),
            Nullable!(ubyte[])(), Parameter.nullOf!DateTime, Variant());
    conn.exec("INSERT INTO #n VALUES (?, ?, ?, ?, ?, ?)", Nullable!int(5), Nullable!string("x"),
            Nullable!Decimal(Decimal.fromString("1.5")), Nullable!(ubyte[])([1]), null, null);
    auto r = conn.query("SELECT * FROM #n ORDER BY i");
    scope (exit)
        r.close();
    enforce(r.next(), "row 1");
    foreach (c; 0 .. 6)
        enforce(r.isNull(c), "NULL in column " ~ c.to!string);
    enforce(r.next() && r.getInt(0) == 5 && r.getString(1) == "x" && r.getString(2) == "1.50"
            && r.getBytes(3) == [1] && r.isNull(4), "row 2");
    r.close();
    // an untyped NULL can't go into varbinary: the server refuses the implicit conversion
    enforce(collectException!ServerException(conn.exec("INSERT INTO #n (b) VALUES (?)", null)) !is null,
            "nvarchar NULL into varbinary");
    enforce(scalar(conn, "SELECT 1") == "1", "the connection stays usable");
}

/// Placeholders: counted outside literals and comments; a wrong count fails before anything is sent.
void testPlaceholders()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT '?' AS a, ? AS b /* ? */, N'it''s ?' AS c -- ?\n, [?] = ?", 1, 2);
    enforce(!r.empty && r.getString(0) == "?" && r.getInt(1) == 1 && r.getString(2) == "it's ?"
            && r.getInt(3) == 2, "placeholders and literals");
    r.close();
    auto e = collectException!ClientException(conn.exec("SELECT ?, ?", 1));
    enforce(e !is null && e.msg == "The statement has 2 placeholders but 1 arguments were given", e.msg);
    enforce(scalar(conn, "SELECT 1") == "1", "the connection stays usable");
    // several statements in one parameterized batch; row counts add up
    conn.exec("CREATE TABLE #b (v int)");
    scope (exit)
        conn.exec("DROP TABLE #b");
    enforce(conn.exec("INSERT INTO #b VALUES (?); INSERT INTO #b VALUES (?), (?); UPDATE #b SET v = v + ?",
            1, 2, 3, 10) == 6, "rows affected");
    enforce(scalar(conn, "SELECT SUM(v) FROM #b") == "36", "values");
    // a server error with parameters keeps the connection
    enforce(collectException!ServerException(conn.exec("INSERT INTO #b VALUES (?)", "not a number")) !is null,
            "conversion error");
    enforce(scalar(conn, "SELECT COUNT(*) FROM #b") == "3", "the connection stays usable");
}

/// Output parameters of sp_executesql: values come back after the rows.
void testOutputParameters()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SET ? = ? * 2; SET ? = N'мир ' + ?; SET ? = SYSDATETIMEOFFSET(); SET ? = 0x0102; "
            ~ "SET ? = ?; SELECT 5 AS five", Parameter.outputOf!int, 21, Parameter.outputOf!string,
            "x", Parameter.outputOf!SysTime, Parameter.outputOf!(ubyte[]),
            Parameter.output(Decimal.fromString("1.25")), Decimal.fromString("-7.5"));
    enforce(collectException!ClientException(r.outputs) !is null, "outputs before the rows are read");
    enforce(!r.empty && r.getInt(0) == 5, "the result set");
    r.close();
    const o = r.outputs;
    enforce(o.length == 5, "five outputs, got " ~ o.length.to!string);
    enforce(o[0].name == "@p1" && o[0].getInt() == 42, "int output");
    enforce(o[1].getString() == "мир x", "nvarchar output");
    enforce(o[2].getSysTime().year >= 2024, "datetimeoffset output");
    enforce(o[3].getBytes() == [1, 2], "varbinary output");
    enforce(o[4].getString() == "-7.50", "decimal output keeps the declared scale (2)");
    enforce(r.returnStatus.isNull, "no return status for a query");
}

/// Stored procedures: positional and named parameters, OUTPUT, return status, result sets, errors.
void testStoredProcedures()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE PROCEDURE #proc @a int, @b nvarchar(20) = N'default', @twice int OUTPUT AS "
            ~ "BEGIN SET @twice = @a * 2; SELECT @a AS a, @b AS b; IF @a < 0 RAISERROR('negative', 16, 1); "
            ~ "RETURN @a + 1 END");
    auto r = conn.callProcedure("#proc", 20, "given", Parameter.outputOf!int);
    enforce(!r.empty && r.getInt(0) == 20 && r.getString(1) == "given", "positional parameters");
    r.close();
    enforce(!r.returnStatus.isNull && r.returnStatus.get == 21, "return status");
    enforce(r.outputs.length == 1 && r.outputs[0].getInt() == 40, "OUTPUT parameter");

    r = conn.callProcedure("#proc", Parameter.of(5).named("a"), Parameter.outputOf!int.named("@twice"));
    enforce(!r.empty && r.getString(1) == "default", "named parameters and a default");
    r.close();
    enforce(r.outputs[0].name == "@twice" && r.outputs[0].getInt() == 10, "named OUTPUT");

    r = conn.callProcedure("#proc", -1, "x", Parameter.outputOf!int);
    auto e = collectException!ServerException({
        foreach (row; r)
        {
        }
        r.close();
    }());
    enforce(e !is null && e.msg.indexOf("negative") >= 0, "an error in the procedure");
    enforce(collectException!ServerException(conn.callProcedure("#no_such_proc").close()) !is null,
            "an unknown procedure");
    enforce(scalar(conn, "SELECT 1") == "1", "the connection stays usable");
}

/// Prepared statements: prepared once, run many times, prepared again when the types change.
void testPreparedStatements()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #s (id int, name nvarchar(max))");
    scope (exit)
        conn.exec("DROP TABLE #s");
    auto insert = conn.prepare("INSERT INTO #s VALUES (?, ?)");
    enforce(insert.parameterCount == 2 && !insert.isPrepared, "not prepared yet");
    foreach (i; 0 .. 10)
        enforce(insert.exec(i, "name " ~ i.to!string) == 1, "inserted");
    enforce(insert.isPrepared, "prepared");
    enforce(insert.exec(100, "x".replicate(5000)) == 1, "a long string: prepared again as nvarchar(max)");
    enforce(insert.exec(101, "short again") == 1, "and again");
    insert.close();
    enforce(!insert.isPrepared, "closed");
    enforce(insert.exec(102, "after close") == 1, "prepared again after close");
    insert.close();

    auto select = conn.prepare("SELECT id, name FROM #s WHERE id >= ? ORDER BY id");
    foreach (from; [0, 5, 100])
    {
        size_t rows;
        foreach (row; select.query(from))
            rows++;
        enforce(rows == (from == 0 ? 13 : from == 5 ? 8 : 3), "rows from " ~ from.to!string);
    }
    auto e = collectException!ClientException(select.query());
    enforce(e !is null, "wrong argument count");
    enforce(scalar(conn, "SELECT COUNT(*) FROM #s") == "13", "the connection stays usable");

    auto failing = conn.prepare("SELECT 1 / ?");
    enforce(collectException!ServerException(failing.query(0).close()) !is null, "division by zero");
    auto ok = failing.query(1);
    enforce(!ok.empty && ok.getInt(0) == 1, "the same statement afterwards");
    ok.close();
    failing.close();
    auto noParams = conn.prepare("SELECT 42");
    auto r = noParams.query();
    enforce(!r.empty && r.getInt(0) == 42, "without parameters");
    r.close();
    noParams.close();
}

/// Parameters inside a transaction (the transaction descriptor goes with RPC requests too).
void testParametersInTransaction()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #tx (v int)");
    scope (exit)
        conn.exec("DROP TABLE #tx");
    conn.exec("BEGIN TRANSACTION");
    conn.exec("INSERT INTO #tx VALUES (?)", 1);
    auto st = conn.prepare("INSERT INTO #tx VALUES (?)");
    st.exec(2);
    enforce(conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #tx") == "2", "inside");
    conn.exec("ROLLBACK");
    enforce(!conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #tx") == "0", "rolled back");
    st.exec(3);
    st.close();
    enforce(scalar(conn, "SELECT COUNT(*) FROM #tx") == "1", "after the transaction");
}

/// `Variant` and `Parameter[]` arguments (for drivers that build parameters at run time).
void testRuntimeParameters()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    Variant[] values = [
        Variant(1), Variant("two"), Variant(Decimal.fromString("3.5")), Variant(Date(2024, 1, 4))
    ];
    Parameter[] params;
    foreach (v; values)
        params ~= Parameter.of(v);
    auto r = conn.query("SELECT ?, ?, ?, ?", params);
    enforce(!r.empty && r.getInt(0) == 1 && r.getString(1) == "two" && r.getString(2) == "3.5"
            && r.getDate(3) == Date(2024, 1, 4), "Variant parameters");
    r.close();
    enforce(collectException!ClientException(Parameter.of(Variant([1, 2]))) !is null, "an unsupported Variant");
}

private string replicate(string s, size_t n)
{
    string r;
    foreach (_; 0 .. n)
        r ~= s;
    return r;
}

private ptrdiff_t indexOf(string s, string what)
{
    import std.string : indexOf;

    return s.indexOf(what);
}
