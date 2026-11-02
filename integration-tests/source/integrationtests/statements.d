/++
Statements in depth: multiple result sets, row counts, cancel, transactions,
session reset, fatal errors.
+/
module integrationtests.statements;

import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.exception : collectException, enforce;
import mssql;
import integrationtests.server : connectToServer, scalar;

/// `queryMultiple`: every result set in order, statements without one skipped, counts per statement.
void testMultipleResultSets()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.queryMultiple("CREATE TABLE #m (v int); INSERT INTO #m VALUES (1), (2), (3); "
            ~ "SELECT v FROM #m ORDER BY v; SELECT v FROM #m WHERE v > 100; UPDATE #m SET v = v * 10 WHERE v > 1; "
            ~ "SELECT 'a' AS x, 2 AS y UNION ALL SELECT 'b', 3; DELETE FROM #m");
    long[] first;
    foreach (row; r)
        first ~= row.getLong(0);
    enforce(first == [1, 2, 3] && r.columns[0].name == "v", "first result set");
    enforce(conn.isBusy, "busy while result sets remain");
    enforce(r.nextResult() && r.empty && r.columns.length == 1, "an empty result set keeps its columns");
    enforce(r.nextResult() && r.columns.length == 2 && r.columns[0].name == "x", "third result set");
    enforce(r.next() && r.getString(0) == "a" && r.getInt(1) == 2, "a row of the third");
    enforce(!r.nextResult(), "no more result sets");
    enforce(!conn.isBusy, "released at the end");
    const c = r.counts;
    enforce(c.length == 6, "six counts, got " ~ c.length.to!string);
    enforce(c[0] == StatementCount(Command.insert, 3) && c[1] == StatementCount(Command.select, 3), "insert, select");
    enforce(c[3] == StatementCount(Command.update, 2) && c[5] == StatementCount(Command.delete_, 3), "update, delete");
    enforce(r.recordsAffected == 8, "records affected");

    // nextResult skips unread rows; with parameters
    r = conn.queryMultiple("SELECT number FROM master..spt_values WHERE type = 'P'; SELECT ? AS p", 42);
    enforce(!r.empty && r.nextResult() && r.next() && r.getInt(0) == 42, "skip to the second set");
    enforce(!r.nextResult(), "end");

    // an error in a later statement: thrown when the response ends; the connection stays usable
    r = conn.queryMultiple("SELECT 1; SELECT 1/0; SELECT 3");
    enforce(r.next() && r.getInt(0) == 1, "first set before the error");
    auto e = collectException!ServerException({
        while (r.nextResult())
        {
        }
    }());
    enforce(e !is null && e.number == 8134, "division by zero");
    enforce(scalar(conn, "SELECT 4") == "4", "usable after the error");

    // query() keeps only the first result set
    auto q = conn.query("SELECT 1; SELECT 2");
    enforce(q.next() && !q.next() && !q.nextResult() && !conn.isBusy, "query: one result set");
}

/// Stored procedures with several result sets; outputs and status after the last one.
void testProcedureResultSets()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE PROCEDURE #sets @n int OUTPUT AS BEGIN SELECT 1 AS a; SELECT 2 AS b; SET @n = 7; RETURN 3 END");
    auto r = conn.callProcedure("#sets", Parameter.outputOf!int);
    enforce(r.next() && r.getInt(0) == 1, "first set");
    enforce(collectException!ClientException(r.outputs) !is null, "outputs only at the end");
    enforce(r.nextResult() && r.next() && r.getInt(0) == 2, "second set");
    enforce(!r.nextResult(), "end");
    enforce(r.outputs[0].getInt() == 7 && r.returnStatus.get == 3, "outputs and status");
}

/// `QueryResult.cancel` stops a large result; a cancel after the batch ended is acknowledged too.
void testCancelResult()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b");
    enforce(r.next(), "a row");
    const start = MonoTime.currTime;
    r.cancel();
    enforce(r.cancelled && !conn.isBusy, "cancelled and released");
    enforce(MonoTime.currTime - start < 10.seconds, "the cancel didn't stop the query");
    enforce(scalar(conn, "SELECT 1") == "1", "usable after a cancel");

    // the batch is over before the attention arrives: the acknowledgement comes in a message of its own
    r = conn.query("SELECT 2");
    enforce(r.next() && r.getInt(0) == 2, "the row");
    conn.cancel();
    enforce(!r.next() && !conn.isBusy, "end of rows");
    enforce(scalar(conn, "SELECT 3") == "3", "the acknowledgement was read");
    conn.cancel(); // nothing running: does nothing
    enforce(scalar(conn, "SELECT 4") == "4", "cancel when idle");

    // a cancel inside a transaction stops the statement, not the transaction
    conn.exec("CREATE TABLE #c (v int)");
    conn.begin();
    conn.exec("INSERT INTO #c VALUES (1)");
    r = conn.query("SELECT a.object_id FROM sys.all_objects a CROSS JOIN sys.all_objects b");
    enforce(r.next(), "a row");
    r.cancel();
    enforce(conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #c") == "1", "the transaction stays");
    conn.rollback();
    enforce(!conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #c") == "0", "rolled back");
}

/// The transaction helpers: begin, commit, rollback, savepoints, isolation levels.
void testTransactionHelpers()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    enum levelSql = "SELECT transaction_isolation_level FROM sys.dm_exec_sessions WHERE session_id = @@SPID";
    conn.exec("CREATE TABLE #t (v int)");
    conn.begin();
    conn.exec("INSERT INTO #t VALUES (?)", 1);
    conn.commit();
    enforce(!conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #t") == "1", "committed");

    conn.begin(IsolationLevel.serializable);
    enforce(conn.inTransaction && scalar(conn, levelSql) == "4", "serializable");
    conn.exec("INSERT INTO #t VALUES (2)");
    conn.savepoint("before three");
    conn.exec("INSERT INTO #t VALUES (3)");
    conn.rollback("before three");
    enforce(conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #t") == "2", "back to the savepoint");
    conn.rollback();
    enforce(!conn.inTransaction && scalar(conn, "SELECT COUNT(*) FROM #t") == "1", "rolled back");

    conn.setIsolationLevel(IsolationLevel.readUncommitted);
    enforce(scalar(conn, levelSql) == "1", "read uncommitted");
    conn.setIsolationLevel(IsolationLevel.readCommitted);
    enforce(scalar(conn, levelSql) == "2", "read committed");
    // master allows snapshot isolation (ALLOW_SNAPSHOT_ISOLATION is on there)
    conn.begin(IsolationLevel.snapshot);
    enforce(scalar(conn, levelSql) == "5", "snapshot");
    conn.commit();
    conn.setIsolationLevel(IsolationLevel.readCommitted);
    enforce(scalar(conn, "SELECT 1") == "1", "usable");
}

/// `resetSession`: temporary tables, SET options, database and an open transaction are reset.
void testResetSession()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TABLE #r (v int); SET NOCOUNT ON; USE tempdb");
    enforce(conn.database == "tempdb", "USE");
    conn.begin();
    conn.exec("INSERT INTO #r VALUES (1)");
    conn.resetSession();
    enforce(collectException!ServerException(conn.exec("SELECT * FROM #r")) !is null, "temporary table dropped");
    enforce(conn.database == "master" && !conn.inTransaction, "database and transaction reset");
    enforce(conn.exec("CREATE TABLE #r (v int); INSERT INTO #r VALUES (1), (2)") == 2, "NOCOUNT reset");
}

/// An error of severity 20 or more ends the connection.
void testFatalError()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto e = collectException!ServerException(conn.exec("RAISERROR('fatal', 20, 1) WITH LOG"));
    enforce(e !is null && e.severity >= 20, "a fatal error");
    enforce(!conn.isOpen, "the connection is closed");
}
