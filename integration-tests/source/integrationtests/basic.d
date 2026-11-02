/// Connection, batches, results and errors (M1).
module integrationtests.basic;

import std.conv : to;
import std.exception : assertThrown, collectException, enforce;
import std.format : format;

import mssql;
import integrationtests.server;

/// Connects; checks the login's results.
void testConnect()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    enforce(conn.isOpen && !conn.isBusy, "not ready after connecting");
    enforce(conn.tdsVersion == 0x74000004, format("TDS version %08X", conn.tdsVersion));
    const major = conn.serverVersion.splitFirst.to!int;
    enforce(major >= 14, "server older than SQL Server 2017: " ~ conn.serverVersion);
    enforce(conn.database == "master", "database " ~ conn.database);
    enforce(conn.language.length > 0 && conn.packetSize >= 512, "language or packet size missing");
    enforce(scalar(conn, "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int)") == major.to!string,
            "version differs from SERVERPROPERTY");
    enforce(scalar(conn, "SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID") == "TRUE",
            "the connection is not encrypted");
    conn.ping();
}

/// Values of the M1 types, NULLs and extremes.
void testBasicValues()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT CAST(-2147483648 AS int) AS i, CAST(9223372036854775807 AS bigint) AS b, "
            ~ "CAST(-9223372036854775808 AS bigint) AS bmin, CAST(255 AS tinyint) AS t, CAST(-32768 AS smallint) AS s, "
            ~ "CAST(1 AS bit) AS yes, CAST(0 AS bit) AS no, CAST(NULL AS bit) AS nb, CAST(NULL AS bigint) AS nn, "
            ~ "N'Grüße, мир 😀' AS u, N'' AS empty, CAST(NULL AS nvarchar(5)) AS ns, CAST(1.5 AS real) AS r, "
            ~ "CAST(-0.1 AS float) AS f, CAST('ascii' AS varchar(10)) AS v, CAST(N'fixed' AS nchar(8)) AS nc");
    scope (exit)
        r.close();
    enforce(!r.empty, "no row");
    enforce(r.columns.length == 16 && r.columnIndex("U") == 9, "columns");
    enforce(r.getLong(0) == int.min && r.getLong(1) == long.max && r.getLong(2) == long.min, "integers");
    enforce(r.getInt(3) == 255 && r.getInt(4) == short.min, "tinyint/smallint");
    enforce(r.getBool(5) && !r.getBool(6) && r.isNull(7) && !r.getBool(7), "bit");
    enforce(r.isNull(8) && r.getLong(8) == 0 && r.getString(8) is null, "NULL bigint");
    enforce(r.getString(9) == "Grüße, мир 😀" && r.getString(10) == "" && !r.isNull(10), "nvarchar");
    enforce(r.isNull(11) && r.getString(11) is null, "NULL nvarchar");
    enforce(r.getDouble(12) == 1.5 && r.getDouble(13) == -0.1, "real/float");
    enforce(r.getString(14) == "ascii" && r.getString(15) == "fixed   ", "varchar/nchar");
    enforce(r.getString(0) == "-2147483648" && r.getString(5) == "1", "integers as text");
    assertThrown!ClientException(r.getInt(1)); // does not fit
    r.popFront();
    enforce(r.empty && r.rowCount == 1, "one row expected");
}

/// exec returns rows affected; a temporary table round trip.
void testExecRowCounts()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    enforce(conn.exec("CREATE TABLE #t (id int PRIMARY KEY, name nvarchar(20) NULL, flag bit NOT NULL)") == 0,
            "DDL counts no rows");
    enforce(conn.exec("INSERT INTO #t VALUES (1, N'one', 1), (2, N'two', 0), (3, NULL, 1)") == 3, "insert");
    enforce(conn.exec("UPDATE #t SET name = N'x' WHERE id >= 2; DELETE FROM #t WHERE id = 1") == 3,
            "update + delete");
    enforce(conn.exec("SELECT * FROM #t") == 0, "SELECT rows are not counted");
    long[] ids;
    string[] names;
    foreach (row; conn.query("SELECT id, name FROM #t ORDER BY id"))
    {
        ids ~= row.getLong(0);
        names ~= row.getString(1);
    }
    enforce(ids == [2, 3] && names == ["x", "x"], "rows");
    auto r = conn.query("SELECT * FROM #t WHERE id > 100");
    enforce(r.empty && r.columns.length == 3 && !conn.isBusy, "an empty result keeps its columns");
}

/// Errors are ServerExceptions; the connection stays usable.
void testServerError()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto e = collectException!ServerException(conn.exec("SELECT * FROM no_such_table"));
    enforce(e !is null && e.number == 208 && e.severity == 16 && e.error.lineNumber == 1, "error 208");
    enforce(e.error.serverName.length > 0, "server name");
    e = collectException!ServerException(conn.query("SELECT 1 +"));
    enforce(e !is null && e.number == 102, "syntax error");
    e = collectException!ServerException(conn.exec("RAISERROR(N'custom %d', 16, 3, 42)"));
    enforce(e !is null && e.number == 50_000 && e.error.state == 3 && e.error.message == "custom 42", "RAISERROR");
    enforce(scalar(conn, "SELECT 1") == "1" && !conn.isBusy, "connection not usable after errors");
}

/// The first result set's rows; later statements are read and discarded; their errors surface.
void testMultipleStatements()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    long[] values;
    foreach (row; conn.query("SET NOCOUNT ON; DECLARE @x int = 5; SELECT @x AS a UNION ALL SELECT 6; SELECT 99"))
        values ~= row.getLong(0);
    enforce(values == [5, 6], "first result set only");
    enforce(!conn.isBusy, "busy after the rows");

    auto r = conn.query("SELECT 1; SELECT 1/0");
    enforce(!r.empty && r.getLong(0) == 1, "first row");
    r.popFront();
    auto e = collectException!ServerException(r.empty); // the rest of the batch fails
    enforce(e !is null && e.number == 8134, "division by zero not reported");
    enforce(!conn.isBusy && scalar(conn, "SELECT 2") == "2", "connection not usable");

    // SET NOCOUNT ON (above) lasts for the session: no counts until it is off again
    enforce(conn.exec("CREATE TABLE #m (x int); INSERT INTO #m VALUES (1)") == 0, "NOCOUNT");
    enforce(conn.exec("SET NOCOUNT OFF; INSERT INTO #m VALUES (1); INSERT INTO #m VALUES (2), (3)") == 3,
            "row counts summed");
}

/// INFO tokens go to onMessage.
void testInfoMessages()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    ServerMessage[] messages;
    conn.onMessage = (ServerMessage m) { messages ~= m; };
    conn.exec("PRINT N'hello'; PRINT N'world'");
    enforce(messages.length == 2 && messages[0].message == "hello" && messages[1].message == "world",
            "PRINT messages");
    enforce(messages[0].severity == 0, "PRINT is informational");
}

/// Login-only encryption, full encryption, certificate verification.
void testEncryption()
{
    import std.process : environment;

    auto loginOnly = connectToServer("encrypt=false");
    scope (exit)
        loginOnly.close();
    const encrypted = scalar(loginOnly,
            "SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID");
    // a server with "force encryption" encrypts everything; otherwise only the login is
    enforce(encrypted == "FALSE" || encrypted == "TRUE", "encrypt_option " ~ encrypted);
    enforce(scalar(loginOnly, "SELECT N'ok'") == "ok", "queries after login-only encryption");

    if (environment.get("MSSQL_VERIFY", "") != "1")
    {
        // Docker images have self-signed certificates: verification must fail without trust
        auto options = serverOptions();
        options.trustServerCertificate = false;
        auto e = collectException!ConnectionException(new Connection(options));
        enforce(e !is null, "a self-signed certificate was accepted");
    }
}

/// A rejected login is not retried on another host; unreachable hosts are skipped.
void testLoginAndFailover()
{
    auto options = serverOptions();
    options.password = "wrong password";
    auto e = collectException!ServerException(new Connection(options));
    enforce(e !is null && e.number == 18_456, "login failure");

    // the first host refuses connections; the second is the server
    auto good = serverOptions();
    const target = good.hosts.length ? good.hosts[0] : HostPort(good.host, good.port);
    good.hosts = [HostPort("127.0.0.1", 1), target];
    auto conn = new Connection(good);
    scope (exit)
        conn.close();
    enforce(conn.host == HostPort(target.host, ConnectionOptions.effectivePort(target.port)), "connected host");
}

/// Transactions: the descriptor from ENVCHANGE is sent with later requests.
void testTransactions()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #tx (x int)");
    conn.exec("BEGIN TRANSACTION");
    enforce(conn.inTransaction, "not in a transaction after BEGIN");
    conn.exec("INSERT INTO #tx VALUES (1)");
    enforce(scalar(conn, "SELECT COUNT(*) FROM #tx") == "1" && scalar(conn, "SELECT @@TRANCOUNT") == "1",
            "inside the transaction");
    conn.exec("ROLLBACK");
    enforce(!conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #tx") == "0", "rollback");
    conn.exec("BEGIN TRAN; INSERT INTO #tx VALUES (2); COMMIT");
    enforce(!conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #tx") == "1", "commit");
}

/// A negotiated packet size; batches and results larger than a packet.
void testPacketSize()
{
    import std.array : replicate;

    auto conn = connectToServer("packet_size=8000");
    scope (exit)
        conn.close();
    enforce(conn.packetSize == 8000, "packet size " ~ conn.packetSize.to!string);
    const long_ = replicate("é", 30_000); // 60 KB of UTF-16 in the batch
    enforce(scalar(conn, "SELECT LEN(N'" ~ long_ ~ "')") == "30000", "long batch");
    long sum;
    size_t rows;
    foreach (row; conn.query("SELECT TOP 5000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n, "
            ~ "REPLICATE(N'x', 100) AS pad FROM sys.all_objects a CROSS JOIN sys.all_objects b"))
    {
        sum += row.getLong(0);
        enforce(row.getString(1).length == 100, "padding");
        rows++;
    }
    enforce(rows == 5000 && sum == 5000L * 5001 / 2, "many rows");
}

/// USE updates the connection's database.
void testUseDatabase()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("USE tempdb");
    enforce(conn.database == "tempdb" && scalar(conn, "SELECT DB_NAME()") == "tempdb", "USE tempdb");
}

/// One request at a time; closing a result releases the connection.
void testBusy()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3");
    enforce(!r.empty && conn.isBusy, "busy while rows remain");
    assertThrown!ClientException(conn.exec("SELECT 1"));
    r.close();
    enforce(!conn.isBusy && scalar(conn, "SELECT 4") == "4", "usable after close");
    conn.close();
    assertThrown!ClientException(conn.exec("SELECT 1"));
}

/// A receive timeout ends a query that takes too long, and the connection with it.
void testReceiveTimeout()
{
    auto conn = connectToServer("receive_timeout=1");
    scope (exit)
        conn.close();
    enforce(scalar(conn, "SELECT 1") == "1", "a quick query");
    auto e = collectException!ConnectionException(conn.exec("WAITFOR DELAY '00:00:03'"));
    enforce(e !is null && !conn.isOpen, "no timeout, or the connection stayed open");
}

/// Types of later milestones are read (the stream stays in sync) and refused clearly on access.
void testUnsupportedTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT CAST(1.5 AS decimal(5,2)) AS d, SYSDATETIME() AS t, NEWID() AS g, 7 AS after");
    scope (exit)
        r.close();
    enforce(!r.empty && r.getLong(3) == 7, "the value after them");
    auto e = collectException!ClientException(r.getString(0));
    enforce(e !is null && e.msg == "Cannot read a decimal value as text (this type is not supported yet)", e.msg);
    enforce(r.getBytes(2).length == 16, "raw bytes of a uniqueidentifier");
}

private string splitFirst(string version_)
{
    import std.string : indexOf;

    const dot = version_.indexOf('.');
    return dot < 0 ? version_ : version_[0 .. dot];
}
