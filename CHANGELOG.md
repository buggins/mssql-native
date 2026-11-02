# Changelog

All notable changes to mssql-native are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

### Added

- More types (#7):
  - `sql_variant`: values read with their base type (`Value.base`); every
    getter and `getVariant` converts the base value;
  - `rowversion`/`timestamp` columns are named `timestamp` and `getLong` gives
    their counter; `TypeInfo.userType` keeps the column's user type;
  - `char`/`varchar` in the Japanese, Chinese and Korean collations (code
    pages 932, 936, 949, 950, from dbwire 0.4);
  - CLR types (`hierarchyid`, `geometry`, `geography`) are read as bytes;
    their getters say how to get text (convert in the query);
  - integration tests for `(max)` values up to 10 MB, `xml`, `text`, `ntext`,
    `image`, `sql_variant`, `rowversion`, CLR types, and every byte pair of the
    double-byte code pages.

## 0.1.0 — 2026-11-02

First release.

### Added

- High-level API (#6):
  - `ConnectionPool` and `PooledConnection` over dbwire's `PoolCore`, in
    thread and fiber mode; a connection handed out again has its session reset
    with its next request;
  - ADO-style connection strings (`Server=tcp:db,1433;Database=...;User
    Id=...;Password=...;TrustServerCertificate=True;Max Pool Size=8`) besides
    the URL style; `ConnectionOptions.parse` accepts both;
  - struct mapping (`mssql.mapping`): `query!T`, `queryRow!T`, `queryValue!T`
    and `insert(table, structs)`, with `@column` and `@ignore`; `insert` sends
    up to 1000 rows per statement, in a transaction of its own when it needs
    several statements;
  - parameters refuse NaN and infinity (SQL Server can't store them);
  - examples (`:example-basic`, `:example-vibe`), and a runner for the vibe.d
    tests against vibe-core 1.x (`:integration-tests-vibe1`).
- Statements in depth (#5):
  - `queryMultiple` and `QueryResult.nextResult`: all result sets of a batch;
    `callProcedure` returns all result sets of the procedure;
    `QueryResult.counts` (rows per statement, with its command) and
    `recordsAffected`;
  - cancelling: `Connection.cancel` (from another thread or task) and
    `QueryResult.cancel` send an attention request and read up to its
    acknowledgement, also when it comes after the batch has ended; a cancelled
    `exec` throws `ClientException`, a cancelled result ends (`cancelled`);
  - transactions: `begin` (with an `IsolationLevel`), `commit`, `rollback`,
    `savepoint`, `rollback(savepoint)`, `setIsolationLevel`;
  - `resetSession`: the next request resets the session (for pools), and the
    client restores the login's database, language and collation;
  - integration tests for result sets, counts, cancel (same thread, another
    thread, another task), transactions, reset and fatal errors.
- Parameters, stored procedures and prepared statements (#4):
  - `exec(sql, args...)` and `query(sql, args...)`: `?` placeholders (not in
    literals, quoted names or comments) become `@p1, @p2, ...`, sent with
    `sp_executesql` over an RPC request; arguments of every D type of the M2
    types (`Parameter.of`), typed NULLs (`Nullable!T`, `Parameter.nullOf!T`),
    `Variant`, or one `Parameter[]` built at run time;
  - output parameters (`Parameter.output`, `outputOf!T`) and stored procedure
    calls (`callProcedure`, positional or named parameters); the result's
    `outputs` and `returnStatus` once its rows are read;
  - `Connection.prepare` → `PreparedStatement`: `sp_prepexec` on the first
    execution, `sp_execute` afterwards, prepared again when the parameter types
    change; `close` releases it (`sp_unprepare`);
  - `Value`: one value with all the getters (`result[i]`, output parameters);
  - integration tests: every D type sent and read back, into typed columns,
    NULLs, placeholders, outputs, procedures, prepared statements,
    transactions.
- The basic types (#3), read with their exact values:
  - `decimal`/`numeric` and `money`/`smallmoney` as dbwire `Decimal`
    (`getDecimal`); `date`, `time(n)`, `datetime2(n)`, `datetimeoffset(n)`,
    `datetime`, `smalldatetime` (`getDate`, `getTime`, `getDuration` with
    100 ns precision, `getDateTime`, `getSysTime`: UTC for types without an
    offset); `uniqueidentifier` (`getUUID`); `binary`/`varbinary`;
  - `char`/`varchar`/`text` in the code page of the column collation: the
    single-byte Windows code pages through dbwire 0.3 `:charset`, and UTF-8;
    the collation-to-code-page table is generated from SQL Server's catalog;
  - `getVariant` with each type's natural D type; `getString` with the text SQL
    Server writes (lossless styles for money, datetime, binary; floats as the
    shortest text that reads back exactly); numeric getters convert between
    integers, decimals and floats;
  - integration tests compare every type's text with the server's `CONVERT`
    output, every `datetime` millisecond, every scale of the time types, and
    all bytes of each supported code page.
- Connecting and the first queries (#2):
  - TDS 7.4 packets; PRELOGIN with encryption negotiation; TLS through dbwire
    0.2 — the handshake inside PRELOGIN packets, full encryption, or only the
    login packet when neither side asks for encryption; encryption is on by
    default, with certificate verification (`trust_server_certificate` for
    development servers);
  - LOGIN7 with SQL Server authentication; LOGINACK, ENVCHANGE (database,
    language, packet size, collation, transactions), INFO, ERROR, DONE;
  - `Connection`: `exec` (rows affected), `query` (rows of the first result
    set, later statements read and discarded), `ping`, `close`; failover over
    several hosts; connect, send and receive timeouts; thread and fiber (vibe.d)
    mode; `ConnectionOptions` with `sqlserver://` connection strings;
  - `QueryResult`: row-by-row reading (input range or `next()`), `getLong`,
    `getInt`, `getBool`, `getDouble`, `getString`, `getBytes`, `isNull`;
    integers, `bit`, `real`/`float`, `nvarchar`/`nchar`, `varchar` (UTF-8
    collations and ASCII); every other type is read (the stream stays in sync)
    and refused clearly on access until M2;
  - `ServerException` (number, state, severity, line, procedure, all errors of
    the statement); a fatal error (severity 20 and above) closes the connection;
  - unit tests with golden bytes and a replayed session from SQL Server 2022;
    integration tests against SQL Server 2017, 2019 and 2022 in both I/O modes,
    run by CI.
- Repository scaffold (#1): dub package `mssql-native` (module `mssql`) on
  dbwire, CI on Linux, Windows and macOS with DMD and LDC down to frontend
  2.097, a SQL Server service container for integration tests, lint and
  documentation checks.
