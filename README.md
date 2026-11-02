# mssql-native

A native client for **Microsoft SQL Server** in D: the TDS protocol over TCP,
written in pure D, for ordinary threads (blocking sockets) and vibe.d fibers.
No ODBC, no FreeTDS, no C libraries at build time.

> **Status: 0.2.0.** The API may still change before 1.0;
> the plan is tracked in the
> [roadmap issue](https://github.com/buggins/mssql-native/issues/11), changes
> in the [changelog](CHANGELOG.md).

Add it to your `dub.json`:

```json
"dependencies": {
    "mssql-native": "~>0.2.0"
}
```

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

Structs map to rows, and a pool shares connections between threads or vibe.d
tasks:

```d
struct Order
{
    int id;
    @column("customer_name") string customer;
    Decimal amount;
    Nullable!DateTime shipped;
}

auto pool = new ConnectionPool(
    "Server=db,1433;Database=sales;User Id=app;Password=secret;Max Pool Size=8");
auto conn = pool.lockConnection(); // returned to the pool at the end of the scope
conn.insert("orders", [Order(1, "Ann", Decimal.fromString("9.90"))]);
foreach (o; conn.query!Order("SELECT * FROM orders WHERE amount > ?", 5))
    writeln(o.customer, " ", o.amount);
```

Features:

- SQL Server 2017 and newer (tested on 2017, 2019, 2022);
- TLS (encryption on by default, with certificate verification), SQL logins;
- connection strings in URL style (`sqlserver://...`) or ADO style
  (`Server=...;Database=...`), failover over several hosts;
- queries with `?` parameters (sent with `sp_executesql`), prepared statements,
  stored procedures with output parameters and return status, multiple result
  sets and row counts, cancellation (also from another thread or task),
  transactions with isolation levels and savepoints;
- the types, read and sent exactly: integers, `bit`, `real`/`float`,
  `decimal`/`numeric`/`money` (as dbwire `Decimal`), `char`/`varchar` (in the
  collation's code page, Japanese, Chinese and Korean included) and
  `nchar`/`nvarchar`, `binary`/`varbinary`, the `(max)` types, `xml`,
  `date`/`time`/`datetime2`/`datetimeoffset`/`datetime`/`smalldatetime`,
  `uniqueidentifier`, `sql_variant`, `rowversion`, legacy `text`/`ntext`/`image`;
  CLR types (`hierarchyid`, `geometry`, `geography`) as bytes;
- thread mode (blocking sockets) and fiber mode (vibe-core 1.22 to 2.x), chosen
  automatically;
- a connection pool (sessions reset on reuse), struct mapping (`query!T`,
  `queryRow!T`, `queryValue!T`, `insert`);
- bulk insert (`bulkInsert`: `INSERT BULK` with bulk load data, as `bcp` and
  `SqlBulkCopy` do), values sent in each column's exact type, with batches and
  the `TABLOCK`/`CHECK_CONSTRAINTS`/`FIRE_TRIGGERS`/`KEEP_NULLS` options.

Examples: [`examples/basic`](examples/basic/source/app.d) (`dub run
:example-basic`) and [`examples/vibe`](examples/vibe/source/app.d) (`dub run
:example-vibe`); both read the connection string from `MSSQL_CONNECTION`.

Later: the text of CLR types (`hierarchyid`, `geometry`; read as
bytes now), streaming `(max)` values, a
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
