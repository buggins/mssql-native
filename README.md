# mssql-native

A native client for **Microsoft SQL Server** in D: the TDS protocol over TCP,
written in pure D, for ordinary threads (blocking sockets) and vibe.d fibers.
No ODBC, no FreeTDS, no C libraries at build time.

> **Status: under development.** Nothing is released yet; the plan is tracked
> in the [roadmap issue](https://github.com/buggins/mssql-native/issues/11).
> Connecting (TLS, SQL logins), queries with parameters, stored procedures,
> prepared statements and all the common types work; multiple result sets and
> cancellation come next.

```d
import mssql;
import std.stdio;

auto conn = new Connection(
    "sqlserver://sa:secret@localhost/master?trust_server_certificate=true");
scope (exit)
    conn.close();
conn.exec("CREATE TABLE #t (id int, name nvarchar(50), amount decimal(18,2))");
conn.exec("INSERT INTO #t VALUES (?, ?, ?)", 1, "Grüße", Decimal.fromString("12.50"));
foreach (row; conn.query("SELECT id, name, amount FROM #t WHERE id > ?", 0))
    writeln(row.getInt(0), " ", row.getString(1), " ", row.getDecimal(2));

auto insert = conn.prepare("INSERT INTO #t (id, name) VALUES (?, ?)"); // compiled once
foreach (i; 2 .. 10)
    insert.exec(i, "row");
insert.close();
```

Planned for the first release (0.1.0):

- SQL Server 2017 and newer, Azure SQL;
- TLS (encryption on by default, with certificate verification), SQL logins;
- queries and parameters (`?` placeholders sent with `sp_executesql`), prepared
  statements, multiple result sets, cancellation, transactions;
- the common types: integers, `bit`, `real`/`float`, `decimal`/`numeric`/`money`
  (as exact decimals), `char`/`varchar`/`nchar`/`nvarchar`, `binary`/`varbinary`,
  `date`/`time`/`datetime2`/`datetimeoffset`/`datetime`, `uniqueidentifier`;
- a connection pool and struct mapping.

Later: `sql_variant`, CLR types (`hierarchyid`, `geometry`), `varchar` in the
double-byte code pages (Japanese, Chinese, Korean collations), bulk insert, a
[ddbc](https://github.com/buggins/ddbc) driver and a
[hibernated](https://github.com/buggins/hibernated) dialect, integrated
authentication.

It builds on [dbwire](https://github.com/buggins/dbwire), the pure-D building
blocks shared with [clickhoused](https://github.com/buggins/clickhoused):
transports for threads and fibers, TLS with OpenSSL loaded at run time,
exact decimals, connection pools.

Requires a D frontend 2.097 or newer (DMD 2.097+, LDC 1.27+, GDC 12+).

## Disclaimer

This is an unofficial project, not affiliated with, endorsed or sponsored by
Microsoft. "Microsoft" and "SQL Server" are trademarks of the Microsoft group of
companies. The protocol is implemented from Microsoft's published
specification, [[MS-TDS]](https://learn.microsoft.com/openspecs/windows_protocols/ms-tds/).

## License

[Boost Software License 1.0](LICENSE).
