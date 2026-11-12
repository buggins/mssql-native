# Changelog

All notable changes to mssql-native are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

## 0.3.1 — 2026-11-12

Float text like SQL Server's own (`100`, not `1e+02`); a `PooledConnection`
collected by the garbage collector no longer crashes; dbwire 0.9.6.

### Changed

- Float text (`Value.toString`, `getString` in ddbc) is plain up to 15 digits
  before the point (6 for `real`), like SQL Server's own text: `100` instead
  of `1e+02`; `1e+15` and `1.5e-05` keep the exponent form (#52).

### Fixed

- A `PooledConnection` finalized by the GC (a field of an object nobody
  references) no longer hands its connection back from the finalizer, which
  called into a pool that may be finalized already (at exit: a segfault). It
  now touches neither the pool nor the connection, which stays checked out:
  call `release` before dropping an object that holds one (#54). Needs dbwire
  0.9.6 (dbwire#79).

## 0.3.0 — 2026-11-10

The fixes and improvements from a code review: robustness, security and
thread safety (#40), float text (#41), attributes, D idioms and dip1000
(#42), performance (#43); and dbwire 0.9 (#38, #48).

### Changed

From the review of attributes and D idioms (#42):

- `@safe` code can pass a `Variant` (e.g. `result.getVariant(0)`) to `exec`,
  `query`, `queryRow`, `queryValue`, `callProcedure`, prepared statements and
  `BulkInserter.addRow`: arguments are taken by `auto ref` (a `Variant` copy
  is `@system`). `insert(table, row)` with one struct is `@safe` too (it
  sliced a pointer), and so are `query!T`/`queryRow!T`/`queryValue!T` with
  `immutable(ubyte)[]` fields (a cast made them `@system`).
- `makeVariant` is no longer public (it is `package(mssql)`, constrained to
  types without elaborate copies or destructors): a public `@trusted`
  template that copies a `T` hid `@system` postblits.
- Fewer `@trusted` blocks (dbwire's endian helpers, values built without
  "unique" casts, `processId` and the pool constructor `@safe`), more `pure`
  and `nothrow`, explicit attributes off templates, compile-time checks of
  what `@safe` code can call. Enum names parsed without `std.conv`; one
  `to!string` instead of six `toText` copies and other duplicated helpers;
  BigInt bytes through `getDigit`. CI runs the unit tests with
  `-preview=dip1000` on the latest compilers.
- Column metadata with an invalid length for `intN`, `bitN`, `floatN`,
  `moneyN`, `datetimeN` or `uniqueidentifier` is rejected with a
  `ProtocolException` (a bulk load could otherwise hit an `Error`).

### Performance

- From the performance review (#43), measured with the new `bench/`
  subpackage (`dub run :bench -b release`, an in-memory fake server; see
  `doc/benchmarks.md`); requests are byte for byte the same as before:
  - `getDouble`/`getLong` of decimals and money whose unscaled value fits in
    64 bits without `BigInt` (48 to 86 times faster, no allocation); doubles
    stay correctly rounded.
  - Date and time text (`getString`) built in a stack buffer instead of up
    to four `format` calls: 7 to 18 times faster; `uniqueidentifier` and
    binary text without `format` (13 and 61 times faster).
    `datetimeoffset` `getSysTime` shares time zones for offsets in whole
    quarter hours (no allocation).
  - Requests with parameters: `@pN` names, the declarations and ASCII text
    written straight into the packet buffer, a statement run again in a loop
    rewritten once (`?` → `@pN`), no temporary `Parameter` arrays: `exec`
    with parameters 2.9 times faster with a fifth of the allocations,
    prepared statements 2.2 times.
  - `insert!T`: one parameter array per call, filled in place, and the
    statement text built once per batch size: 3.9 times faster, 124 bytes
    per row instead of 4.9 KB.
  - Bulk loads: no `Parameter[]` per row, the row buffer reused, the struct
    fields checked once per type: 1.8 to 2.7 times faster, 208 bytes per
    row instead of 1.2 to 2.6 KB.
  - NBCROW null bitmaps and legacy text pointers read without allocating;
    column names decoded in the read buffer; `Parameter.of` of `Decimal`,
    `DateTime` and `SysTime` without temporary arrays (2.4 to 4.5 times
    faster).
- `real`/`float` text (`getString`) from dbwire's `shortestDigits` instead of
  up to 17 `format("%.*g")` and `to!double` attempts (#41): 3.6 to 5.4 times
  faster, one allocation (doubles like prices: 0.89 µs and 277 B before,
  0.25 µs and 16 B now). The layout stays `%g`'s. The text is never exactly
  halfway between two values (`Ties.avoid`), so it reads back whatever way
  the reader rounds ties (SQL Server's parser doesn't round them to even).
  Some old texts didn't read back as the same value under C's `strtod`
  (Phobos's parser accepted them), others were longer than needed. dbwire
  `~>0.9.2` (which has `Ties.avoid`).

### Fixed

From the code review (#40):

- `cancel()` racing with the start of a request could desynchronize the
  connection: the attention went out before the request, its acknowledgement
  was taken for the request's response, and the next query returned the
  previous one's rows; during a long request it landed inside the request
  message, and a late one could cancel the next batch. `cancel()` is now
  checked and sent under the lock the requests take: one that comes while a
  request is written goes out right after it; one that comes after the batch
  ended cancels nothing else. It is `nothrow`.
- A `ServerException` while reading rows left the `QueryResult` unfinished:
  `close()` (`scope (exit) r.close()`) then read on, closing the intact
  connection or taking another result's rows. Results now stop once their
  response is over, failed, or the connection moved on to another request.
- `query!T`: a value that didn't convert left the connection busy; the
  result is closed now.
- A prepared statement whose first execution failed lost its server handle.
- An exception from `onMessage` closed the connection; it is thrown after the
  response was read, and the connection stays usable.
- A fiber-mode connection used from another thread is refused before anything
  changes (it was closed from that thread); `close()` from there only marks
  it closed (a later `close()` on its own thread closes the socket),
  `cancel()` does nothing. A result whose connection was closed before it was
  read throws instead of looking complete.
- Server data that could crash the client or exhaust its memory: many empty
  packets (recursion), an invalid packet size in ENVCHANGE (an `AssertError`,
  a 4 GB buffer, or a desynchronized stream; now a protocol error), session
  state and feature acknowledgements and values whose announced lengths were
  allocated before any data arrived. At most 100 errors (plus fatal ones) are
  kept per response.
- `ConnectionPool`: a returned connection (`release()`, or the
  `PooledConnection` going out of scope) is rolled back right away (its locks
  were held while idle; checked on SQL Server 2022), `onMessage` is cleared,
  and statements and bulk inserters of the previous borrower are refused;
  `resetSession()` reports the reset state (`inTransaction`, `database`,
  `language`) at once.
- Requests that can't be written are refused before anything is sent:
  parameter names over 255 UTF-16 code units, parameters of types that can't
  be sent (an `assert` mid-request before), login fields too long for LOGIN7,
  dates outside 0001–9999 (they wrapped around).
- `BulkInserter.abort()` on a closed connection no longer replaces the
  original error; the collations of a table in another database are looked
  up with the database name quoted (`[my db]`).
- `ConnectionOptions.toString` hides `password` and `tls.keyPassword`, and
  errors about an ADO.NET connection string no longer show the rest of a
  password with an unquoted `;`.

### Changed

- dbwire 0.9 (`~>0.9.0`), like clickhoused, postgresql-native and
  oracle-native: the fixes from its code review (huge TZif counts rejected
  before allocating, the next address tried when a socket can't be created,
  faster character set conversions, fewer allocations).
- dbwire `~>0.9.3` (#48): SQL text, procedure and parameter names and text
  parameters are encoded as UTF-16 straight into the packets, without
  allocating, also when they aren't ASCII (dbwire's `encodeUtf16leInto`
  replaces the ASCII-only workaround); faster decoding of ASCII text; float
  text laid out by dbwire's `formatDigits` and date/time text built with its
  `TextBuffer` (the same text); a `?password=` in a connection string is
  masked in error messages.
- `connect_timeout=0` (`Connect Timeout=0`, `ConnectionOptions.connectTimeout
  = Duration.zero`) means no time limit, as in ADO.NET. With dbwire 0.8
  connecting failed at once.

## 0.2.4 — 2026-11-07

### Changed

- Depends on dbwire 0.8 (`~>0.8.0`, #34), the same as postgresql-native 0.5,
  clickhoused 0.9 and oracle-native 0.3.1, so they can be used in one build
  (and in ddbc, which resolves the dependencies of all configurations
  together). No code changes.

## 0.2.3 — 2026-11-04

### Fixed

- The version constants match the release again (#30): the sources tagged
  v0.2.2 reported version 0.2.1 (`mssqlVersion`, and the client version sent
  in PRELOGIN and LOGIN7). No library changes.

## 0.2.2 — 2026-11-04

### Changed

- Depends on dbwire 0.6 (#25), the version oracle-native 0.3 uses, so that
  ddbc can offer both native drivers again. No code changes.

The sources tagged v0.2.2 still report version 0.2.1 (`mssqlVersion`, and the
client version sent in PRELOGIN and LOGIN7); corrected in 0.2.3 (#30).

## 0.2.1 — 2026-11-03

### Changed

- Depends on dbwire 0.5 (#22), so that packages can use mssql-native
  together with oracle-native (ddbc offers both native drivers, and dub
  resolves the dependencies of all configurations together). No code
  changes: dbwire 0.5 only adds `dbwire:crypto`.

## 0.2.0 — 2026-11-02

### Added

- Bulk insert (#8): `Connection.bulkInsert` returns a `BulkInserter`
  (`addRow`, `add` for structs, `finish`, `abort`); `bulkInsert(table,
  structs)` in one call. It reads the columns' types (`SELECT TOP 0`), sends
  `INSERT BULK` and the rows as bulk load data, each value converted to its
  column's exact type with SQL Server's rounding (decimals, money, times,
  `datetime`, `smalldatetime`) and range checks; `char`/`varchar` in the
  column's code page (collations from `sp_tablecollations_100`), `xml` as
  `nvarchar(max)`. `BulkOptions`: batch size, `TABLOCK`, `CHECK_CONSTRAINTS`,
  `FIRE_TRIGGERS`, `KEEP_NULLS`. A value that doesn't fit is refused before it
  is sent (the inserter stays usable); server errors fail the batch. About 20×
  faster than `INSERT ... VALUES` for 100,000 rows.
- Decimal parameters with an unscaled value within 64 bits are encoded
  without `BigInt`.
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
