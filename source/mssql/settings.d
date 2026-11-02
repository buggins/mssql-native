/++
Connection options, and parsing them from a connection string (DSN).

A DSN looks like
`sqlserver://user:password@host1:1433,host2/database?trust_server_certificate=true`.
See `ConnectionOptions.fromDsn` for the parameters.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.settings;

import core.time : Duration, seconds;

import dbwire.client.dsn : Dsn, parseEnumValue, parseFlag, parseSeconds;
import dbwire.io.backend : IoMode;
import dbwire.io.transport : TransportFactory;
import dbwire.tls.transport : TlsOptions;
import mssql.exception : ClientException;
import mssql.protocol.packet : defaultPacketSize, maxPacketSize, minPacketSize;

public import dbwire.client.hosts : HostPort, HostSelection;

/// SQL Server's default TCP port.
enum ushort defaultPort = 1433;

/// Options for opening a `mssql.connection.Connection`.
struct ConnectionOptions
{
    /// Server host name or IP address. Ignored when `hosts` is set.
    string host = "localhost";
    /// Server TCP port; 0 means 1433. Ignored when `hosts` is set.
    ushort port;
    /++
    Several servers (e.g. failover partners). Connecting tries them as
    `hostSelection` says and uses the first one that answers; a server that
    refuses the login is not skipped. When empty, `host` and `port` are used.
    +/
    HostPort[] hosts;
    /// Order in which `hosts` are tried.
    HostSelection hostSelection = HostSelection.inOrder;
    /// SQL Server login name.
    string user;
    /// Password.
    string password;
    /// Initial database; empty: the login's default database.
    string database;
    /// Application name, shown in `sys.dm_exec_sessions`.
    string appName = "mssql-native";
    /// Client machine name, shown in `sys.dm_exec_sessions`; empty: this machine's name.
    string workstation;
    /// Initial language (e.g. "us_english"); empty: the login's default.
    string language;
    /// Ask for a read-only replica (`ApplicationIntent=ReadOnly`).
    bool readOnlyIntent;

    /++
    Encrypt the connection (TLS). On by default: the server must support it,
    and its certificate is verified unless `trustServerCertificate` is set.
    When off, the login packet is still encrypted if the server can (without
    verifying its certificate, like other drivers), and the whole connection
    if the server requires it (verified unless `trustServerCertificate`).
    OpenSSL is loaded when the first encrypted connection is made.
    +/
    bool encrypt = true;
    /// Don't verify the server certificate (`TrustServerCertificate=yes`): for development
    /// servers with self-signed certificates.
    bool trustServerCertificate;
    /// More TLS settings: trusted CAs (`caFile`), the name to verify (`serverName`,
    /// `HostNameInCertificate`), client certificates.
    TlsOptions tls;

    /// Maximum time to establish the TCP connection, the TLS handshake and the login.
    Duration connectTimeout = 15.seconds;
    /// Maximum time a single socket write may block; `Duration.zero`: no limit.
    Duration sendTimeout = 300.seconds;
    /++
    Maximum time to wait for the next data from the server; `Duration.zero`
    (the default): no limit. SQL Server sends nothing while a query runs, so
    this limits the query time.
    +/
    Duration receiveTimeout;

    /// Requested packet size (512 to 32767); the server may answer with another one.
    uint packetSize = defaultPacketSize;
    /// Largest value (string, binary) accepted from the server, in bytes.
    size_t maxValueLength = 1024 * 1024 * 1024;

    /// I/O backend selection.
    IoMode ioMode = IoMode.auto_;
    /// Custom transport factory; overrides the backend's connect logic when set.
    TransportFactory transportFactory;

    /++
    Parses a connection string:
    `sqlserver://[user[:password]@]host[:port][,host[:port]...][/database][?param=value&...]`.

    User, password and values may be percent-encoded; IPv6 addresses go in
    brackets. Parameters are those of `fromParams`.

    Throws: `ClientException` if the string is malformed or a parameter is
    unknown or invalid.
    +/
    static ConnectionOptions fromDsn(string dsn) @safe
    {
        const parsed = Dsn.parse(dsn, "sqlserver");
        string[string] params;
        foreach (key, value; parsed.params)
            params[key] = value;
        if (parsed.hasUser)
            params["user"] = parsed.user;
        if (parsed.hasPassword)
            params["password"] = parsed.password;
        if (parsed.path.length)
            params["database"] = parsed.path;
        auto options = fromParams(params);
        options.hosts = parsed.hosts.dup;
        if (options.hosts.length == 1)
        {
            options.host = options.hosts[0].host;
            options.port = options.hosts[0].port;
        }
        return options;
    }

    ///
    @safe unittest
    {
        const o = ConnectionOptions.fromDsn(
                "sqlserver://sa:s%40cret@db1:1433,db2/sales?trust_server_certificate=true&app_name=report");
        assert(o.user == "sa" && o.password == "s@cret" && o.database == "sales");
        assert(o.hosts == [HostPort("db1", 1433), HostPort("db2")]); // db2: the default port
        assert(o.encrypt && o.trustServerCertificate && o.appName == "report");
    }

    /++
    Builds options from name/value pairs, e.g. the parameters of a ddbc URL.

    Keys: `host`, `port`, `user`, `password`, `database`, `app_name`,
    `workstation`, `language`, `read_only` (true/false), `encrypt` (true/false),
    `trust_server_certificate`, `host_name_in_certificate`, `tls_ca_file`,
    `tls_cert_file`, `tls_key_file`, `connect_timeout`, `send_timeout`,
    `receive_timeout` (seconds, may be fractional), `packet_size`,
    `io` (`auto`, `phobos`, `vibe`), `host_selection` (`in_order`, `random`).
    `pool_*` keys are for the pool and ignored here.

    Throws: `ClientException` for an unknown key or an invalid value.
    +/
    static ConnectionOptions fromParams(const string[string] params) @safe
    {
        import std.algorithm.searching : startsWith;
        import std.conv : ConvException, to;

        ConnectionOptions options;
        foreach (key, value; params)
        {
            T parse(T)()
            {
                try
                    return value.to!T;
                catch (ConvException)
                    throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "'");
            }

            switch (key)
            {
            case "host":
                options.host = value;
                break;
            case "port":
                options.port = parse!ushort;
                break;
            case "user":
                options.user = value;
                break;
            case "password":
                options.password = value;
                break;
            case "database":
                options.database = value;
                break;
            case "app_name":
                options.appName = value;
                break;
            case "workstation":
                options.workstation = value;
                break;
            case "language":
                options.language = value;
                break;
            case "read_only":
                options.readOnlyIntent = parseFlag(key, value);
                break;
            case "encrypt":
                options.encrypt = parseFlag(key, value);
                break;
            case "trust_server_certificate":
                options.trustServerCertificate = parseFlag(key, value);
                break;
            case "host_name_in_certificate":
                options.tls.serverName = value;
                break;
            case "tls_ca_file":
                options.tls.caFile = value;
                break;
            case "tls_cert_file":
                options.tls.certFile = value;
                break;
            case "tls_key_file":
                options.tls.keyFile = value;
                break;
            case "connect_timeout":
                options.connectTimeout = parseSeconds(key, value);
                break;
            case "send_timeout":
                options.sendTimeout = parseSeconds(key, value);
                break;
            case "receive_timeout":
                options.receiveTimeout = parseSeconds(key, value);
                break;
            case "packet_size":
                options.packetSize = parse!uint;
                if (options.packetSize < minPacketSize || options.packetSize > maxPacketSize)
                    throw new ClientException("'packet_size' must be from 512 to 32767");
                break;
            case "io":
                options.ioMode = value == "auto" ? IoMode.auto_ : parseEnumValue!IoMode(key, value);
                break;
            case "host_selection":
                options.hostSelection = value == "in_order" ? HostSelection.inOrder
                    : parseEnumValue!HostSelection(key, value);
                break;
            default:
                if (!key.startsWith("pool_"))
                    throw new ClientException("Unknown connection parameter '" ~ key ~ "'");
            }
        }
        return options;
    }

    /// The port to connect to for `p`: itself, or 1433 when it is 0.
    static ushort effectivePort(ushort p) @safe pure nothrow @nogc
    {
        return p != 0 ? p : defaultPort;
    }
}

@safe unittest
{
    import core.time : msecs;
    import std.exception : assertThrown;

    auto o = ConnectionOptions.fromDsn("sqlserver://localhost");
    assert(o.host == "localhost" && o.port == 0 && ConnectionOptions.effectivePort(o.port) == 1433);
    assert(o.encrypt && !o.trustServerCertificate && o.database == "");

    o = ConnectionOptions.fromDsn("sqlserver://[::1]:14330/?encrypt=false&connect_timeout=2.5&packet_size=8000"
            ~ "&io=phobos&host_selection=random&read_only=1&host_name_in_certificate=db.example&pool_max=3");
    assert(o.hosts == [HostPort("::1", 14_330)] && !o.encrypt && o.connectTimeout == 2500.msecs);
    assert(o.packetSize == 8000 && o.ioMode == IoMode.phobos && o.hostSelection == HostSelection.random);
    assert(o.readOnlyIntent && o.tls.serverName == "db.example");

    foreach (bad; [
        "mysql://h", "sqlserver://", "sqlserver://h?encrypt=yes", "sqlserver://h?packet_size=100",
        "sqlserver://h?unknown=1", "sqlserver://h:x", "sqlserver://h?io=threads"
    ])
        assertThrown!ClientException(ConnectionOptions.fromDsn(bad), bad);
}
