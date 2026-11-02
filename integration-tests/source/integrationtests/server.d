/++
The test server: `MSSQL_HOST` (`host` or `host:port`), `MSSQL_USER` (default
`sa`), `MSSQL_PASSWORD`. Test servers in Docker have self-signed certificates,
so the tests trust them (`trust_server_certificate`) unless `MSSQL_VERIFY=1`.
+/
module integrationtests.server;

import std.process : environment;
import std.uri : encodeComponent;

import mssql;

/// Whether a server is configured.
bool serverConfigured()
{
    return environment.get("MSSQL_HOST", "").length > 0;
}

/// The connection string for the test server, with extra `params` (`key=value&...`).
string serverDsn(string params = null)
{
    const trust = environment.get("MSSQL_VERIFY", "") == "1" ? "" : "trust_server_certificate=true";
    string query = trust;
    if (params.length)
        query ~= (query.length ? "&" : "") ~ params;
    return "sqlserver://" ~ encodeComponent(environment.get("MSSQL_USER", "sa")) ~ ":"
        ~ encodeComponent(
                environment.get("MSSQL_PASSWORD", "")) ~ "@" ~ environment.get("MSSQL_HOST", "")
        ~ "/master" ~ (query.length ? "?" ~ query : "");
}

/// Options for the test server.
ConnectionOptions serverOptions(string params = null)
{
    return ConnectionOptions.fromDsn(serverDsn(params));
}

/// Connects to the test server.
Connection connectToServer(string params = null)
{
    return new Connection(serverOptions(params));
}

/// The first value of the first row of `sql` as text.
string scalar(Connection conn, string sql)
{
    auto r = conn.query(sql);
    scope (exit)
        r.close();
    if (r.empty)
        return null;
    return r.getString(0);
}
