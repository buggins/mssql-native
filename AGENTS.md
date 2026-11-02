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

## Conventions

- `@safe` by default; small commented `@trusted` blocks only in I/O and reinterpret-cast hot paths.
- **Every public symbol gets a Ddoc comment**; documented unittests as usage examples.
- Every type gets golden-byte unit tests and server round trips in both I/O modes; cover NULLs, extremes, non-ASCII text, collations, time zones.
