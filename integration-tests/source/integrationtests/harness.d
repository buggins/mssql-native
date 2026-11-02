/++
Integration test harness shared by the thread (Phobos) and fiber (vibe.d)
runners. Tests are written once here; each runner calls `runAllTests` in its
own I/O context. Tests that need a server run only when `MSSQL_HOST` is set.
+/
module integrationtests.harness;

import core.exception : AssertError;
import std.stdio : stderr, writefln;

import integrationtests.basic;
import integrationtests.params;
import integrationtests.statements;
import integrationtests.types;
import integrationtests.server : serverConfigured;

/// Integration test entry point. Throws on failure.
alias TestFunction = void function();

/// A named integration test.
struct TestCase
{
    /// Test name used in reports.
    string name;
    /// Test body.
    TestFunction run;
    /// Whether the test needs a server.
    bool needsServer;
}

/// All integration tests, in execution order.
immutable TestCase[] allTests = [
    TestCase("connect and server version", &testConnect, true),
    TestCase("integer, bit, float and string values", &testBasicValues, true),
    TestCase("exec row counts and a temporary table", &testExecRowCounts, true),
    TestCase("server error keeps the connection", &testServerError, true),
    TestCase("batches with several statements", &testMultipleStatements, true),
    TestCase("informational messages (PRINT)", &testInfoMessages, true),
    TestCase("encryption modes and certificate verification", &testEncryption, true),
    TestCase("failed login and failover", &testLoginAndFailover, true),
    TestCase("transactions", &testTransactions, true),
    TestCase("packet size, long batches, many rows", &testPacketSize, true),
    TestCase("USE changes the database", &testUseDatabase, true),
    TestCase("busy connection and closed results", &testBusy, true),
    TestCase("receive timeout", &testReceiveTimeout, true),
    TestCase("text of every type matches the server", &testTextMatchesServer, true),
    TestCase("datetime and smalldatetime rounding", &testDatetimeRounding, true),
    TestCase("time, datetime2, datetimeoffset scales", &testTimeScales, true),
    TestCase("char and varchar in every code page", &testCodePages, true),
    TestCase("typed getters and Variants", &testTypedGetters, true),
    TestCase("float and real values", &testFloats, true),
    TestCase("table with every type and NULL rows", &testTableRoundTrip, true),
    TestCase("types not supported yet", &testUnsupportedTypes, true),
    TestCase("parameter values of every D type", &testParameterValues, true),
    TestCase("parameters into typed columns", &testParametersIntoColumns, true),
    TestCase("NULL parameters", &testNullParameters, true),
    TestCase("placeholders and argument counts", &testPlaceholders, true),
    TestCase("output parameters", &testOutputParameters, true),
    TestCase("stored procedures", &testStoredProcedures, true),
    TestCase("prepared statements", &testPreparedStatements, true),
    TestCase("parameters in a transaction", &testParametersInTransaction, true),
    TestCase("Variant and Parameter[] arguments", &testRuntimeParameters, true),
    TestCase("multiple result sets and row counts", &testMultipleResultSets, true),
    TestCase("procedures with several result sets", &testProcedureResultSets, true),
    TestCase("cancelling a result", &testCancelResult, true),
    TestCase("transaction helpers and isolation levels", &testTransactionHelpers, true),
    TestCase("session reset", &testResetSession, true),
    TestCase("fatal errors close the connection", &testFatalError, true),
];

/// Runner identity, for reports.
struct RunnerContext
{
    /// Runner name used in reports, e.g. "phobos" or "vibe".
    string name;
}

/++
Runs all integration tests, plus `extraTests` from the runner, and prints a report.

Returns: the number of failed tests.
+/
int runAllTests(RunnerContext runner, const TestCase[] extraTests = null)
{
    const withServer = serverConfigured();
    if (!withServer)
        writefln("[%s] MSSQL_HOST is not set: skipping tests that need a server", runner.name);
    int failures, skipped;
    foreach (test; allTests ~ extraTests)
    {
        if (test.needsServer && !withServer)
        {
            skipped++;
            writefln("[%s] SKIP  %s", runner.name, test.name);
            continue;
        }
        try
        {
            test.run();
            writefln("[%s] PASS  %s", runner.name, test.name);
        }
        catch (AssertError e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s (%s:%s)", runner.name, test.name, e.msg, e.file, e.line);
        }
        catch (Exception e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s", runner.name, test.name, e.msg);
        }
    }
    writefln("[%s] %d test(s), %d failed, %d skipped", runner.name, allTests.length + extraTests.length, failures,
            skipped);
    return failures;
}
