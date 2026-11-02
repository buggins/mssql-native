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
];

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
