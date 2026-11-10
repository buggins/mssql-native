/++
Bulk insert: `BulkInserter` sends rows as bulk load data ([MS-TDS] 2.2.6.1),
the fast path that `bcp` and `SqlBulkCopy` use.

Example:
---
auto bulk = conn.bulkInsert("dbo.events", ["id", "name", "created"]);
foreach (i; 0 .. 100_000)
    bulk.addRow(i, "event", Clock.currTime);
writeln(bulk.finish(), " rows");
---

The inserter reads the columns' types first (`SELECT TOP 0`), then sends
`INSERT BULK` and the rows, each value converted to its column's exact type
(see `mssql.types.encode`). Rows stream out as they are added; the server
checks them when the data ends (`finish`, or the end of each batch), and an
error rolls back the batch. The connection is busy until `finish` or `abort`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.bulk;

import mssql.connection : Connection;
import mssql.exception : ClientException;
import mssql.mapping : columnNames, fieldParametersInto;
import mssql.params : Parameter, isParameterArray;
import mssql.types.encode : appendTypeInfo, appendValue, bulkType, declaration;
import mssql.types.typeinfo : TdsType, TypeInfo;
import std.uni : toLower;

/// Options of a bulk insert (the `WITH` options of `INSERT BULK`).
struct BulkOptions
{
    /// Rows per batch: each batch is a separate `INSERT BULK`, committed on its own
    /// (outside a transaction). 0: all rows in one batch.
    size_t batchSize;
    /// Take a table lock for the load (`TABLOCK`): faster, blocks other writers.
    bool tableLock;
    /// Check the table's CHECK and FOREIGN KEY constraints (`CHECK_CONSTRAINTS`).
    bool checkConstraints;
    /// Run the table's INSERT triggers (`FIRE_TRIGGERS`).
    bool fireTriggers;
    /// Keep NULLs in columns that have a default, instead of the default (`KEEP_NULLS`).
    bool keepNulls;
}

/++
Inserts rows into a table with bulk load data; create it with
`Connection.bulkInsert`. Add rows with `addRow` (values in column order) or
`add` (structs whose fields map to the columns, see `mssql.mapping`), then
call `finish`, or `abort` to discard the rows of the current batch.
+/
final class BulkInserter
{
    private Connection conn;
    private ulong lease; // the connection's lease (pooled connections)
    private string table;
    private string[] names;
    private TypeInfo[] types;
    private ushort[] flags; // COLMETADATA flags of the columns, as the server reports them
    private string insertSql;
    private BulkOptions options;
    private ubyte[] row;
    private immutable(string)[] checkedFields; // the fields of the struct type `add` checked last
    private ulong inserted; // rows of finished batches
    private size_t inBatch; // rows sent in the current batch
    private bool sending; // a bulk load message is open
    private bool done;

    package this(Connection conn, string table, const string[] columns, BulkOptions options) @safe
    {
        import std.array : join;
        import mssql.mapping : quoteIdentifier;

        this.conn = conn;
        lease = conn.lease;
        this.table = table;
        this.options = options;
        // the columns' types, as the table has them
        string select = "*";
        if (columns.length)
        {
            string[] quoted;
            foreach (c; columns)
                quoted ~= quoteIdentifier(c);
            select = quoted.join(", ");
        }
        auto meta = conn.query("SELECT TOP 0 " ~ select ~ " FROM " ~ table);
        const infos = meta.columns.dup;
        meta.close();
        // char/varchar data is read in the code page of the declared column: declare the collations
        string[string] collations;
        foreach (c; infos)
            if (c.type.type == TdsType.bigVarchar || c.type.type == TdsType.bigChar)
            {
                collations = columnCollations(conn, table);
                break;
            }
        string[] declarations;
        foreach (c; infos)
        {
            if (!columns.length && ((c.flags & (columnIdentity | columnComputed)) != 0
                    || c.type.userType == timestampUserType))
                continue; // filled in by the server
            names ~= c.name;
            types ~= bulkType(c.type);
            flags ~= c.flags;
            string decl = quoteIdentifier(c.name) ~ " " ~ declaration(types[$ - 1]);
            if (auto collation = toLower(c.name) in collations)
                if (c.type.type == TdsType.bigVarchar || c.type.type == TdsType.bigChar)
                    decl ~= " COLLATE " ~ *collation;
            declarations ~= decl;
        }
        if (names.length == 0)
            throw new ClientException("No columns to insert into " ~ table);
        string[] with_;
        if (options.tableLock)
            with_ ~= "TABLOCK";
        if (options.checkConstraints)
            with_ ~= "CHECK_CONSTRAINTS";
        if (options.fireTriggers)
            with_ ~= "FIRE_TRIGGERS";
        if (options.keepNulls)
            with_ ~= "KEEP_NULLS";
        insertSql = "INSERT BULK " ~ table ~ " (" ~ declarations.join(", ") ~ ")" ~ (with_.length
                ? " WITH (" ~ with_.join(", ") ~ ")" : "");
    }

    /// The columns rows go into, in order.
    @property const(string)[] columns() const @safe pure nothrow
    {
        return names;
    }

    /// Rows added so far (sent, and those of finished batches).
    @property ulong rowCount() const @safe pure nothrow
    {
        return inserted + inBatch;
    }

    /++
    Adds a row: one value per column, in the order of `columns`, converted
    as `Parameter.of` does and then to the column's type; or one `Parameter[]`.

    Throws: `ClientException` if the number of values is wrong or a value
    can't be converted to its column's type (the row is not added, the
    inserter stays usable); `ServerException` when a batch ends with an error.
    +/
    void addRow(Args...)(auto ref Args args)
    {
        static if (isParameterArray!Args)
            addParameters(args[0]);
        else
        {
            Parameter[Args.length] values; // addParameters doesn't keep them
            foreach (i, ref arg; args)
                values[i] = Parameter.of(arg);
            addParameters(values[]);
        }
    }

    /++
    Adds structs (one, or a range of them) as rows: their mapped fields (see
    `mssql.mapping`) go into the columns of the same names.

    Throws: `ClientException` if the inserter's columns are not the struct's
    mapped fields; as `addRow`.
    +/
    void add(T)(auto ref T value) if (is(T == struct))
    {
        static immutable string[] fields = columnNames!T;
        if (checkedFields !is fields) // checked once per struct type in a row
        {
            checkColumns(fields);
            checkedFields = fields;
        }
        Parameter[fields.length] values; // addParameters doesn't keep them
        fieldParametersInto(value, values[]);
        addParameters(values[]);
    }

    /// ditto
    void add(R)(R rows) if (!is(R == struct))
    {
        foreach (ref r; rows)
            add(r);
    }

    private void checkColumns(const string[] fields) @safe
    {
        import std.uni : icmp;

        bool same = fields.length == names.length;
        foreach (i; 0 .. fields.length)
            same = same && icmp(fields[i], names[i]) == 0;
        if (!same)
            throw new ClientException("The struct's fields don't match the columns of the bulk insert: "
                    ~ "create it with Connection.bulkInsert!T, or give the columns in field order");
    }

    private void addParameters(scope const Parameter[] values) @safe
    {
        import std.conv : to;

        checkOpen();
        if (values.length != names.length)
            throw new ClientException(
                    "A row of " ~ values.length.to!string ~ " values for " ~ names.length.to!string
                    ~ " columns");
        row.length = 0;
        (() @trusted => row.assumeSafeAppend())(); // the previous row was sent (putBulkData copies it)
        row ~= 0xD1; // ROW
        foreach (i, ref v; values)
        {
            if (v.isNull && (flags[i] & columnNullable) == 0)
                throw new ClientException("Column '" ~ names[i] ~ "' doesn't take NULLs (NOT NULL)");
            appendValue(row, types[i], v, names[i]);
        }
        if (!sending)
            startBatch();
        conn.putBulkData(row);
        inBatch++;
        if (options.batchSize && inBatch >= options.batchSize)
            endBatch();
    }

    /++
    Sends the remaining rows and ends the insert.

    Returns: the number of rows inserted.
    Throws: `ServerException` if the server refused the rows of the last
    batch (they are not inserted; the connection stays usable).
    +/
    ulong finish() @safe
    {
        if (done)
            return inserted;
        checkOpen();
        done = true;
        if (sending)
            endBatch();
        return inserted;
    }

    /++
    Discards the rows of the current batch: the server ignores the data sent
    for it. Rows of batches already ended stay inserted. The connection is
    then usable again.
    +/
    void abort() @safe
    {
        if (done)
            return;
        done = true;
        // a closed connection, or one returned to its pool: nothing to end (and the original error stays)
        if (sending && conn.isOpen && conn.lease == lease)
        {
            sending = false;
            inBatch = 0;
            conn.abortBulkData();
        }
    }

    private void startBatch() @safe
    {
        conn.exec(insertSql);
        // COLMETADATA: the columns as the data is sent
        ubyte[] meta = [0x81, cast(ubyte) names.length, cast(ubyte)(names.length >> 8)];
        foreach (i, ref t; types)
        {
            meta ~= [0, 0, 0, 0]; // user type
            meta ~= [cast(ubyte) flags[i], cast(ubyte)(flags[i] >> 8)]; // as the server reports them
            appendTypeInfo(meta, t);
            appendName(meta, names[i]);
        }
        conn.beginBulkData(meta);
        sending = true;
    }

    private void endBatch() @safe
    {
        sending = false;
        const rows = inBatch;
        inBatch = 0;
        conn.endBulkData();
        inserted += rows;
    }

    private void checkOpen() const @safe
    {
        if (done)
            throw new ClientException("The bulk insert is finished");
        if (conn.lease != lease)
            throw new ClientException("The bulk insert began before the pooled connection was returned");
    }
}

/++
The collation names of the columns of `table`, by lower-case column name
(`sp_tablecollations_100`, in `tempdb` for temporary tables, in the table's
database for three-part names).
+/
private string[string] columnCollations(Connection conn, string table) @safe
{
    import mssql.mapping : quoteIdentifier;

    const parts = nameParts(table); // unquoted: quoted again for the EXEC (`[my db]..sp_...`)
    string db = parts.length == 3 ? quoteIdentifier(parts[0]) ~ ".." : "";
    if (parts.length && parts[$ - 1].length && parts[$ - 1][0] == '#')
        db = "tempdb..";
    string[string] result;
    auto r = conn.query("EXEC " ~ db ~ "sp_tablecollations_100 ?", table);
    scope (exit)
        r.close();
    while (r.next())
        if (!r.isNull(3))
            result[toLower(r.getString(1))] = r.getString(3);
    return result;
}

/// The parts of a multi-part name (`db.schema.table`), without brackets or quotes.
private string[] nameParts(string name) @safe pure
{
    string[] parts;
    string current;
    for (size_t i = 0; i < name.length; i++)
    {
        const c = name[i];
        if (c == '[' || c == '"')
        {
            const close = c == '[' ? ']' : '"';
            for (i++; i < name.length; i++)
            {
                if (name[i] == close)
                {
                    if (i + 1 < name.length && name[i + 1] == close)
                    {
                        current ~= close;
                        i++;
                        continue;
                    }
                    break;
                }
                current ~= name[i];
            }
        }
        else if (c == '.')
        {
            parts ~= current;
            current = null;
        }
        else
            current ~= c;
    }
    return parts ~ current;
}

///
@safe unittest
{
    assert(nameParts("dbo.orders") == ["dbo", "orders"]);
    assert(nameParts("[my db].[dbo].[a]]b]") == ["my db", "dbo", "a]b"]);
    assert(nameParts("#temp") == ["#temp"] && nameParts("db..t") == ["db", "", "t"]);
}

private enum ushort columnNullable = 0x0001; // COLMETADATA flags
private enum ushort columnIdentity = 0x0010;
private enum ushort columnComputed = 0x0020;
private enum uint timestampUserType = 80;

/// B_VARCHAR: a count of UTF-16 characters, then the characters.
private void appendName(ref ubyte[] buffer, string name) @safe pure
{
    import dbwire.charset.utf16 : encodeUtf16le;

    const n = encodeUtf16le(name);
    if (n.length / 2 > 255)
        throw new ClientException("Column name too long: " ~ name);
    buffer ~= cast(ubyte)(n.length / 2);
    buffer ~= n;
}
