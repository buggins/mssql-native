/++
Native Microsoft SQL Server client library for D.

mssql-native talks to SQL Server over the TDS protocol (version 7.4) and works
both with blocking Phobos sockets (ordinary threads) and with vibe-core sockets
(vibe.d fibers), through [dbwire](https://github.com/buggins/dbwire).

This is an unofficial project, not affiliated with Microsoft.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors:   Vadim Lopatin
+/
module mssql;

public import mssql.bulk : BulkInserter, BulkOptions;
public import mssql.connection : Connection, IsolationLevel;
public import mssql.exception;
public import mssql.params : Parameter;
public import mssql.mapping : column, ColumnName, columnNames, ignore, IgnoreField, readValue, RowRange;
public import mssql.pool : ConnectionPool, PoolOptions, PooledConnection;
public import mssql.prepared : PreparedStatement;
public import mssql.protocol.rpc : OutputParameter;
public import mssql.result : Command, QueryResult, StatementCount;
public import mssql.value : Value;
public import mssql.settings;
public import mssql.types.typeinfo : Collation, ColumnInfo, TdsType, TypeInfo;
public import mssql.types.temporal : Temporal, TemporalKind;
public import dbwire.io.backend : IoMode;
public import dbwire.types.decimal : Decimal, RoundingMode;
public import std.typecons : Nullable;
public import dbwire.tls.transport : TlsOptions;

/// Library version.
enum uint mssqlVersionMajor = 0;
/// ditto
enum uint mssqlVersionMinor = 2;
/// ditto
enum uint mssqlVersionPatch = 0;

/// Library version as a string, e.g. `"0.1.0"`.
enum string mssqlVersion = versionString(mssqlVersionMajor, mssqlVersionMinor, mssqlVersionPatch);

/// Client library name reported to the server at login.
enum string mssqlClientName = "mssql-native";

version (Have_vibe_core)
    private enum bool hasVibeCore = true;
else
    private enum bool hasVibeCore = false;

/++
True when vibe-core support is compiled in.

dub defines `Have_vibe_core` when vibe-core is anywhere in the application's
dependency graph. mssql-native then supports fiber mode in addition to the
always-available thread mode.
+/
enum bool mssqlHasVibe = hasVibeCore;

private string versionString(uint major, uint minor, uint patch) pure @safe
{
    import std.conv : to;

    return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
}

///
@safe unittest
{
    import std.algorithm.searching : count;

    assert(mssqlVersion.count('.') == 2 && mssqlClientName == "mssql-native");
}
