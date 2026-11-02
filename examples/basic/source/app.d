/++
Basic mssql-native usage: connect, run statements with parameters, insert and
query structs, call a stored procedure, use a prepared statement and a
transaction, bulk insert.

Run with `dub run :example-basic`. The connection string comes from the
`MSSQL_CONNECTION` environment variable, in URL style
(`sqlserver://sa:secret@localhost/master?trust_server_certificate=true`) or
ADO style (`Server=localhost;User Id=sa;Password=secret;TrustServerCertificate=True`).
+/
module app;

import std.datetime : DateTime;
import std.process : environment;
import std.stdio : writefln, writeln;

import mssql;

/// One row of the `#orders` table.
struct Order
{
    /// Order number.
    int id;
    /// Customer; stored in the column `customer_name`.
    @column("customer_name") string customer;
    /// Exact amount.
    Decimal amount;
    /// When it was shipped; NULL while not shipped.
    Nullable!DateTime shipped;
}

void main()
{
    auto conn = new Connection(environment.get("MSSQL_CONNECTION",
            "sqlserver://sa@localhost/master?trust_server_certificate=true"));
    scope (exit)
        conn.close();
    writefln("Connected to SQL Server %s on %s:%s, database %s", conn.serverVersion, conn.host.host,
            conn.host.port, conn.database);

    // A temporary table lives as long as the connection
    conn.exec("CREATE TABLE #orders (id int PRIMARY KEY, customer_name nvarchar(50), "
            ~ "amount decimal(18,2), shipped datetime2(0))");

    // Statements with ? placeholders: values go as typed parameters (sp_executesql)
    conn.exec("INSERT INTO #orders VALUES (?, ?, ?, ?)", 1, "Grüße GmbH", Decimal.fromString("1234.50"),
            DateTime(2026, 1, 15, 9, 30, 0));

    // Structs: fields map to columns by name
    Order[] more;
    foreach (i; 2 .. 6)
        more ~= Order(i, "customer " ~ cast(char)('A' + i), Decimal.fromLong(i * 100));
    writeln("inserted ", conn.insert("#orders", more), " rows");
    foreach (o; conn.query!Order("SELECT * FROM #orders WHERE amount >= ? ORDER BY id", 300))
        writefln("%s  %-12s %10s  %s", o.id, o.customer, o.amount.toFixedString(), o.shipped.isNull ? "-"
                : o.shipped.get.toString());
    writefln("total %s", conn.queryValue!Decimal("SELECT SUM(amount) FROM #orders").toFixedString());

    // Rows one by one, with the getters
    foreach (row; conn.query("SELECT id, customer_name, amount FROM #orders WHERE id < ?", 3))
        writefln("row %s: %s owes %s", row.getInt(0), row.getString(1), row.getString(2));

    // A stored procedure with an OUTPUT parameter and a return status
    conn.exec("CREATE PROCEDURE #count_orders @min decimal(18,2), @n int OUTPUT AS "
            ~ "BEGIN SELECT @n = COUNT(*) FROM #orders WHERE amount >= @min; RETURN 0 END");
    auto call = conn.callProcedure("#count_orders", Decimal.fromLong(200), Parameter.outputOf!int);
    call.close();
    writefln("%s orders of 200 or more (status %s)", call.outputs[0].getInt(), call.returnStatus.get);

    // A prepared statement, run several times in a transaction
    conn.begin();
    auto update = conn.prepare("UPDATE #orders SET amount = amount * ? WHERE id = ?");
    foreach (id; 2 .. 6)
        update.exec(Decimal.fromString("1.1"), id);
    update.close();
    conn.commit();
    writefln("after the update: total %s", conn.queryValue!Decimal("SELECT SUM(amount) FROM #orders").toFixedString());

    // Bulk insert: many rows at once, as bulk load data
    auto bulk = conn.bulkInsert("#orders", ["id", "customer_name", "amount"]);
    foreach (id; 100 .. 10_100)
        bulk.addRow(id, "bulk customer", Decimal.fromLong(id % 100));
    writefln("bulk inserted %s rows; now %s orders", bulk.finish(), conn.queryValue!long(
            "SELECT COUNT(*) FROM #orders"));
}
