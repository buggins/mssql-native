/++
mssql-native in a vibe.d application: tasks share a connection pool, and
waiting for SQL Server suspends only the waiting task, not the thread.

Run with `dub run :example-vibe`. The connection string comes from the
`MSSQL_CONNECTION` environment variable (see the basic example).
+/
module app;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.process : environment;
import std.stdio : writefln;

import vibe.core.core : exitEventLoop, runEventLoop, runTask;
import vibe.core.task : Task;

import mssql;

void main()
{
    // Inside vibe.d tasks the pool's connections use vibe-core sockets automatically
    auto options = ConnectionOptions.parse(environment.get("MSSQL_CONNECTION",
            "sqlserver://sa@localhost/master?trust_server_certificate=true"));
    auto pool = new ConnectionPool(options, PoolOptions(4));

    // Runs one query on a pooled connection
    void query(int n) nothrow
    {
        try
        {
            auto conn = pool.lockConnection();
            const value = conn.queryValue!int("WAITFOR DELAY '00:00:00.500'; SELECT ? * 10", n);
            print("task %s: got %s", n, value);
        }
        catch (Exception e)
            print("task %s failed: %s", n, e.msg);
    }

    void work() nothrow
    {
        scope (exit)
            exitEventLoop();
        try
        {
            auto sw = StopWatch(AutoStart.yes);
            Task[] tasks;
            foreach (i; 0 .. 8)
                tasks ~= runTask(&query, i);
            foreach (t; tasks)
                t.join();
            // 8 half-second queries on 4 pooled connections: about one second in total
            print("8 queries in %s", sw.peek);
            pool.close();
        }
        catch (Exception e)
            print("error: %s", e.msg);
    }

    runTask(&work);
    runEventLoop();
}

/// `writefln` that never throws, for use in tasks.
void print(Args...)(string format, Args args) nothrow
{
    try
        writefln(format, args);
    catch (Exception)
    {
    }
}
