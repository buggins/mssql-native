# AGENTS.md

Guidance for AI coding agents working on **mssql-native**, a native D client for Microsoft SQL Server.

## Project at a glance

- **What:** a pure-D client for SQL Server over the **TDS protocol, version 7.4** (TCP, port 1433), for SQL Server 2017+ and Azure SQL, with blocking (thread) and vibe.d (fiber) I/O. dub package `mssql-native`, root module `mssql`.
- **Repo:** `git@github.com:buggins/mssql-native.git`, default branch `main`. Author Vadim Lopatin (GitHub `buggins`). License BSL-1.0.
- **Status:** 0.3.1 released on 2026-11-12 (M0–M5 in 0.1.0: connect, types, parameters, statements, pool and mapping; 0.2.0: M6 more types, M7 bulk insert; 0.2.1: dbwire 0.5; 0.2.2: dbwire 0.6; 0.2.3: version constants; 0.2.4: dbwire 0.8; 0.3.0: code review fixes #40–#43, dbwire 0.9 #38, #48; 0.3.1: float text #52, PooledConnection finalizer #54, dbwire 0.9.6); roadmap issue #11 lists milestones M0–M9 (one issue each). Published on code.dlang.org as `mssql-native`.
- **Builds on dbwire** (`../dbwire`, `~>0.9.6`): `dbwire:types` (exceptions, `Decimal`), `:io` (transports, I/O backends, buffers), `:tls` (OpenSSL loaded at run time), `:client` (DSN, failover, pool core); later `:charset` (code pages) and `:crypto` (NTLM). Anything not protocol-specific is added to dbwire (issue + PR there), not here.
- **Sibling project:** `../clickhoused` (ClickHouse client): the model for structure, API style, tests and conventions (its `AGENTS.md`).
- **`PLAN.md` (local and optional):** the design plan is a local, untracked file (excluded through `.git/info/exclude`). If present, read it before design-level changes and keep it up to date; never `git add` it.

## Workflow

- **Every change goes through an issue and a pull request. Never push to `main` directly.** One feature branch per issue; the PR says `Closes #N`. The author merges.
- Commit, push and open PRs only when the user asks. Releases and tags only on request (version constants in `source/mssql/package.d` and `CHANGELOG.md`; the author pushes the `vX.Y.Z` tag).

## Key design rules

1. **Pure D, zero C dependencies by default.** OpenSSL is loaded at run time through dbwire; other C libraries (SSPI/GSSAPI later) only as optional run-time-loaded extras.
2. **Dual I/O.** Anything that can block goes through dbwire's `IoBackend`/`Transport`; never call `std.socket`, `core.sync`, `Thread.sleep` or vibe APIs from protocol, connection or pool code. vibe code under `version (Have_vibe_core)`.
3. **Runtime interfaces, not templates**, for what a `Connection` holds; `Connection` stays one non-templated class (for the ddbc driver).
4. **Connection invariants** (as in clickhoused): one request at a time; a result holds the connection until drained or closed; `cancel()` (attention) is the only call allowed from another thread or task; a broken stream poisons the connection, which is never returned to a pool.
5. **Robust decoding:** malformed or truncated input throws `ProtocolException`; never crash, never allocate from an unchecked length.
6. **Specification first:** byte layouts come from [MS-TDS] (https://learn.microsoft.com/openspecs/windows_protocols/ms-tds/). Verify every constant and layout there; golden bytes come from real servers.

## Licensing rules (important)

- [MS-TDS] is published under the Microsoft Open Specifications Promise and is the primary source.
- **Other clients are reference only — never copy or translate their code:** go-mssqldb (BSD-3), tedious (MIT), Microsoft JDBC/SqlClient (MIT). Line-by-line translation counts as copying. Wire-format facts are fine to reproduce.
- **Don't use FreeTDS or jTDS at all** (LGPL), not even as a reference.
- If any third-party code or data seems necessary, **stop and ask the user first**. (Approved: code page tables written from the published Windows code page definitions, in dbwire `:charset`.)
- The README says the project is unofficial and not affiliated with Microsoft.

## Decisions

Minimum server SQL Server 2017 (tested on 2017, 2019, 2022 images); `?` placeholders rewritten to `@p1...` for `sp_executesql`; encryption on by default with certificate verification (`trust_server_certificate` for development); TDS 7.4 first, TDS 8.0 later.

## Commands

The recipe format is **`dub.json`**.

```sh
dub build                                                  # library
dub test                                                   # unit tests
dub run dscanner@0.15.2 -- --styleCheck .                  # lint (CI fails on any warning)
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')     # format (CI fails if this changes files)
dub build -b docs                                          # docs into /docs/ (git-ignored)
dub run :bench -b release [-- --filter query/]             # benchmarks (doc/benchmarks.md); compare the min column
```

Run lint and format before committing D code. dfmt 0.15.2 mangles lambdas with attributes (`() nothrow {` → `() nothrow{`): use named nested functions. It merges `@safe return` into `@safereturn`: avoid the `return` attribute. Run dfmt twice when it changes files. `dub.selections.json` files are git-ignored (a root one listing vibe-core would enable vibe support silently).

## Local environment

- WSL2 Linux. **LDC 1.36.0** (`ldc2`); DMD is not installed. Test the minimum frontend with LDC 1.27.1 (download `https://github.com/ldc-developers/ldc/releases/download/v1.27.1/ldc2-1.27.1-linux-x86_64.tar.xz` into the scratchpad, run dub with `--compiler=<path>/bin/ldc2`).
- SQL Server in Docker: container `ddbc-mssql` (2022, port **11433**, user `sa`, password `MSbbk4k77JKH88g54`); create others with `docker run -d -p <port>:1433 -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e 'MSSQL_SA_PASSWORD=...' mcr.microsoft.com/mssql/server:<2017|2019|2022>-latest`. `sqlcmd` is inside the 2022 image at `/opt/mssql-tools18/bin/sqlcmd -C` (older images: `/opt/mssql-tools/bin/sqlcmd`).
- ODBC Driver 18 for SQL Server is installed (handy to compare results, e.g. through ddbc's ODBC driver).

## Layout

```
source/mssql/
  package.d            public imports, version constants, mssqlHasVibe
  connection.d         Connection: connect (failover, PRELOGIN, TLS, LOGIN7), exec, query, ping, close;
                       the token loop (nextEvent), row reading, ALL_HEADERS, ENVCHANGE handling
  result.d             QueryResult: rows of the first result set (range or next()), getters, outputs, returnStatus
  value.d              Value: one value with all getters (cells, output parameters)
  params.d             Parameter (D value -> TYPE_INFO + bytes, typed NULLs, outputs), rewritePlaceholders (? -> @pN)
  prepared.d           PreparedStatement (sp_prepexec / sp_execute / sp_unprepare)
  pool.d               ConnectionPool, PooledConnection (over dbwire PoolCore; resets sessions on reuse)
  mapping.d            struct mapping: @column, @ignore, readValue, RowRange (query!T; insert is in connection.d)
  bulk.d               BulkInserter, BulkOptions (INSERT BULK + bulk load data, packet type 7)
  settings.d           ConnectionOptions (+ fromDsn sqlserver://, fromAdo Server=...;..., parse, fromParams), HostPort
  exception.d          ServerException (ServerMessage), dbwire's ClientException/ConnectionException/ProtocolException
  protocol/            packet.d (PacketWriter, PacketReader), prelogin.d (options, encryption agreement,
                       PreloginTlsFraming), login.d (LOGIN7), tokens.d (DONE, ERROR/INFO, LOGINACK, ENVCHANGE),
                       rpc.d (RPC requests, parameters on the wire, RETURNVALUE, OutputParameter);
                       UTF-16LE comes from dbwire:charset (decodeUtf16le; PacketWriter.putUtf16 encodes straight
                       into the packets with encodeUtf16leInto, utf16Length gives the length beforehand)
  types/               typeinfo.d (TYPE_INFO, COLMETADATA, value framing for every type), values.d (conversions,
                       text, Variant), temporal.d (date/time types), collations.d (collation -> code page,
                       generated from the server's catalog), encode.d (values in a column's exact
                       type for bulk loads)
integration-tests/     shared harness (dub subpackage `:integration-tests`): tests in `allTests` (harness.d),
                       basic.d (connections, batches), types.d (every type against the server's own text),
                       params.d (parameters, outputs, procedures, prepared statements),
                       statements.d (result sets, counts, cancel, transactions, reset), bulk.d (bulk insert);
                       server from MSSQL_HOST, MSSQL_USER, MSSQL_PASSWORD (MSSQL_VERIFY=1: verify certificates)
integration-tests-phobos/, integration-tests-vibe/   runners (threads, plus threadtests.d; vibe.d tasks, plus vibetests.d)
integration-tests-vibe1/   the vibe.d runner against vibe-core 1.22.6 (sources shared with integration-tests-vibe)
examples/              basic (`:example-basic`), vibe (`:example-vibe`); read MSSQL_CONNECTION
bench/                 benchmarks (dub subpackage `:bench`, local runs only): fakeserver.d (an in-memory server:
                       PRELOGIN without encryption, LOGIN7 answered with LOGINACK, then scripted token streams),
                       cases.d, runner.d; results in doc/benchmarks.md
```

Run the integration tests with `MSSQL_HOST=localhost:11433 MSSQL_USER=sa MSSQL_PASSWORD=MSbbk4k77JKH88g54 dub run :integration-tests-phobos` (and `:integration-tests-vibe`). Other local servers: containers `mssql-2017` (port 14017) and `mssql-2019` (14019), password `Test_password123`.

## Protocol behaviour learned from the real server

- TDS 7.4 version bytes in LOGIN7: `04 00 00 74`; LOGINACK returns `74 00 00 04` (read big-endian: 0x74000004).
- PRELOGIN option offsets count from the start of the PRELOGIN data; the server answers with packet type 4. During the TLS handshake it sends PRELOGIN packets (type 0x12).
- TDS 7.x handshakes negotiate TLS 1.2 even when 1.3 is offered; the client caps at TLS 1.2 (a TLS 1.3 server would send session tickets through the framing).
- Login-only encryption (both sides ENCRYPT_OFF) doesn't verify the certificate, like SqlClient/ODBC; full encryption verifies unless `trust_server_certificate`.
- NBCROW: a set bit in the null bitmap means NULL ([MS-TDS] is self-contradictory there).
- A response may end with DONEPROC (e.g. a batch read as a procedure call: `SELEC 1` gives error 2812); DONEINPROC never ends it.
- Nullable columns come as INTN/BITN/FLTN with their size; non-null literals as fixed types (INT4, ...).
- `SET NOCOUNT ON` lasts for the session: DONE tokens then carry no row counts.

- RPC: system procedures go by id (`0xFFFF`, then sp_executesql 10, sp_prepexec 13, sp_execute 12, sp_unprepare 15). `sp_executesql`/`sp_execute` also send a RETURNSTATUS (0); it is reported only for `callProcedure`. RETURNVALUE tokens (output parameters) come after the rows, before the final DONEPROC; `sp_prepexec` returns the handle as output ordinal 0.
- A NULL `nvarchar` parameter can't go into a `varbinary` column (no implicit conversion): binary NULLs need `Parameter.nullOf!(ubyte[])`. A `datetimeoffset` parameter stored in a `datetime2` column keeps its local time (the offset is dropped). A `decimal` OUTPUT parameter comes back with the declared scale.
- Variadic templates taking parameters must not be marked `@safe` (attribute inference): `Variant` copies are `@system`. A lone `null` argument must not match a `Parameter[]` overload, so `parameters(args)` recognises a single `Parameter[]` itself.

- The server holds back output until a packet is full or the batch ends: rows of `SELECT 1; WAITFOR DELAY ...` arrive after the WAITFOR, so `query()` itself waits. Cancel tests start the cancel before the query, or use a large result.
- Attention (cancel): an 8-byte packet of type 6 written straight to the transport (dbwire's TLS transport allows it from another thread). The server answers with a DONE with status 0x20, at the end of the response; if the batch had already ended, in a message of its own, which the client reads before anything else (`finishIfFinal`, `startRequest`).
- `RESETCONNECTION` (status 0x08 on the request's first packet) is acknowledged only by ENVCHANGE 18: no database/language changes are sent, so the client restores the login's values itself. The reset rolls back an open transaction; the request then carries transaction descriptor 0.
- `master` allows snapshot isolation. Command codes in DONE: SELECT 0xC1, INSERT 0xC3, DELETE 0xC4, UPDATE 0xC5.

- Multi-row `INSERT ... VALUES` (and `UNION`) give each column the union type of its rows: `decimal(38,4)` with `decimal(38,0)` becomes `decimal(38,0)` and the fraction is truncated silently. `insert` therefore sends all decimals of a column with one scale (`withDecimalScale`). SQL Server rejects NaN and infinity in float parameters (error 8023); `Parameter.of` refuses them, and D float fields start as NaN.
- Mapping templates (`query!T`, `queryRow!T`, `queryValue!T`, `insert`) are member templates overloaded with the variadic `query(sql, args...)`; an explicit `query!Row(sql, args)` picks the mapping one. Like the parameter templates, they infer their attributes.

- Bulk load (packet type 7): `INSERT BULK table (col type, ...)` first, then one message with COLMETADATA, ROW tokens and DONE. The server checks the data only when the message ends. What it insists on:
  - each column's TYPE_INFO exactly as `SELECT TOP 0` reports it (INT4 for `int NOT NULL`, INTN for nullable) and **the same nullable flag**, else error 4816 "Invalid column type from bcp client";
  - `char`/`varchar` bytes are read in the code page of the declared `INSERT BULK` column: declare `COLLATE` (names from `[tempdb..]sp_tablecollations_100`);
  - `xml` data can't be of type xml: send `nvarchar(max)`;
  - PLP values with their total length fail (error 4804); the "unknown length" form (0xFFFFFFFFFFFFFFFE) works;
  - ending the message with the IGNORE status (0x02) discards it; the server still answers with a DONE.

## Types learned from the real server

- `sql_variant` (type 0x62, 4-byte length): base type byte, property byte count, properties (decimal: precision, scale; time types: scale; strings: collation and max length; binary: max length), then the value. `CONVERT(nvarchar, sql_variant)` writes dates in style 0 (`Jan 31 2024`); `getString` uses the base type's text. A multi-row `VALUES` into a `sql_variant` column first converts all values to one type: insert them one statement each.
- `rowversion` is `binary(8)` with user type 80 (big-endian counter); `CONVERT(..., rv, 1)` is not allowed, cast to `varbinary(8)` first.
- Double-byte code pages: a lead byte plus a trail byte is one character, an invalid pair the default character (U+30FB for 932, `?` otherwise), a lead byte before 0x00 the default character and the 0x00, a lead byte at the end nothing (checked on every pair; tables in dbwire `charset/tables`).

- `getString` gives the text SQL Server writes, checked by `integrationtests.types` against `CONVERT(nvarchar(max), x[, style])`. Where the default `CONVERT` loses information, the lossless style is used: `money` style 2 (4 fraction digits; style 0 has 2), `datetime` style 121 (style 0 is `Jan 31 2024 12:34PM`), `smalldatetime` style 120, binary style 1 (`0x01AB`). `real`/`float` give the shortest text that reads back exactly (`CONVERT` style 0 keeps 6 digits; style 3 always 17): dbwire's `shortestDigits` with `Ties.avoid`, laid out by `formatDigits` as `%g`, so `100` is `1e+02` (#41). Ties must be avoided: SQL Server's text parser doesn't round halfway texts to even (`CAST('-3.668192745606422e+16' AS float)` is 0xC3604A4098F6405B, the correctly rounded value ...5C), and it makes every subnormal 0 (`CAST('4.9406564584124654e-324' AS float)` = 0), checked on 2022.
- `datetime` holds 1/300 s; SQL Server shows milliseconds as `(ticks * 10 + 1) / 3` (.000, .003, .007); the getters use the same milliseconds.
- `datetimeoffset` is sent as UTC time and date, then the offset in minutes (signed 16-bit); text and `getDate`/`getTime`/`getDateTime` use the local time at that offset.
- Dates and times with fewer fraction digits are rounded by the server, not truncated (`time(0)` of `...58.9` is `...59`).
- `money`: the high 32 bits come first, then the low 32 bits. `decimal`: a sign byte (1 = positive), then a little-endian magnitude of 4, 8, 12 or 16 bytes. GUID: the first three groups little-endian.
- `char`/`varchar` text is in the collation's code page: SQL collations are identified by the sort id, Windows collations by the LCID (`types/collations.d`, generated with a query of `sys.fn_helpcollations()` and the collation bytes of a column in each). Unicode-only collations (code page 0) can't be used for `varchar`. Double-byte code pages (932, 936, 949, 950) aren't supported yet: such text throws, ASCII text still reads.
- In T-SQL, `CAST(N'...' AS varchar) COLLATE X` converts through the database's code page first (unmappable characters become `?`); to get text in X's code page write `CAST(N'...' COLLATE X AS varchar)`, or insert `varbinary` into a `varchar` column of collation X (raw bytes, no conversion).
- Errors are collected until the final DONE, then thrown as one `ServerException`, so the stream stays in sync; severity 20+ closes the connection.

## Conventions

- `@safe` by default; small commented `@trusted` blocks only in I/O and reinterpret-cast hot paths.
- **Every public symbol gets a Ddoc comment**; documented unittests as usage examples.
- Every type gets golden-byte unit tests and server round trips in both I/O modes; cover NULLs, extremes, non-ASCII text, collations, time zones.

## D idioms and review lessons

Learned from the review of the MySQL 8 work in mysql-native (mysql-d/mysql-native#288, 2026-11). All of these work on the minimum frontend 2.097; checked with LDC 1.27.1.

- **`BigInt` and bytes: never go through hex or decimal strings.**
  - Bytes to `BigInt`: `BigInt(false, bytes)` takes any finite range of unsigned integers, most significant first.
  - `BigInt` to words or bytes: `value.getDigit!uint(i)` or `getDigit!ulong(i)` for `i` below `uintLength` or `ulongLength`, least significant first. dbwire's `WideInt.fromBigInt` does this.
  - Modular exponentiation: `std.bigint.powmod`.
  - `format("%x", bigint)` groups digits with `_` until Phobos 2.114 (dlang/phobos#11051).
- **Enums for protocol names.** For a fixed set of wire strings such as plugin names, use a `ubyte` enum whose members are spelled exactly like the wire names; the protocol's own spelling beats camelCase here.
  - `to!string` then gives the name to send. It returns the stored literal and doesn't allocate for a valid member, but it isn't `nothrow` or `@nogc`.
  - To parse untrusted input, loop over the members: `static foreach (m; __traits(allMembers, E)) if (name == m) return __traits(getMember, E, m);`. This is `nothrow @nogc` and compares the packet slice directly, with no `idup`. Don't use `to!E(name)`, which throws `ConvException` on unknown names.
  - Each name then appears once, instead of in a parse table and a format table that can drift apart.
  - With a `string`-based enum, `to!string` returns the member's identifier, not its value.
- **Small idioms:**
  - Test byte vectors: `cast(const(ubyte)[]) std.conv.hexString!"0a1b..."` instead of hand-written hex decoding.
  - Strip leading zero bytes with `find!(b => b != 0)`.
  - Copy (`idup`) a slice only where it must outlive the buffer; an error message built inside `enforce` is lazy, so copying there is fine.
- **Function attributes** (`@safe`, `@trusted`, `pure`, `nothrow`, `@nogc`, `scope`). Sources: the D spec (function.html, attribute.html), the D blog's memory-safety series, and the D forum consensus. Behaviour checked with LDC 1.27.1 and 1.36 (2026-11-08).
  - **Inference.** Templates, `auto` functions, nested functions and lambdas infer `@safe`, `pure`, `nothrow` and `@nogc`. Other functions infer nothing, even when their body is visible.
    - Write the attributes on ordinary functions, public API first.
    - Leave them off templates. An attribute written on a template binds every instantiation (an `@safe` template rejects a `T` whose copy is `@system`).
    - Lock in what a template infers with an attributed unittest that instantiates it with plain types, e.g. `@safe pure nothrow @nogc unittest`.
  - **`@safe:` at module scope** covers everything after it, templates included; they still infer the other attributes. `pure`, `nothrow` and `@nogc` don't propagate into struct and class bodies.
  - **`@trusted` promises a safe interface.** For every argument a `@safe` caller can pass, the function must not corrupt memory or create an unsafe value, such as a dangling pointer or a `bool` other than 0 or 1. The compiler doesn't check the body.
    - Keep the trusted part as small as possible: trust the one `@system` call, e.g. `(() @trusted => v.get!T)()`, with a comment saying why it is safe.
    - A trusted lambda makes the enclosing function part of the review. Whatever the lambda relies on, such as a length checked a few lines earlier, must stay true when that function changes.
    - A `cast(ubyte[])` view of values without indirections is fine for reading. Writing arbitrary bytes into `bool` or enum values through such a view creates invalid values; normalize them before `@safe` code sees them.
  - **Never mark a template `@trusted` if its body copies, constructs or destroys a `T`.** The attribute hides `T`'s `@system` postblit, copy constructor or destructor. Checked: `V wrap(T)(ref T v) @trusted { T copy = v; ... }` compiles in `@safe` code for a struct with a `@system` postblit. Trust only the `@system` call inside, which lets inference catch `T`, or constrain `T` (`!hasIndirections!T`, `!hasElaborateCopyConstructor!T`).
  - **`nothrow`**: only `Error`s may escape.
    - Wrap calls that can't actually throw in `std.exception.assumeWontThrow`, or in `try ... catch (Exception e) assert(0, e.msg);`.
    - Never catch `Error` or `Throwable` to make code `nothrow`.
  - **`@nogc`** forbids `new`, array appending and concatenation, closures that escape, and `throw new`. Use it for leaf hot paths (codecs, parsers); error paths that throw stay outside it.
  - **`debug` statements** may break `pure`, `nothrow` and `@nogc`, which helps temporary logging. They compile only with `-debug`; don't leave them in committed code.
  - **`scope` and `return scope`** are checked only in `@safe` code compiled with `-preview=dip1000`, which is still not the default (D 2.113, August 2026).
    - Without that switch, `scope` is an unchecked promise. With it, callers may pass stack memory to a `scope` parameter, so a `@trusted` or `@system` function that keeps such a parameter has a memory bug.
    - dbwire and the four connectors are dip1000-clean on current compilers: CI runs their unit tests with `-preview=dip1000` on dmd-latest and ldc-latest (dbwire#50, clickhoused#71, postgresql-native#37, oracle-native#47, mssql-native#42). Older Phobos isn't: 2.097's `std.socket` has no `scope` annotations. Don't add `scope` speculatively.
- **Changes to someone else's code: keep the diff small.** Keep the existing structure, and change the input instead of the cases. For example, when MySQL 8.4 inserted a `Language` column after `Type` in `SHOW PROCEDURE STATUS` (5.7, 8.0 and MariaDB don't have it; the manual doesn't list it), the fix kept the old switch on column numbers: skip column 3 when there are 12 columns, and shift the later indexes down by one.
- **Check facts before writing them down.** Verify server behaviour on the real servers, since manuals lag behind. Take CI failure reasons from the job logs, not from memory. A wrong reason in a commit message had to be corrected during that review.
- **CI facts (November 2026):**
  - GitHub retired the `ubuntu-20.04` runners. When a matrix tests old compilers, pin a concrete image instead of `ubuntu-latest`, and prefer the oldest one still offered: `ubuntu-22.04` today (likely until mid-2027). The mysql-native reviewers asked for that as the most conservative choice, and old compilers down to dmd 2.097 / ldc 1.27 pass on it.
  - `macos-latest` is macOS 26 on arm64. There:
    - `setup-dlang` installs no DMD;
    - `setup-dlang@v1` requests `ldc2-1.28.1-osx-aarch64.tar.xz`, while LDC names the file `osx-arm64`, so the download fails with a 404.
  - `macos-15-intel` runs dmd-latest, dmd 2.098.1 and LDC 1.28.1. On macOS 15, even Intel, the dmd 2.101.2 binary doesn't run and LDC 1.31.0's dub crashes (SIGSEGV).
  - With `setup-dlang@v2.0.0`, programs built by LDC 1.30, 1.35 or 1.40.1 crash (segfault, even hello world) on `macos-latest`, `macos-15` and `macos-15-intel`. LDC 1.41.0 is the oldest that works there, so our CI tests ldc-latest and 1.41.0 on macOS, and the older LDCs on Linux.
  - `WebFreak001/dub-upgrade@v0.1.1` uses GitHub's retired cache service ("getCacheEntry failed"); v0.2.0 works.
