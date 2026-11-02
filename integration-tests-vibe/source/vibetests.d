/// Fiber-mode tests that need vibe-core: waiting for the server doesn't block the event loop.
module vibetests;

import core.time : MonoTime, msecs, seconds;
import std.exception : enforce;

import vibe.core.core : runTask;

import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar;

/// Tests registered by the vibe.d runner.
immutable TestCase[] vibeTests = [
    TestCase("fiber: queries run concurrently", &testConcurrentQueries, true),
    TestCase("fiber: cancel from another task", &testCancelFromTask, true),
    TestCase("fiber: a pool shared by tasks", &testPoolTasks, true),
];

/// Six tasks share a pool of three connections: six half-second queries take about one second.
void testPoolTasks()
{
    import mssql : ConnectionPool, PoolOptions;
    import integrationtests.server : serverOptions;

    auto pool = new ConnectionPool(serverOptions(), PoolOptions(3));
    scope (exit)
        pool.close();
    string[6] results;
    void work(size_t i) nothrow
    {
        try
        {
            auto conn = pool.lockConnection();
            results[i] = scalar(conn, "WAITFOR DELAY '00:00:00.500'; SELECT 'ok'");
        }
        catch (Exception e)
            results[i] = e.msg;
    }

    const start = MonoTime.currTime;
    typeof(runTask(&work, cast(size_t) 0))[] tasks;
    foreach (i; 0 .. 6)
        tasks ~= runTask(&work, cast(size_t) i);
    foreach (t; tasks)
        t.join();
    const elapsed = MonoTime.currTime - start;
    foreach (r; results)
        enforce(r == "ok", "a task failed: " ~ r);
    enforce(elapsed < 1800.msecs, "the pool didn't run three queries at a time");
    enforce(pool.activeConnections == 0 && pool.idleConnections <= 3, "at most three connections");
}

/// `Connection.cancel` from another task stops a batch that waits on the server.
void testCancelFromTask()
{
    import std.exception : collectException;
    import vibe.core.core : sleep;
    import mssql : ClientException;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    void cancelLater() nothrow
    {
        try
        {
            sleep(300.msecs);
            conn.cancel();
        }
        catch (Exception)
        {
        }
    }

    auto canceller = runTask(&cancelLater);
    const start = MonoTime.currTime;
    auto e = collectException!ClientException(conn.exec("WAITFOR DELAY '00:00:10'"));
    canceller.join();
    enforce(e !is null && e.msg == "The batch was cancelled", e is null ? "not cancelled" : e.msg);
    enforce(MonoTime.currTime - start < 5.seconds, "the cancel didn't stop the batch");
    enforce(scalar(conn, "SELECT 1") == "1", "usable after the cancel");
}

/// Three one-second queries in three tasks on one thread take about one second, not three.
void testConcurrentQueries()
{
    enforce(scalar(connectToServer(), "SELECT 1") == "1", "connection in a task");
    string[3] results;
    void query(size_t i) nothrow
    {
        try
        {
            auto conn = connectToServer();
            scope (exit)
                conn.close();
            results[i] = scalar(conn, "WAITFOR DELAY '00:00:01'; SELECT 'done'");
        }
        catch (Exception e)
            results[i] = e.msg;
    }

    const start = MonoTime.currTime;
    auto a = runTask(&query, cast(size_t) 0);
    auto b = runTask(&query, cast(size_t) 1);
    auto c = runTask(&query, cast(size_t) 2);
    a.join();
    b.join();
    c.join();
    const elapsed = MonoTime.currTime - start;
    enforce(results == ["done", "done", "done"], "results: " ~ results[0] ~ ", " ~ results[1] ~ ", " ~ results[2]);
    enforce(elapsed < 2500.msecs, "the queries ran one after the other");
}
