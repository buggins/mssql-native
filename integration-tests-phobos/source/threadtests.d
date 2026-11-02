/// Thread-mode tests: a cancel from another thread.
module threadtests;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.exception : collectException, enforce;

import mssql;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar;

/// Tests registered by the thread runner.
immutable TestCase[] threadTests = [
    TestCase("thread: cancel from another thread", &testCancelFromThread, true),
    TestCase("thread: a pool shared by threads", &testPoolThreads, true),
];

/// Eight threads share a pool of three connections; each waits for a free one.
void testPoolThreads()
{
    import core.atomic : atomicOp;
    import integrationtests.server : serverOptions;

    auto pool = new ConnectionPool(serverOptions(), PoolOptions(3));
    scope (exit)
        pool.close();
    shared int done;
    shared int failed;
    Thread[] threads;
    foreach (i; 0 .. 8)
    {
        threads ~= new Thread({
            try
            {
                foreach (k; 0 .. 5)
                {
                    auto conn = pool.lockConnection();
                    if (conn.queryValue!int("SELECT ? + ?", k, 1) != k + 1)
                        atomicOp!"+="(failed, 1);
                }
                atomicOp!"+="(done, 1);
            }
            catch (Exception)
                atomicOp!"+="(failed, 1);
        });
        threads[$ - 1].start();
    }
    foreach (t; threads)
        t.join();
    enforce(done == 8 && failed == 0, "threads failed");
    enforce(pool.idleConnections <= 3 && pool.activeConnections == 0, "at most three connections");
}

/// `Connection.cancel` from another thread stops `exec` and a result being read.
void testCancelFromThread()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto canceller = new Thread({ Thread.sleep(300.msecs); conn.cancel(); });
    canceller.start();
    const start = MonoTime.currTime;
    auto e = collectException!ClientException(conn.exec("WAITFOR DELAY '00:00:10'"));
    canceller.join();
    enforce(e !is null && e.msg == "The batch was cancelled", e is null ? "not cancelled" : e.msg);
    enforce(MonoTime.currTime - start < 5.seconds, "the cancel didn't stop the batch");
    enforce(scalar(conn, "SELECT 1") == "1", "usable after the cancel");

    // the server sends the first row only after the WAITFOR: the cancel arrives while query() waits
    canceller = new Thread({ Thread.sleep(300.msecs); conn.cancel(); });
    canceller.start();
    const queryStart = MonoTime.currTime;
    auto r = conn.query("SELECT 1; WAITFOR DELAY '00:00:10'; SELECT 2");
    size_t rows;
    foreach (row; r)
        rows++;
    canceller.join();
    enforce(rows <= 1 && r.cancelled && !conn.isBusy, "the result ends at the cancel");
    enforce(MonoTime.currTime - queryStart < 5.seconds, "the cancel didn't stop the query");
    enforce(scalar(conn, "SELECT 2") == "2", "usable");
}
