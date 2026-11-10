/++
Prepared statements: `PreparedStatement`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.prepared;

import mssql.connection : Connection;
import mssql.exception : ClientException;
import mssql.params : Parameter, declarations, numbered, parameters, rewritePlaceholders;
import mssql.protocol.rpc : OutputParameter, ProcId;
import mssql.result : QueryResult;

/++
A statement with `?` placeholders that the server compiles once and runs many
times; create it with `Connection.prepare`.

The first execution prepares and runs it (`sp_prepexec`), later ones run the
prepared form (`sp_execute`). If the parameter types change (e.g. a string
grows beyond 4000 characters and becomes `nvarchar(max)`), it is prepared
again. `close` releases it on the server (`sp_unprepare`); closing the
connection releases it too.
+/
final class PreparedStatement
{
    private Connection conn;
    private ulong lease; // the connection's lease (pooled connections)
    private string text; // with @p1, @p2, ...
    private size_t count; // placeholders
    private int handle; // 0: not prepared
    private string preparedDeclarations;
    private string originalSql;

    package this(Connection conn, string sql) @safe
    {
        this.conn = conn;
        lease = conn.lease;
        originalSql = sql;
        text = rewritePlaceholders(sql, count);
    }

    /// The statement as given to `Connection.prepare`.
    @property string sql() const @safe pure nothrow
    {
        return originalSql;
    }

    /// The number of `?` placeholders.
    @property size_t parameterCount() const @safe pure nothrow
    {
        return count;
    }

    /// Whether the server holds a prepared form (after the first execution).
    @property bool isPrepared() const @safe pure nothrow
    {
        return handle != 0;
    }

    /++
    Runs the statement with `args` for its placeholders, or one `Parameter[]`
    (see `Connection.exec`).

    Returns: the number of rows inserted, updated or deleted.
    Throws: `ClientException` if the number of arguments is wrong;
    `ServerException` if the statement failed.
    +/
    ulong exec(Args...)(Args args)
    {
        return execParams(parameters(args));
    }

    private ulong execParams(const Parameter[] params) @safe
    {
        const preparing = send(params);
        // also after a ServerException (the handle comes back even when the first execution fails); after
        // other errors the connection is closed and the handle is gone with it
        scope (exit)
            if (preparing && conn.isOpen && !conn.isBusy)
                takeHandle(conn.responseOutputs);
        return conn.readExecResponse();
    }

    /++
    Runs the statement with `args` and returns its rows (see `Connection.query`).

    Throws: as `exec`.
    +/
    QueryResult query(Args...)(Args args)
    {
        return queryParams(parameters(args));
    }

    private QueryResult queryParams(const Parameter[] params) @safe
    {
        const preparing = send(params);
        return new QueryResult(conn, preparing ? &takeHandle : null);
    }

    /++
    Releases the statement on the server. Calling it again does nothing.

    Throws: `ClientException` if the connection is busy with a result.
    +/
    void close() @safe
    {
        if (handle == 0 || !conn.isOpen || conn.lease != lease) // a returned pooled session is reset
        {
            handle = 0;
            return;
        }
        conn.checkReady(); // a busy connection: keep the handle, so close can be called again
        const h = handle;
        handle = 0;
        conn.sendRpc(null, ProcId.unprepare, [Parameter.of(h)]);
        conn.readExecResponse();
    }

    /// Sends the execution request; returns whether it prepares (the handle comes back as output 0).
    private bool send(const Parameter[] params) @safe
    {
        import std.conv : to;

        if (conn.lease != lease)
            throw new ClientException("The statement was prepared before the pooled connection was returned");
        if (params.length != count)
            throw new ClientException("The statement has " ~ count.to!string ~ " placeholders but "
                    ~ params.length.to!string ~ " arguments were given");
        auto values = numbered(params);
        const decl = declarations(values);
        if (handle != 0 && decl != preparedDeclarations)
            close(); // the types changed: prepare again
        if (handle != 0)
        {
            conn.sendRpc(null, ProcId.execute, [Parameter.of(handle)] ~ values);
            return false;
        }
        preparedDeclarations = decl;
        conn.sendRpc(null, ProcId.prepExec, [
            Parameter.outputOf!int(), count ? Parameter.of(decl) : Parameter.nullOf!string(),
            Parameter.of(text)
        ] ~ values);
        return true;
    }

    private void takeHandle(const(OutputParameter)[] outputs) @safe
    {
        foreach (ref o; outputs)
            if (o.ordinal == 0 && !o.isNull)
                handle = o.getInt();
    }
}
