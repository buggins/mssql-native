/++
Connection options, and parsing them from a connection string in either of
two forms:

$(UL
$(LI URL style (DSN):
    `sqlserver://user:password@host1:1433,host2/database?trust_server_certificate=true`;
    see `ConnectionOptions.fromDsn` for the parameters;)
$(LI ADO style, as .NET and ODBC use:
    `Server=tcp:db,1433;Database=sales;User Id=app;Password=secret;TrustServerCertificate=True`;
    see `ConnectionOptions.fromAdo`.)
)

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

    /++
    Time limit for each step of connecting: the TCP connection, the TLS
    handshake, and each wait for the server's answer during the login (not
    for the whole connect). `Duration.zero` (`connect_timeout=0`, or
    `Connect Timeout=0` in an ADO.NET connection string): no limit.
    +/
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

    /++
    Parses an ADO-style connection string (`key=value` pairs separated by `;`,
    keys case-insensitive; values may be quoted with `"`, `'` or `{}`).

    $(TABLE
    $(TR $(TH Keys) $(TH Meaning))
    $(TR $(TD `Server`, `Data Source`, `Address`, `Addr`, `Network Address`)
        $(TD `host`, `host,port` or `tcp:host,port`; `.` and `(local)` are localhost.
        Named instances (`host\instance`) need the port given instead.))
    $(TR $(TD `Failover Partner`) $(TD a second host, tried after the first))
    $(TR $(TD `Database`, `Initial Catalog`) $(TD the database))
    $(TR $(TD `User Id`, `UID`, `User`) $(TD the login))
    $(TR $(TD `Password`, `PWD`) $(TD the password))
    $(TR $(TD `Encrypt`) $(TD `true`/`yes`/`mandatory` or `false`/`no`/`optional`))
    $(TR $(TD `TrustServerCertificate`) $(TD don't verify the certificate))
    $(TR $(TD `HostNameInCertificate`) $(TD the name expected in the certificate))
    $(TR $(TD `Application Name`, `App`) $(TD the application name))
    $(TR $(TD `Workstation ID`, `WSID`) $(TD the client's name))
    $(TR $(TD `Current Language`, `Language`) $(TD the session language))
    $(TR $(TD `Connect Timeout`, `Connection Timeout`, `Timeout`) $(TD seconds))
    $(TR $(TD `Command Timeout`) $(TD the receive timeout, seconds; 0: none))
    $(TR $(TD `Packet Size`) $(TD bytes, 512 to 32767))
    $(TR $(TD `ApplicationIntent`) $(TD `ReadOnly` or `ReadWrite`))
    $(TR $(TD `Max Pool Size`, `Connection Lifetime`) $(TD for `ConnectionPool`))
    )

    `Pooling`, `Min Pool Size`, `Persist Security Info` and
    `MultiSubnetFailover` are accepted and ignored; `Integrated Security`,
    `Trusted_Connection` and `MultipleActiveResultSets` only as false.

    Throws: `ClientException` for unknown keys, invalid values and features
    that are not supported.
    +/
    static ConnectionOptions fromAdo(string connectionString) @safe
    {
        const parsed = parseAdoString(connectionString);
        auto options = fromParams(parsed.params);
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
        const o = ConnectionOptions.fromAdo("Server=tcp:db1,1433; Initial Catalog=sales; User ID=app;"
                ~ "Password='it''s;secret'; TrustServerCertificate=True; Application Name={report};");
        assert(o.host == "db1" && o.port == 1433 && o.database == "sales" && o.user == "app");
        assert(o.password == "it's;secret" && o.trustServerCertificate && o.appName == "report");
    }

    /// A connection string in either form: URL style (`sqlserver://...`) or ADO style (`Server=...;...`).
    static ConnectionOptions parse(string connectionString) @safe
    {
        return isUrlConnectionString(connectionString) ? fromDsn(connectionString) : fromAdo(connectionString);
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
    assert(ConnectionOptions.fromDsn("sqlserver://h/?connect_timeout=0").connectTimeout == Duration.zero);
    assert(o.packetSize == 8000 && o.ioMode == IoMode.phobos && o.hostSelection == HostSelection.random);
    assert(o.readOnlyIntent && o.tls.serverName == "db.example");

    foreach (bad; [
        "mysql://h", "sqlserver://", "sqlserver://h?encrypt=yes", "sqlserver://h?packet_size=100",
        "sqlserver://h?unknown=1", "sqlserver://h:x", "sqlserver://h?io=threads"
    ])
        assertThrown!ClientException(ConnectionOptions.fromDsn(bad), bad);
}

/// Whether `s` is a URL-style connection string (`scheme://...`) rather than ADO style.
bool isUrlConnectionString(string s) @safe pure nothrow
{
    import std.string : indexOf;

    const scheme = s.indexOf("://");
    const equals = s.indexOf('=');
    return scheme > 0 && (equals < 0 || scheme < equals);
}

/// An ADO-style connection string as connection parameters (the names of `fromParams`) and hosts.
struct AdoConnectionString
{
    /// Parameters for `ConnectionOptions.fromParams` and `PoolOptions.fromParams` (`pool_*`).
    string[string] params;
    /// The server, and its failover partner.
    HostPort[] hosts;
}

/++
Splits an ADO-style connection string and maps its keys (see
`ConnectionOptions.fromAdo`).

Throws: `ClientException` for syntax errors, unknown keys and unsupported values.
+/
AdoConnectionString parseAdoString(string connectionString) @safe
{
    import std.string : strip, toLower;

    AdoConnectionString result;
    string server, partner;
    foreach (pair; splitAdo(connectionString))
    {
        const key = normalizeKey(pair[0]);
        const value = pair[1];
        string flag()
        {
            switch (value.toLower)
            {
            case "true":
            case "yes":
                return "true";
            case "false":
            case "no":
                return "false";
            default:
                throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ pair[0]
                        ~ "' (true or false expected)");
            }
        }

        void onlyFalse()
        {
            if (flag() == "true")
                throw new ClientException("'" ~ pair[0] ~ "=" ~ value ~ "' is not supported");
        }

        switch (key)
        {
        case "server":
        case "data source":
        case "address":
        case "addr":
        case "network address":
            server = value;
            break;
        case "failover partner":
            partner = value;
            break;
        case "database":
        case "initial catalog":
            result.params["database"] = value;
            break;
        case "user id":
        case "uid":
        case "user":
            result.params["user"] = value;
            break;
        case "password":
        case "pwd":
            result.params["password"] = value;
            break;
        case "encrypt":
            switch (value.toLower)
            {
            case "mandatory":
                result.params["encrypt"] = "true";
                break;
            case "optional":
                result.params["encrypt"] = "false";
                break;
            case "strict":
                throw new ClientException("'Encrypt=Strict' (TDS 8.0) is not supported yet");
            default:
                result.params["encrypt"] = flag();
            }
            break;
        case "trustservercertificate":
        case "trust server certificate":
            result.params["trust_server_certificate"] = flag();
            break;
        case "hostnameincertificate":
        case "host name in certificate":
            result.params["host_name_in_certificate"] = value;
            break;
        case "application name":
        case "app":
            result.params["app_name"] = value;
            break;
        case "workstation id":
        case "wsid":
            result.params["workstation"] = value;
            break;
        case "current language":
        case "language":
            result.params["language"] = value;
            break;
        case "connect timeout":
        case "connection timeout":
        case "timeout":
            result.params["connect_timeout"] = value;
            break;
        case "command timeout":
            result.params["receive_timeout"] = value;
            break;
        case "packet size":
            result.params["packet_size"] = value;
            break;
        case "applicationintent":
        case "application intent":
            switch (value.toLower)
            {
            case "readonly":
                result.params["read_only"] = "true";
                break;
            case "readwrite":
                result.params["read_only"] = "false";
                break;
            default:
                throw new ClientException(
                        "Invalid value '" ~ value ~ "' for '" ~ pair[0]
                        ~ "' (ReadOnly or ReadWrite expected)");
            }
            break;
        case "max pool size":
            result.params["pool_max"] = value;
            break;
        case "connection lifetime":
        case "load balance timeout":
            result.params["pool_max_lifetime"] = value;
            break;
        case "pooling":
        case "persist security info":
        case "persistsecurityinfo":
        case "multisubnetfailover":
        case "multi subnet failover":
            flag(); // valid, ignored
            break;
        case "min pool size":
            break;
        case "integrated security":
        case "trusted_connection":
            if (value.toLower != "sspi")
                onlyFalse();
            else
                throw new ClientException("'" ~ pair[0] ~ "=" ~ value ~ "' is not supported");
            break;
        case "multipleactiveresultsets":
        case "multiple active result sets":
            onlyFalse();
            break;
        default:
            throw new ClientException("Unknown connection string key '" ~ pair[0] ~ "'");
        }
    }
    if (server.length)
        result.hosts ~= parseServer(server);
    if (partner.length)
        result.hosts ~= parseServer(partner);
    return result;
}

///
@safe unittest
{
    import std.exception : assertThrown;

    auto a = parseAdoString("Data Source=(local);Failover Partner=db2,14330;Max Pool Size=4;Pooling=true");
    assert(a.hosts == [HostPort("localhost"), HostPort("db2", 14_330)] && a.params["pool_max"] == "4");
    assertThrown!ClientException(parseAdoString("Server=db\\SQLEXPRESS")); // a named instance
    assertThrown!ClientException(parseAdoString("Server=db;Integrated Security=SSPI"));
    assertThrown!ClientException(parseAdoString("Server=db;Colour=blue"));
    assert(parseAdoString("Server=db;Integrated Security=false").hosts == [HostPort("db")]);
}

/// The `key=value` pairs of an ADO-style connection string, unquoted.
private string[2][] splitAdo(string s) @safe
{
    import std.string : strip;

    string[2][] pairs;
    size_t i;
    while (i < s.length)
    {
        // key: up to '=' ('==' is a literal '=')
        string key;
        while (i < s.length && s[i] != ';')
        {
            if (s[i] == '=')
            {
                if (i + 1 < s.length && s[i + 1] == '=')
                {
                    key ~= '=';
                    i += 2;
                    continue;
                }
                break;
            }
            key ~= s[i++];
        }
        key = key.strip;
        if (i >= s.length || s[i] == ';')
        {
            if (key.length)
                throw new ClientException("Connection string: no value for '" ~ key ~ "'");
            i++;
            continue;
        }
        i++; // '='
        while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
            i++;
        string value;
        if (i < s.length && (s[i] == '"' || s[i] == '\'' || s[i] == '{'))
        {
            const close = s[i] == '{' ? '}' : s[i];
            i++;
            for (;;)
            {
                if (i >= s.length)
                    throw new ClientException("Connection string: unterminated quoted value for '" ~ key ~ "'");
                if (s[i] == close)
                {
                    if (i + 1 < s.length && s[i + 1] == close) // doubled: a literal quote
                    {
                        value ~= close;
                        i += 2;
                        continue;
                    }
                    i++;
                    break;
                }
                value ~= s[i++];
            }
            while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
                i++;
            if (i < s.length && s[i] != ';')
                throw new ClientException("Connection string: text after the quoted value of '" ~ key ~ "'");
        }
        else
        {
            const start = i;
            while (i < s.length && s[i] != ';')
                i++;
            value = s[start .. i].strip;
        }
        i++; // ';'
        if (key.length == 0)
            throw new ClientException("Connection string: a value without a key");
        pairs ~= [key, value];
    }
    return pairs;
}

/// A key in lower case with runs of spaces made single.
private string normalizeKey(string key) @safe pure
{
    import std.ascii : isWhite, toLower;

    string k;
    bool space;
    foreach (char c; key)
    {
        if (isWhite(c))
        {
            space = k.length > 0;
            continue;
        }
        if (space)
            k ~= ' ';
        space = false;
        k ~= toLower(c);
    }
    return k;
}

/// `host`, `host,port`, `tcp:host,port`; `.`, `(local)` are localhost.
private HostPort parseServer(string server) @safe
{
    import std.algorithm.searching : findSplit, startsWith;
    import std.conv : ConvException, to;
    import std.string : indexOf, strip, toLower;

    string s = server.strip;
    if (s.toLower.startsWith("tcp:"))
        s = s[4 .. $];
    else if (s.toLower.startsWith("np:") || s.toLower.startsWith("lpc:") || s.toLower.startsWith("admin:"))
        throw new ClientException("Server '" ~ server ~ "': only TCP connections are supported");
    auto parts = s.findSplit(",");
    string host = parts[0].strip;
    ushort port;
    if (parts[1].length)
    {
        try
            port = parts[2].strip.to!ushort;
        catch (ConvException)
            throw new ClientException("Server '" ~ server ~ "': invalid port");
    }
    if (host.indexOf('\\') >= 0)
        throw new ClientException("Server '" ~ server ~ "': named instances are not supported yet "
                ~ "(they need the SQL Server Browser); give the instance's port instead: host,port");
    if (host == "." || host.toLower == "(local)" || host.toLower == "(localdb)")
        host = "localhost";
    if (host.length == 0)
        throw new ClientException("Server '" ~ server ~ "': no host");
    return HostPort(host, port);
}
