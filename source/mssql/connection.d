/++
A connection to SQL Server: connecting (PRELOGIN, TLS, LOGIN7), SQL batches
and their responses.

Example:
---
auto conn = new Connection("sqlserver://sa:secret@localhost/master?trust_server_certificate=true");
scope (exit)
    conn.close();
conn.exec("CREATE TABLE #t (id int, name nvarchar(50))");
conn.exec("INSERT INTO #t VALUES (1, N'one'), (2, N'two')");
foreach (row; conn.query("SELECT id, name FROM #t ORDER BY id"))
    writeln(row.getLong(0), " ", row.getString(1));
---

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.connection;

import dbwire.client.hosts : connectFirst, orderHosts;
import dbwire.io.backend : IoBackend, backendFor;
import dbwire.io.buffer : BufferedReader;
import dbwire.io.transport : Transport;
import dbwire.tls.transport : TlsContext, TlsOptions, TlsTransport, TlsVersion;
import mssql.exception;
import mssql.protocol.login : Login7, buildLogin7;
import mssql.protocol.packet : PacketReader, PacketType, PacketWriter, defaultPacketSize;
import mssql.protocol.prelogin;
import dbwire.charset.utf16 : encodeUtf16le;
import mssql.params : Parameter, declarations, numbered, parameters, rewritePlaceholders;
import mssql.prepared : PreparedStatement;
import mssql.protocol.rpc : OutputParameter, ProcId, putParameter, putProcedure, readReturnValue;
import mssql.protocol.tokens;
import mssql.result : QueryResult;
import mssql.settings : ConnectionOptions, HostPort;
import mssql.types.typeinfo : Collation, ColumnInfo, ValueRef, readColumnMetadata, readValue;

/++
One connection to SQL Server.

One request at a time: a `QueryResult` keeps the connection busy until all its
rows are read or it is closed. The connection is not thread-safe. Call `close`
when done; the garbage collector does not close it.
+/
final class Connection
{
    package enum State
    {
        closed,
        ready,
        busy,
    }

    package State state = State.closed;
    package ConnectionOptions options;
    private IoBackend backend;
    private Transport transport;
    package PacketWriter writer;
    package PacketReader packets;
    package BufferedReader reader;
    private ulong transactionDescriptor; // 0 outside transactions (ENVCHANGE begin/commit/rollback)
    private ServerMessage[] errors; // ERROR tokens of the current response
    package OutputParameter[] responseOutputs; // RETURNVALUE tokens of the current response
    package bool responseHasStatus; // whether the current response had a RETURNSTATUS
    package int responseStatus; // its value
    private bool statusWanted; // the request calls a user's procedure (not sp_executesql, sp_execute, ...)
    private HostPort connectedHost;
    private LoginAck ack;
    private string currentDatabase;
    private string currentLanguage;
    private Collation defaultCollation;
    private uint negotiatedPacketSize = defaultPacketSize;

    /++
    Called with each informational message (INFO token: `PRINT` output,
    warnings, "Changed database context to ..."); may be null.
    +/
    void delegate(ServerMessage message) @safe onMessage;

    /++
    Connects and logs in.

    Throws: `ConnectionException` if no server can be reached or TLS fails;
    `ServerException` if the server rejects the login; `ClientException` for
    invalid options (e.g. OpenSSL missing when encryption is needed).
    +/
    this(ConnectionOptions options) @safe
    {
        this.options = options;
        connect();
    }

    /// Connects with a connection string; see `ConnectionOptions.fromDsn`.
    this(string dsn) @safe
    {
        this(ConnectionOptions.fromDsn(dsn));
    }

    /// Whether the connection is open (it may be busy).
    @property bool isOpen() const @safe pure nothrow
    {
        return state != State.closed;
    }

    /// Whether a result is still being read.
    @property bool isBusy() const @safe pure nothrow
    {
        return state == State.busy;
    }

    /// The server connected to.
    @property HostPort host() const @safe pure nothrow
    {
        return connectedHost;
    }

    /// The current database (updated by `USE`).
    @property string database() const @safe pure nothrow
    {
        return currentDatabase;
    }

    /// The session language, e.g. "us_english".
    @property string language() const @safe pure nothrow
    {
        return currentLanguage;
    }

    /// The database's default collation.
    @property Collation collation() const @safe pure nothrow
    {
        return defaultCollation;
    }

    /// The server's version, e.g. "16.0.4305" for SQL Server 2022.
    @property string serverVersion() const @safe pure
    {
        import std.conv : to;

        return ack.majorVersion.to!string ~ "." ~ ack.minorVersion.to!string ~ "." ~ ack.build.to!string;
    }

    /// The TDS version the server speaks, e.g. `0x74000004` for TDS 7.4.
    @property uint tdsVersion() const @safe pure nothrow
    {
        return ack.tdsVersion;
    }

    /// The packet size in use.
    @property uint packetSize() const @safe pure nothrow
    {
        return negotiatedPacketSize;
    }

    /// Whether the session is inside a transaction.
    @property bool inTransaction() const @safe pure nothrow
    {
        return transactionDescriptor != 0;
    }

    /++
    Runs a batch of SQL statements and reads all their results.

    Returns: the number of rows inserted, updated or deleted, over all
    statements of the batch (rows of SELECT statements are not counted).
    Throws: `ServerException` if a statement failed (the connection stays
    usable unless the error's severity is 20 or higher).
    +/
    ulong exec(string sql) @safe
    {
        sendBatch(sql);
        return readExecResponse();
    }

    /++
    Runs a statement (or batch) with parameters: each `?` placeholder of `sql`
    takes the next argument, converted as `mssql.params.Parameter.of` does
    (see `mssql.params` for the types); or pass one `Parameter[]` with all
    parameters (e.g. built at run time). The statement is sent with
    `sp_executesql`, so the server can reuse its plan.

    Returns: the number of rows inserted, updated or deleted.
    Throws: `ClientException` if the number of placeholders and arguments
    differ, or for a value that can't be sent; `ServerException` if a
    statement failed.
    +/
    ulong exec(Args...)(string sql, Args args) if (Args.length > 0)
    {
        return execParams(sql, parameters(args));
    }

    private ulong execParams(string sql, const Parameter[] params) @safe
    {
        sendExecuteSql(sql, params);
        return readExecResponse();
    }

    /// Reads a response to its end; returns the rows affected.
    package ulong readExecResponse() @safe
    {
        ulong affected;
        ColumnInfo[] columns;
        ubyte[] scratch;
        ValueRef[] values;
        guarded({
            for (;;)
            {
                Done done;
                final switch (nextEvent(done))
                {
                case Event.metadata:
                    columns = readColumnMetadata(reader);
                    break;
                case Event.row:
                    readRow(columns, false, scratch, values);
                    break;
                case Event.nbcRow:
                    readRow(columns, true, scratch, values);
                    break;
                case Event.done:
                    if (done.hasCount && done.command != selectCommand && done.token != TokenType.doneProc)
                        affected += done.rowCount;
                    if (finishIfFinal(done))
                        return;
                    break;
                }
            }
        });
        return affected;
    }

    /++
    Runs a query and returns its rows: the rows of the first result set of the
    batch. The connection stays busy until all rows are read or the result is
    closed; later result sets are read and discarded then.

    Throws: `ServerException` if the query failed (at once, or while reading
    when the error comes after some rows).
    +/
    QueryResult query(string sql) @safe
    {
        sendBatch(sql);
        return new QueryResult(this);
    }

    /++
    Runs a query with parameters (see `exec` for the placeholders and types)
    and returns its rows, as `query(sql)` does. Output parameters
    (`Parameter.output`) are in the result's `outputs` once all its rows are read.

    Throws: as `exec`.
    +/
    QueryResult query(Args...)(string sql, Args args) if (Args.length > 0)
    {
        return queryParams(sql, parameters(args));
    }

    private QueryResult queryParams(string sql, const Parameter[] params) @safe
    {
        sendExecuteSql(sql, params);
        return new QueryResult(this);
    }

    /++
    Calls the stored procedure `name` with `args`: values for its parameters
    in order, or `Parameter`s (`Parameter.of(v).named("@x")` for a named
    parameter, `Parameter.output`/`outputOf` for an `OUTPUT` parameter), or
    one `Parameter[]` with all of them.

    Returns: the rows of the procedure's first result set; once they are all
    read (or the result is closed), its `outputs` and `returnStatus`.
    Throws: `ServerException` if the procedure failed.
    +/
    QueryResult callProcedure(Args...)(string name, Args args)
    {
        return callParams(name, parameters(args));
    }

    private QueryResult callParams(string name, const Parameter[] params) @safe
    {
        if (name.length == 0)
            throw new ClientException("No procedure name");
        sendRpc(name, 0, params);
        return new QueryResult(this);
    }

    /++
    Prepares `sql` (with `?` placeholders) for repeated execution: the server
    compiles it once (`sp_prepexec` on the first execution, `sp_execute`
    afterwards).
    +/
    PreparedStatement prepare(string sql) @safe
    {
        checkOpen();
        return new PreparedStatement(this, sql);
    }

    /// Checks that the server answers.
    void ping() @safe
    {
        exec("SELECT 1");
    }

    /// Closes the connection. Calling it again does nothing.
    void close() @safe nothrow
    {
        if (state == State.closed)
            return;
        state = State.closed;
        if (transport !is null)
            transport.close();
    }

    // --- responses ---

    package enum Event
    {
        metadata, /// COLMETADATA follows: read it with readColumnMetadata
        row, /// ROW follows
        nbcRow, /// NBCROW follows
        done, /// a DONE token was read
    }

    package enum ushort selectCommand = 0xC1;

    /++
    Reads tokens up to the next result set event, handling the others
    (messages, environment changes, ...). Errors are collected.
    +/
    package Event nextEvent(out Done done) @safe
    {
        for (;;)
        {
            const token = reader.readFixed!ubyte();
            switch (token)
            {
            case TokenType.colMetadata:
                return Event.metadata;
            case TokenType.row:
                return Event.row;
            case TokenType.nbcRow:
                return Event.nbcRow;
            case TokenType.done:
            case TokenType.doneProc:
            case TokenType.doneInProc:
                done = readDone(reader, cast(TokenType) token);
                return Event.done;
            case TokenType.error:
                errors ~= readMessage(reader);
                break;
            case TokenType.info:
                const message = readMessage(reader);
                if (onMessage !is null)
                    onMessage(message);
                break;
            case TokenType.envChange:
                applyEnvChange(readEnvChange(reader));
                break;
            case TokenType.loginAck:
                ack = readLoginAck(reader);
                break;
            case TokenType.featureExtAck:
                skipFeatureExtAck(reader);
                break;
            case TokenType.returnStatus:
                responseStatus = reader.readFixed!int();
                responseHasStatus = statusWanted;
                break;
            case TokenType.returnValue:
                responseOutputs ~= readReturnValue(reader, options.maxValueLength);
                break;
            case TokenType.order:
            case TokenType.tabName:
            case TokenType.colInfo:
            case TokenType.sspi:
                readShortToken(reader);
                break;
            case TokenType.sessionState:
                reader.readExactBytes(reader.readFixed!uint());
                break;
            default:
                throw new ProtocolException("Unexpected token 0x" ~ hexByte(token) ~ " in the server's response");
            }
        }
    }

    /++
    After a DONE: if it ends the response, makes the connection ready and
    throws the collected errors. Returns whether it ended the response.
    +/
    package bool finishIfFinal(const ref Done done) @safe
    {
        if (done.more || done.token == TokenType.doneInProc)
            return false;
        if (!packets.messageEnded)
            throw new ProtocolException("The server's response continues after its last DONE token");
        state = State.ready;
        if (errors.length)
        {
            auto e = errors;
            errors = null;
            foreach (m; e)
                if (m.severity >= 20)
                    close(); // the server closes the connection after fatal errors
            throw new ServerException(e);
        }
        return true;
    }

    /// Reads a ROW or NBCROW (after its token byte) of `columns` into `data`/`values`.
    package void readRow(const ColumnInfo[] columns, bool nullBitmap, ref ubyte[] data, ref ValueRef[] values) @safe
    {
        if (values.length != columns.length)
            values = new ValueRef[columns.length];
        data.length = 0;
        (() @trusted => data.assumeSafeAppend())(); // the previous row's bytes are no longer referenced
        ubyte[] bitmap;
        if (nullBitmap)
            bitmap = reader.readExactBytes((columns.length + 7) / 8).dup;
        foreach (i, ref c; columns)
        {
            if (nullBitmap && (bitmap[i / 8] & (1 << (i % 8))) != 0)
                values[i] = ValueRef.init; // NULL: no data in the row
            else
                values[i] = readValue(reader, c.type, data, options.maxValueLength);
        }
    }

    /++
    Runs `action`. A `ServerException` leaves the connection usable (the
    response was read to its end); any other exception means the stream is in
    an unknown state, so the connection is closed.
    +/
    package void guarded(scope void delegate() @safe action) @safe
    {
        try
            action();
        catch (ServerException e)
            throw e;
        catch (Exception e)
        {
            close();
            throw e;
        }
    }

    // --- requests ---

    private void sendBatch(string sql) @safe
    {
        checkReady();
        state = State.busy;
        guarded({
            writer.begin(PacketType.sqlBatch);
            putAllHeaders();
            writer.put(encodeUtf16le(sql));
            writer.end();
            statusWanted = false;
            beginResponse();
        });
    }

    private void sendExecuteSql(string sql, const Parameter[] params) @safe
    {
        import std.conv : to;

        size_t count;
        const text = rewritePlaceholders(sql, count);
        if (count != params.length)
            throw new ClientException("The statement has " ~ count.to!string ~ " placeholders but "
                    ~ params.length.to!string ~ " arguments were given");
        if (params.length == 0)
            return sendBatch(sql);
        auto values = numbered(params);
        sendRpc(null, ProcId.executeSql, [
            Parameter.of(text), Parameter.of(declarations(values))
        ] ~ values);
    }

    /// Sends an RPC request: procedure `name`, or system procedure `id` when `name` is empty.
    package void sendRpc(string name, ushort id, const Parameter[] params) @safe
    {
        checkReady();
        state = State.busy;
        guarded({
            writer.begin(PacketType.rpc);
            putAllHeaders();
            putProcedure(writer, name, id);
            statusWanted = name.length != 0;
            foreach (ref p; params)
                putParameter(writer, p, defaultCollation);
            writer.end();
            beginResponse();
        });
    }

    /// Starts reading a response: per-response state is reset.
    private void beginResponse() @safe
    {
        packets.beginMessage();
        responseOutputs = null;
        responseHasStatus = false;
        responseStatus = 0;
    }

    /// ALL_HEADERS with the transaction descriptor header ([MS-TDS] 2.2.5.3).
    private void putAllHeaders() @safe
    {
        writer.putLE!uint(22); // total length
        writer.putLE!uint(18); // header length
        writer.putLE!ushort(2); // transaction descriptor
        writer.putLE!ulong(transactionDescriptor);
        writer.putLE!uint(1); // outstanding requests
    }

    package void checkOpen() const @safe
    {
        if (state == State.closed)
            throw new ClientException("The connection is closed");
    }

    package void checkReady() const @safe
    {
        if (state == State.closed)
            throw new ClientException("The connection is closed");
        if (state == State.busy)
            throw new ClientException("The connection is busy: read or close the previous query result first");
    }

    private void applyEnvChange(const EnvChange e) @safe
    {
        import std.conv : ConvException, to;

        switch (e.type)
        {
        case EnvChangeType.database:
            currentDatabase = e.newValue;
            break;
        case EnvChangeType.language:
            currentLanguage = e.newValue;
            break;
        case EnvChangeType.packetSize:
            try
                negotiatedPacketSize = e.newValue.to!uint;
            catch (ConvException)
                throw new ProtocolException("Invalid packet size from the server: " ~ e.newValue);
            break;
        case EnvChangeType.collation:
            if (e.newBytes.length == 5)
                defaultCollation = Collation.fromBytes(e.newBytes);
            break;
        case EnvChangeType.beginTransaction:
            transactionDescriptor = descriptor(e.newBytes);
            break;
        case EnvChangeType.commitTransaction:
        case EnvChangeType.rollbackTransaction:
        case EnvChangeType.transactionEnded:
            transactionDescriptor = 0;
            break;
        case EnvChangeType.routing:
        case EnvChangeType.enhancedRouting:
            throw new ClientException(
                    "The server redirects the connection to another server, "
                    ~ "which is not supported yet");
        default:
            break;
        }
    }

    private static ulong descriptor(scope const(ubyte)[] bytes) @safe
    {
        if (bytes.length != 8)
            throw new ProtocolException("Invalid transaction descriptor");
        ulong v;
        foreach_reverse (b; bytes)
            v = (v << 8) | b;
        return v;
    }

    // --- connecting ---

    private void connect() @safe
    {
        backend = backendFor(options.ioMode);
        auto hosts = options.hosts.length ? options.hosts.dup : [
            HostPort(options.host, options.port)
        ];
        foreach (ref h; hosts)
            h.port = ConnectionOptions.effectivePort(h.port);

        void tryHost(HostPort endpoint) @safe
        {
            connectTo(endpoint);
        }

        connectFirst(orderHosts(hosts, options.hostSelection), &tryHost, "SQL Server");
    }

    private void connectTo(HostPort endpoint) @safe
    {
        import mssql : mssqlVersionMajor, mssqlVersionMinor, mssqlVersionPatch;

        auto raw = options.transportFactory !is null
            ? options.transportFactory(endpoint.host, endpoint.port, options.connectTimeout) : backend.connect(
                    endpoint.host, endpoint.port, options.connectTimeout);
        transport = raw;
        state = State.busy;
        errors = null;
        transactionDescriptor = 0;
        scope (failure)
            close();
        raw.setTimeouts(options.connectTimeout, options.connectTimeout);
        writer = new PacketWriter(raw);
        packets = new PacketReader(raw);
        reader = new BufferedReader(packets);

        // PRELOGIN: agree on encryption
        const clientEncryption = options.encrypt ? Encryption.on : Encryption.off;
        writer.message(PacketType.prelogin, buildPrelogin(clientEncryption, [
            mssqlVersionMajor, mssqlVersionMinor, mssqlVersionPatch
        ]));
        packets.beginMessage();
        const response = parsePrelogin(readWholeMessage());
        const mode = agreeEncryption(clientEncryption, response.encryption);

        // TLS: the handshake inside PRELOGIN packets, then TLS records directly over TCP
        TlsTransport tls;
        if (mode != EncryptionMode.none)
        {
            TlsOptions tlsOptions = options.tls;
            // Login-only encryption only keeps the password off the wire; like other drivers,
            // it doesn't verify the certificate (servers often have a self-signed one for it)
            tlsOptions.skipVerify = tlsOptions.skipVerify || options.trustServerCertificate
                || mode == EncryptionMode.loginOnly;
            tlsOptions.maxVersion = TlsVersion.tls12; // TDS 7.x handshakes are TLS 1.2
            if (tlsOptions.minVersion > tlsOptions.maxVersion)
                tlsOptions.minVersion = TlsVersion.tls12;
            tls = new TlsTransport(raw, backend, TlsContext.client(tlsOptions), endpoint.host, tlsOptions,
                    options.connectTimeout, new PreloginTlsFraming(raw, defaultPacketSize));
            transport = tls;
            writer.transport = tls;
        }

        // LOGIN7
        Login7 login;
        login.packetSize = options.packetSize;
        login.clientProgVersion = (mssqlVersionMajor << 24) | (mssqlVersionMinor << 16) | mssqlVersionPatch;
        login.clientPid = processId();
        login.hostName = options.workstation.length ? options.workstation : machineName();
        login.userName = options.user;
        login.password = options.password;
        login.appName = options.appName;
        login.serverName = endpoint.host;
        login.libraryName = "mssql-native";
        login.language = options.language;
        login.database = options.database;
        login.readOnlyIntent = options.readOnlyIntent;
        writer.message(PacketType.login7, buildLogin7(login));
        if (mode == EncryptionMode.loginOnly)
        {
            transport = tls.detach(); // only the login packet is encrypted
            writer.transport = transport;
        }
        packets.transport = transport;
        reader = new BufferedReader(packets);

        // The login response: LOGINACK (or ERROR), environment changes, DONE
        packets.beginMessage();
        ack = LoginAck.init;
        for (;;)
        {
            Done done;
            const event = nextEvent(done);
            if (event != Event.done)
                throw new ProtocolException("Unexpected result set in the login response");
            if (done.more || done.token == TokenType.doneInProc)
                continue;
            if (errors.length)
            {
                auto e = errors;
                errors = null;
                throw new ServerException(e);
            }
            if (ack.tdsVersion == 0)
                throw new ProtocolException("The server did not acknowledge the login");
            break;
        }
        if (negotiatedPacketSize != writer.packetSize)
            writer.packetSize = negotiatedPacketSize; // from the next message on
        transport.setTimeouts(options.receiveTimeout, options.sendTimeout);
        connectedHost = endpoint;
        state = State.ready;
    }

    /// Reads the rest of the current message (PRELOGIN response).
    private ubyte[] readWholeMessage() @safe
    {
        ubyte[] data;
        ubyte[1024] buffer;
        do
        {
            const n = packets.read(buffer[]);
            data ~= buffer[0 .. n];
            if (data.length > 64 * 1024)
                throw new ProtocolException("PRELOGIN response too long");
        }
        while (!packets.messageEnded);
        return data;
    }
}

private uint processId() @trusted nothrow
{
    import std.process : thisProcessID;

    return cast(uint) thisProcessID; // reads the process id
}

private string machineName() @safe nothrow
{
    try
    {
        import std.socket : Socket;

        return Socket.hostName;
    }
    catch (Exception)
        return "";
}

private string hexByte(ubyte b) @safe pure nothrow
{
    static immutable digits = "0123456789ABCDEF";
    return [digits[b >> 4], digits[b & 15]];
}

version (unittest)
{
    import core.time : Duration;
    import dbwire.io.mock : MockTransport;

    /// Packs a server message as one tabular result packet.
    private ubyte[] serverMessage(scope const(ubyte)[] data) @safe pure
    {
        const length = data.length + 8;
        ubyte[] packet = [4, 1, cast(ubyte)(length >> 8), cast(ubyte) length, 0, 0, 1, 0];
        return packet ~ data;
    }

    // Responses captured from SQL Server 2022 (16.0.4305): the login response, the response to
    // SELECT 1 AS a, N'xй' AS b, CAST(NULL AS int) AS c, CAST(1 AS bit) AS d, CAST(5 AS bigint) AS e,
    // CAST(NULL AS nvarchar(10)) AS f, CAST(7 AS smallint) AS g, CAST(200 AS tinyint) AS h,
    // and the response to "SELEC 1" (error 2812)
    private immutable ubyte[] capturedLogin = [
        0xE3, 0x1B, 0x00, 0x01, 0x06, 0x6D, 0x00, 0x61, 0x00, 0x73, 0x00, 0x74, 0x00, 0x65, 0x00, 0x72,
        0x00, 0x06, 0x6D, 0x00, 0x61, 0x00, 0x73, 0x00, 0x74, 0x00, 0x65, 0x00, 0x72, 0x00, 0xAB, 0x70,
        0x00, 0x45, 0x16, 0x00, 0x00, 0x02, 0x00, 0x25, 0x00, 0x43, 0x00, 0x68, 0x00, 0x61, 0x00, 0x6E,
        0x00, 0x67, 0x00, 0x65, 0x00, 0x64, 0x00, 0x20, 0x00, 0x64, 0x00, 0x61, 0x00, 0x74, 0x00, 0x61,
        0x00, 0x62, 0x00, 0x61, 0x00, 0x73, 0x00, 0x65, 0x00, 0x20, 0x00, 0x63, 0x00, 0x6F, 0x00, 0x6E,
        0x00, 0x74, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00, 0x20, 0x00, 0x74, 0x00, 0x6F, 0x00, 0x20,
        0x00, 0x27, 0x00, 0x6D, 0x00, 0x61, 0x00, 0x73, 0x00, 0x74, 0x00, 0x65, 0x00, 0x72, 0x00, 0x27,
        0x00, 0x2E, 0x00, 0x0C, 0x32, 0x00, 0x62, 0x00, 0x66, 0x00, 0x34, 0x00, 0x64, 0x00, 0x39, 0x00,
        0x32, 0x00, 0x65, 0x00, 0x35, 0x00, 0x65, 0x00, 0x66, 0x00, 0x63, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0xE3, 0x08, 0x00, 0x07, 0x05, 0x09, 0x04, 0xD0, 0x00, 0x34, 0x00, 0xE3, 0x17, 0x00, 0x02,
        0x0A, 0x75, 0x00, 0x73, 0x00, 0x5F, 0x00, 0x65, 0x00, 0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x69,
        0x00, 0x73, 0x00, 0x68, 0x00, 0x00, 0xAB, 0x74, 0x00, 0x47, 0x16, 0x00, 0x00, 0x01, 0x00, 0x27,
        0x00, 0x43, 0x00, 0x68, 0x00, 0x61, 0x00, 0x6E, 0x00, 0x67, 0x00, 0x65, 0x00, 0x64, 0x00, 0x20,
        0x00, 0x6C, 0x00, 0x61, 0x00, 0x6E, 0x00, 0x67, 0x00, 0x75, 0x00, 0x61, 0x00, 0x67, 0x00, 0x65,
        0x00, 0x20, 0x00, 0x73, 0x00, 0x65, 0x00, 0x74, 0x00, 0x74, 0x00, 0x69, 0x00, 0x6E, 0x00, 0x67,
        0x00, 0x20, 0x00, 0x74, 0x00, 0x6F, 0x00, 0x20, 0x00, 0x75, 0x00, 0x73, 0x00, 0x5F, 0x00, 0x65,
        0x00, 0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x69, 0x00, 0x73, 0x00, 0x68, 0x00, 0x2E, 0x00, 0x0C,
        0x32, 0x00, 0x62, 0x00, 0x66, 0x00, 0x34, 0x00, 0x64, 0x00, 0x39, 0x00, 0x32, 0x00, 0x65, 0x00,
        0x35, 0x00, 0x65, 0x00, 0x66, 0x00, 0x63, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xAD, 0x36, 0x00,
        0x01, 0x74, 0x00, 0x00, 0x04, 0x16, 0x4D, 0x00, 0x69, 0x00, 0x63, 0x00, 0x72, 0x00, 0x6F, 0x00,
        0x73, 0x00, 0x6F, 0x00, 0x66, 0x00, 0x74, 0x00, 0x20, 0x00, 0x53, 0x00, 0x51, 0x00, 0x4C, 0x00,
        0x20, 0x00, 0x53, 0x00, 0x65, 0x00, 0x72, 0x00, 0x76, 0x00, 0x65, 0x00, 0x72, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x00, 0x10, 0xD1, 0xE3, 0x13, 0x00, 0x04, 0x04, 0x34, 0x00, 0x30, 0x00, 0x39,
        0x00, 0x36, 0x00, 0x04, 0x34, 0x00, 0x30, 0x00, 0x39, 0x00, 0x36, 0x00, 0xFD, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ];
    private immutable ubyte[] capturedQuery = [
        0x81, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x38, 0x01, 0x61, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x20, 0x00, 0xE7, 0x04, 0x00, 0x09, 0x04, 0xD0, 0x00, 0x34, 0x01, 0x62, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x21, 0x00, 0x26, 0x04, 0x01, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x68,
        0x01, 0x01, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x26, 0x08, 0x01, 0x65, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x21, 0x00, 0xE7, 0x14, 0x00, 0x09, 0x04, 0xD0, 0x00, 0x34, 0x01, 0x66, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x26, 0x02, 0x01, 0x67, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21,
        0x00, 0x26, 0x01, 0x01, 0x68, 0x00, 0xD2, 0x24, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x78, 0x00,
        0x39, 0x04, 0x01, 0x01, 0x08, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x07, 0x00,
        0x01, 0xC8, 0xFD, 0x10, 0x00, 0xC1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ];
    private immutable ubyte[] capturedError = [
        0xAA, 0x76, 0x00, 0xFC, 0x0A, 0x00, 0x00, 0x3E, 0x10, 0x28, 0x00, 0x43, 0x00, 0x6F, 0x00, 0x75,
        0x00, 0x6C, 0x00, 0x64, 0x00, 0x20, 0x00, 0x6E, 0x00, 0x6F, 0x00, 0x74, 0x00, 0x20, 0x00, 0x66,
        0x00, 0x69, 0x00, 0x6E, 0x00, 0x64, 0x00, 0x20, 0x00, 0x73, 0x00, 0x74, 0x00, 0x6F, 0x00, 0x72,
        0x00, 0x65, 0x00, 0x64, 0x00, 0x20, 0x00, 0x70, 0x00, 0x72, 0x00, 0x6F, 0x00, 0x63, 0x00, 0x65,
        0x00, 0x64, 0x00, 0x75, 0x00, 0x72, 0x00, 0x65, 0x00, 0x20, 0x00, 0x27, 0x00, 0x53, 0x00, 0x45,
        0x00, 0x4C, 0x00, 0x45, 0x00, 0x43, 0x00, 0x27, 0x00, 0x2E, 0x00, 0x0C, 0x32, 0x00, 0x62, 0x00,
        0x66, 0x00, 0x34, 0x00, 0x64, 0x00, 0x39, 0x00, 0x32, 0x00, 0x65, 0x00, 0x35, 0x00, 0x65, 0x00,
        0x66, 0x00, 0x63, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFE, 0x02, 0x00, 0xE0, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ];

    /// The PRELOGIN response of the same server, but with ENCRYPTION = not supported (no TLS)
    private immutable ubyte[] preloginNoTls = [
        0x00, 0x00, 0x0B, 0x00, 0x06, 0x01, 0x00, 0x11, 0x00, 0x01, 0xFF, 0x10, 0x00, 0x10, 0xD1, 0x00,
        0x00, 0x02
    ];
}

// A whole session against replayed server responses: connect without TLS, a query, an error
@safe unittest
{
    import std.exception : collectException;

    auto server = new MockTransport;
    server.feed(serverMessage(preloginNoTls));
    server.feed(serverMessage(capturedLogin));
    server.feed(serverMessage(capturedQuery));
    server.feed(serverMessage(capturedError));

    ConnectionOptions options;
    options.user = "sa";
    options.password = "secret";
    options.encrypt = false;
    Transport factory(string, ushort, Duration)
    {
        return server;
    }

    options.transportFactory = &factory;
    auto conn = new Connection(options);
    assert(conn.serverVersion == "16.0.4305" && conn.tdsVersion == 0x74000004);
    assert(conn.database == "master" && conn.language == "us_english" && conn.packetSize == 4096);
    assert(conn.collation.sortId == 52);

    // what the client sent: PRELOGIN, then LOGIN7 (no TLS: the server doesn't support it)
    assert(server.written[0] == PacketType.prelogin && server.written[1] == 0x01);
    const loginStart = (server.written[2] << 8) | server.written[3];
    assert(server.written[loginStart] == PacketType.login7);

    auto result = conn.query("SELECT 1 AS a, ...");
    assert(conn.isBusy && result.columns.length == 8 && result.columns[1].name == "b");
    assert(!result.empty);
    assert(result.getLong(0) == 1 && result.getString(1) == "xй" && result.isNull(2) && result.getString(2) is null);
    assert(result.getBool(3) && result.getLong(4) == 5 && result.isNull(5) && result.getInt(6) == 7);
    assert(result.getLong(7) == 200);
    result.popFront();
    assert(result.empty && result.rowCount == 1 && !conn.isBusy);

    // the batch went out with ALL_HEADERS (transaction descriptor 0, one request)
    const batchStart = loginStart + ((server.written[loginStart + 2] << 8) | server.written[loginStart + 3]);
    assert(server.written[batchStart] == PacketType.sqlBatch);
    assert(server.written[batchStart + 8 .. batchStart + 30] == [
        22, 0, 0, 0, 18, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0
    ]);

    const e = collectException!ServerException(conn.exec("SELEC 1"));
    assert(e !is null && e.number == 2812 && e.severity == 16 && conn.isOpen && !conn.isBusy);
}

// A failed login is a ServerException; a malformed response closes the connection
@safe unittest
{
    import std.exception : assertThrown, collectException;
    import dbwire.charset.utf16 : encodeUtf16le;

    ubyte[] loginFailed;
    const text = encodeUtf16le("Login failed for user 'sa'.");
    ubyte[] body = [0x18, 0x48, 0, 0, 1, 14, cast(ubyte)(text.length / 2), 0]; // Msg 18456, state 1, level 14
    body ~= text;
    body ~= [0, 0, 1, 0, 0, 0];
    loginFailed ~= [0xAA, cast(ubyte)
        body.length, 0];
    loginFailed ~= body;
    loginFailed ~= [0xFD, 0x02, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

    auto server = new MockTransport;
    server.feed(serverMessage(preloginNoTls));
    server.feed(serverMessage(loginFailed));
    ConnectionOptions options;
    options.encrypt = false;
    Transport factory(string, ushort, Duration)
    {
        return server;
    }

    options.transportFactory = &factory;
    const e = collectException!ServerException(new Connection(options));
    assert(e !is null && e.number == 18_456 && !server.connected);

    server = new MockTransport;
    server.feed(serverMessage(preloginNoTls));
    server.feed(serverMessage(capturedLogin));
    server.feed(serverMessage([0x81, 0x01])); // a truncated COLMETADATA
    auto conn = new Connection(options);
    assertThrown!ProtocolException(conn.query("SELECT 1"));
    assert(!conn.isOpen);
}
