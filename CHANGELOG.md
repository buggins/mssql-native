# Changelog

All notable changes to mssql-native are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

### Added

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
