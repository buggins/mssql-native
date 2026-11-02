# AGENTS.md

Guidance for AI coding agents working on **mssql-native**, a native D client for Microsoft SQL Server.

## Project at a glance

- **What:** a pure-D client for SQL Server over the **TDS protocol, version 7.4** (TCP, port 1433), for SQL Server 2017+ and Azure SQL, with blocking (thread) and vibe.d (fiber) I/O. dub package `mssql-native`, root module `mssql`.
- **Repo:** `git@github.com:buggins/mssql-native.git`, default branch `main`. Author Vadim Lopatin (GitHub `buggins`). License BSL-1.0.
- **Status:** under development; roadmap issue #11 lists milestones M0–M9 (one issue each).
- **Builds on dbwire** (`../dbwire`): `dbwire:types` (exceptions, `Decimal`), `:io` (transports, I/O backends, buffers), `:tls` (OpenSSL loaded at run time), `:client` (DSN, failover, pool core); later `:charset` (code pages) and `:crypto` (NTLM). Anything not protocol-specific is added to dbwire (issue + PR there), not here.
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
  settings.d           ConnectionOptions (+ fromDsn sqlserver://, fromParams), HostPort, HostSelection
  exception.d          ServerException (ServerMessage), dbwire's ClientException/ConnectionException/ProtocolException
  protocol/            packet.d (PacketWriter, PacketReader), prelogin.d (options, encryption agreement,
                       PreloginTlsFraming), login.d (LOGIN7), tokens.d (DONE, ERROR/INFO, LOGINACK, ENVCHANGE),
                       rpc.d (RPC requests, parameters on the wire, RETURNVALUE, OutputParameter);
                       UTF-16LE comes from dbwire:charset (encodeUtf16le/decodeUtf16le)
  types/               typeinfo.d (TYPE_INFO, COLMETADATA, value framing for every type), values.d (conversions,
                       text, Variant), temporal.d (date/time types), collations.d (collation -> code page,
                       generated from the server's catalog)
integration-tests/     shared harness (dub subpackage `:integration-tests`): tests in `allTests` (harness.d),
                       basic.d (connections, batches), types.d (every type against the server's own text),
                       params.d (parameters, outputs, procedures, prepared statements),
                       statements.d (result sets, counts, cancel, transactions, reset);
                       server from MSSQL_HOST, MSSQL_USER, MSSQL_PASSWORD (MSSQL_VERIFY=1: verify certificates)
integration-tests-phobos/, integration-tests-vibe/   runners (threads, plus threadtests.d; vibe.d tasks, plus vibetests.d)
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

## Types learned from the real server

- `getString` gives the text SQL Server writes, checked by `integrationtests.types` against `CONVERT(nvarchar(max), x[, style])`. Where the default `CONVERT` loses information, the lossless style is used: `money` style 2 (4 fraction digits; style 0 has 2), `datetime` style 121 (style 0 is `Jan 31 2024 12:34PM`), `smalldatetime` style 120, binary style 1 (`0x01AB`). `real`/`float` give the shortest text that reads back exactly (`CONVERT` style 0 keeps 6 digits; style 3 always 17).
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
