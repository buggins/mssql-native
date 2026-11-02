# Contributing to mssql-native

Thank you for your interest in contributing.

## Workflow

Every change goes through an issue and a pull request; nothing is pushed to
`main` directly. Open an issue first (or pick one from the
[roadmap](https://github.com/buggins/mssql-native/issues/11)), work on a feature
branch, and mention `Closes #N` in the pull request.

## Development setup

- A D compiler with frontend **2.097 or newer**: DMD 2.097+, LDC 1.27+ or GDC 12+.
- [dub](https://code.dlang.org).
- For integration tests: a SQL Server in Docker, e.g.

  ```sh
  docker run -d --name mssql -p 1433:1433 -e ACCEPT_EULA=Y -e MSSQL_PID=Developer \
      -e 'MSSQL_SA_PASSWORD=Your_password123' mcr.microsoft.com/mssql/server:2022-latest
  ```

  Its certificate is self-signed: connect with `trust_server_certificate=true`.

## Building and testing

```sh
dub build       # library (thread mode, no C dependencies)
dub test        # unit tests, no server needed
```

## Code style and checks

CI runs these checks, so run them before sending a pull request:

```sh
dub run dscanner@0.15.2 -- --styleCheck .                   # static analysis
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')      # formatting
dub build -b docs                                           # documentation builds
```

- Formatting follows `dfmt`, configured in `.editorconfig`: Allman braces, 4-space indentation.
- **Document every public symbol with a Ddoc comment.** D-Scanner reports undocumented public declarations.
- **Add unit tests next to the code they test.** A unittest preceded by `///` becomes a usage example in the generated docs.
- Prefer `@safe`. Keep `@trusted` blocks small, with a comment explaining why each one is safe.
- Anything that can block goes through dbwire's I/O backends, never directly through `std.socket`, `core.sync` or vibe.d.
- vibe.d-specific code belongs under `version (Have_vibe_core)`. The default build must not depend on vibe-core.
- Don't use language or library features newer than frontend 2.097.

## Licensing of contributions

mssql-native is licensed under the [Boost Software License 1.0](LICENSE). By contributing, you agree that your contributions are licensed under the same terms.

- **The protocol is implemented from Microsoft's specification**, [MS-TDS](https://learn.microsoft.com/openspecs/windows_protocols/ms-tds/), published under the Microsoft Open Specifications Promise.
- **Other clients are reference only**: reading go-mssqldb, tedious, or Microsoft's JDBC driver and SqlClient to understand the protocol is fine; copying or translating their code is not. Reproducing wire-format facts (packet layouts, constants, type encodings) is fine.
- **Don't use FreeTDS or jTDS at all**, not even as a reference (LGPL).
- Test data (golden bytes) comes from real servers, not from other clients' test suites.
- Third-party code or data needs the maintainer's agreement before it is added.
