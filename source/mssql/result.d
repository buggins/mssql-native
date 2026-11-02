/++
The rows of a query: `QueryResult`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.result;

import mssql.connection : Connection;
import mssql.exception : ClientException;
import mssql.protocol.tokens : Done, TokenType;
import mssql.types.typeinfo : ColumnInfo, ValueRef, readColumnMetadata;
import mssql.protocol.rpc : OutputParameter;
import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.typecons : Nullable;
import std.variant : Variant;
import dbwire.types.decimal : Decimal;
import mssql.value : Value;

/// The row count of one statement (a DONE or DONEINPROC token with a count).
struct StatementCount
{
    /// The statement's command, e.g. `Command.select`, `Command.insert`.
    ushort command;
    /// Rows returned (SELECT) or affected (INSERT, UPDATE, DELETE, ...).
    ulong rows;
}

/// Command codes of `StatementCount.command` (the token's CurCmd).
enum Command : ushort
{
    select = 0xC1, /// SELECT
    insert = 0xC3, /// INSERT
    delete_ = 0xC4, /// DELETE
    update = 0xC5, /// UPDATE
    merge = 0x117, /// MERGE
}

/++
The rows of a query, read one at a time from the server.

Use it as an input range (`foreach (row; conn.query(sql))`: `front` is the
result itself, positioned on the current row) or with `next()`; don't mix the
two. The getters read the current row; column indexes are 0-based. A NULL
gives the getter's zero value (`0`, `null`, `T.init`): check `isNull` to tell
NULL apart. A getter that can't convert the column's type throws a
`ClientException`.

A result from `Connection.query` holds the first result set of the batch:
when its rows end, the rest of the batch (later statements and result sets) is
read and discarded, which may throw a `ServerException` for a later statement.
A result from `Connection.queryMultiple` or `Connection.callProcedure` holds
all result sets: `nextResult` moves to the next one.

The connection stays busy until the whole response is read: all rows (of all
result sets for `queryMultiple`), `close` (which reads the rest) or `cancel`
(which stops the batch).
+/
final class QueryResult
{
    private Connection conn;
    private ColumnInfo[] columnList; // the current result set's columns
    private ColumnInfo[] readingColumns; // the columns of the rows being read
    private ColumnInfo[] pendingColumns; // the next result set, read ahead (multiple result sets)
    private bool hasPending;
    private bool multiple; // all result sets, not only the first
    private bool haveResultSet; // the current result set exists
    private ubyte[] rowData;
    private ValueRef[] values;
    private ubyte[] skippedData; // rows of later result sets
    private ValueRef[] skippedValues;
    private bool rowReady; // a row is loaded and not consumed
    private bool rowsEnded; // the current result set is over
    private bool finished; // the whole response is read
    private bool positioned; // next() was called
    private ulong rowsRead;
    private OutputParameter[] outputList;
    private int statusValue;
    private bool hasStatus;
    private StatementCount[] countList;
    private bool wasCancelled;
    private void delegate(const(OutputParameter)[] outputs) @safe onFinished; // e.g. a prepared statement's handle

    package this(Connection conn, void delegate(const(OutputParameter)[]) @safe onFinished = null,
            bool multiple = false) @safe
    {
        this.conn = conn;
        this.onFinished = onFinished;
        this.multiple = multiple;
        conn.guarded({ advance(); });
    }

    /// The columns of the current result set (empty if the batch returned no result set).
    @property const(ColumnInfo)[] columns() const @safe pure nothrow
    {
        return columnList;
    }

    /++
    The index of the column called `name` (case-insensitive).

    Throws: `ClientException` if there is no such column.
    +/
    size_t columnIndex(string name) const @safe
    {
        import std.uni : icmp;

        foreach (i, c; columnList)
            if (icmp(c.name, name) == 0)
                return i;
        throw new ClientException("No column '" ~ name ~ "' in the result");
    }

    /// Whether there are no more rows (reads the next row from the server if needed).
    @property bool empty() @safe
    {
        if (!rowReady && !finished)
            conn.guarded({ advance(); });
        return !rowReady;
    }

    /// The current row: this result.
    @property QueryResult front() @safe
    {
        if (empty)
            throw new ClientException("No current row");
        return this;
    }

    /// Moves to the next row.
    void popFront() @safe
    {
        if (empty)
            throw new ClientException("No current row");
        rowReady = false;
    }

    /++
    Moves to the next row; the first call moves to the first row.

    Returns: false when there are no more rows.
    +/
    bool next() @safe
    {
        if (positioned)
            rowReady = false;
        positioned = true;
        return !empty;
    }

    /// Number of rows of the current result set read so far.
    @property ulong rowCount() const @safe pure nothrow
    {
        return rowsRead;
    }

    /++
    The value in `column` of the current row; valid until the result moves to
    the next row.

    Throws: `ClientException` if there is no current row or no such column.
    +/
    Value opIndex(size_t column) @safe
    {
        const v = valueRef(column);
        return Value(columnList[column].type, v.isNull ? null : bytes(v), v.isNull);
    }

    /// Whether the value in `column` is NULL.
    bool isNull(size_t column) @safe
    {
        return valueRef(column).isNull;
    }

    /// The value in `column`, see `Value.getLong`: integers and `bit`; decimals and money truncated.
    long getLong(size_t column) @safe
    {
        return this[column].getLong();
    }

    /// The value in `column`, see `Value.getInt`.
    int getInt(size_t column) @safe
    {
        return this[column].getInt();
    }

    /// The value in `column`, see `Value.getBool`.
    bool getBool(size_t column) @safe
    {
        return this[column].getBool();
    }

    /// The value in `column`, see `Value.getDouble`: floats, integers, decimals and money.
    double getDouble(size_t column) @safe
    {
        return this[column].getDouble();
    }

    /// The value in `column`, see `Value.getDecimal`: decimals, money and integers, exactly.
    Decimal getDecimal(size_t column) @safe
    {
        return this[column].getDecimal();
    }

    /// The value in `column`, see `Value.getString`: the text SQL Server writes.
    string getString(size_t column) @safe
    {
        return this[column].getString();
    }

    /// The value in `column`, see `Value.getBytes`: the raw bytes (a copy).
    ubyte[] getBytes(size_t column) @safe
    {
        return this[column].getBytes();
    }

    /// The value in `column`, see `Value.getDate`.
    Date getDate(size_t column) @safe
    {
        return this[column].getDate();
    }

    /// The value in `column`, see `Value.getTime`.
    TimeOfDay getTime(size_t column) @safe
    {
        return this[column].getTime();
    }

    /// The value in `column`, see `Value.getDuration`: time of day, exact.
    Duration getDuration(size_t column) @safe
    {
        return this[column].getDuration();
    }

    /// The value in `column`, see `Value.getDateTime`.
    DateTime getDateTime(size_t column) @safe
    {
        return this[column].getDateTime();
    }

    /// The value in `column`, see `Value.getSysTime`: exact; UTC for types without an offset.
    SysTime getSysTime(size_t column) @safe
    {
        return this[column].getSysTime();
    }

    /// The value in `column`, see `Value.getUUID`.
    UUID getUUID(size_t column) @safe
    {
        return this[column].getUUID();
    }

    /// The value in `column`, see `Value.getVariant`: the natural D type.
    Variant getVariant(size_t column) @safe
    {
        return this[column].getVariant();
    }

    /++
    The output parameters, in their order: values of parameters passed with
    `Parameter.output`, and of stored procedures' `OUTPUT` parameters.

    Throws: `ClientException` until the whole response is read (all rows, or `close`).
    +/
    @property const(OutputParameter)[] outputs() const @safe
    {
        checkFinished();
        return outputList;
    }

    /++
    The return status of the stored procedure (`RETURN n`); null for queries,
    which are not procedure calls.

    Throws: `ClientException` until the whole response is read (all rows, or `close`).
    +/
    @property Nullable!int returnStatus() const @safe
    {
        checkFinished();
        return hasStatus ? Nullable!int(statusValue) : Nullable!int.init;
    }

    /++
    Moves to the next result set of a result from `queryMultiple` or
    `callProcedure`, discarding the rest of the current one. Statements
    without a result set (INSERT, SET, ...) are skipped; their row counts are
    in `counts`.

    Returns: false when there are no more result sets (the response is then
    read to its end, and the connection released); always false for a result
    from `query`, whose later result sets are discarded.
    Throws: `ServerException` if a statement of the batch failed, when the
    response ends.
    +/
    bool nextResult() @safe
    {
        rowReady = false;
        rowsEnded = true;
        positioned = false;
        conn.guarded({
            while (!finished && !hasPending)
                step();
        });
        if (!hasPending)
            return false;
        columnList = pendingColumns;
        pendingColumns = null;
        hasPending = false;
        haveResultSet = true;
        rowsEnded = false;
        rowsRead = 0;
        return true;
    }

    /++
    The row counts of the statements read so far, in order: rows returned by
    SELECT, rows affected by INSERT, UPDATE, DELETE, MERGE (none while `SET
    NOCOUNT ON`).
    +/
    @property const(StatementCount)[] counts() const @safe pure nothrow
    {
        return countList;
    }

    /// The number of rows inserted, updated, deleted or merged by the statements read so far.
    @property ulong recordsAffected() const @safe pure nothrow
    {
        ulong n;
        foreach (c; countList)
            if (c.command != Command.select)
                n += c.rows;
        return n;
    }

    /// Whether the batch was cancelled (`cancel`, or `Connection.cancel` from another thread or task).
    @property bool cancelled() const @safe pure nothrow
    {
        return wasCancelled;
    }

    /++
    Reads the rest of the response and releases the connection; remaining rows
    and later result sets are discarded. The statements of the batch still run
    to their end (use `cancel` to stop them).

    Throws: `ServerException` if a statement of the batch failed.
    +/
    void close() @safe
    {
        rowReady = false;
        rowsEnded = true;
        hasPending = false;
        multiple = false; // later result sets are discarded
        if (!finished)
            conn.guarded({ advance(); });
    }

    /++
    Stops the batch on the server (an attention request) and discards the rest
    of the response; then the connection is ready. Statements that already ran
    keep their effects (unless a transaction is rolled back). Errors of the
    batch are not reported.
    +/
    void cancel() @safe
    {
        rowReady = false;
        rowsEnded = true;
        hasPending = false;
        multiple = false;
        if (finished)
            return;
        conn.cancel();
        conn.guarded({ advance(); });
    }

    private void checkFinished() const @safe
    {
        if (!finished)
            throw new ClientException(
                    "Output parameters and the return status are available after all rows are read or close()");
    }

    private ValueRef valueRef(size_t column) @safe
    {
        if (!rowReady)
            throw new ClientException("No current row");
        if (column >= values.length)
            throw new ClientException(
                    "Column index " ~ toText(column) ~ " out of range (" ~ toText(
                    values.length) ~ " columns)");
        return values[column];
    }

    private const(ubyte)[] bytes(const ValueRef v) const @safe pure nothrow
    {
        return rowData[v.offset .. v.offset + v.length];
    }

    /++
    Reads up to the next row of the current result set; after its last row, to
    the next result set (multiple result sets) or to the end of the response.
    +/
    private void advance() @safe
    {
        while (!rowReady && !finished && !hasPending)
            step();
    }

    /// Reads one event of the response.
    private void step() @safe
    {
        Done done;
        const event = conn.nextEvent(done);
        final switch (event)
        {
        case Connection.Event.metadata:
            readingColumns = readColumnMetadata(conn.reader);
            if (!haveResultSet && !rowsEnded)
            {
                columnList = readingColumns; // the first result set
                haveResultSet = true;
            }
            else if (multiple)
            {
                pendingColumns = readingColumns; // the next result set: stop here
                hasPending = true;
                rowsEnded = true;
            }
            else
                rowsEnded = true; // a later result set: its rows are discarded
            break;
        case Connection.Event.row:
        case Connection.Event.nbcRow:
            const nullBitmap = event == Connection.Event.nbcRow;
            if (haveResultSet && !rowsEnded)
            {
                conn.readRow(columnList, nullBitmap, rowData, values);
                rowReady = true;
                rowsRead++;
            }
            else
                conn.readRow(readingColumns, nullBitmap, skippedData, skippedValues);
            break;
        case Connection.Event.done:
            if (haveResultSet)
                rowsEnded = true; // the DONE of the current result set's statement
            if (done.hasCount && done.token != TokenType.doneProc)
                countList ~= StatementCount(done.command, done.rowCount);
            if (conn.finishIfFinal(done))
            {
                finished = true;
                wasCancelled = done.attention;
                outputList = conn.responseOutputs;
                hasStatus = conn.responseHasStatus;
                statusValue = conn.responseStatus;
                if (onFinished !is null)
                    onFinished(outputList);
            }
            break;
        }
    }
}

private string toText(T)(T value) @safe pure
{
    import std.conv : to;

    return value.to!string;
}
