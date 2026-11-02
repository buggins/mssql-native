/++
The rows of a query: `QueryResult`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.result;

import mssql.connection : Connection;
import mssql.exception : ClientException;
import mssql.protocol.tokens : Done;
import mssql.types.typeinfo : ColumnInfo, ValueRef, readColumnMetadata;
import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.variant : Variant;
import dbwire.types.decimal : Decimal;
import mssql.types.temporal : Temporal, TemporalKind, decodeTemporal;
import mssql.types.values : decimalValue, floatValue, integerValue, textValue, uuidValue, variantValue;

/++
The rows of the first result set of a query, read one at a time from the
server.

Use it as an input range (`foreach (row; conn.query(sql))`: `front` is the
result itself, positioned on the current row) or with `next()`; don't mix the
two. The getters read the current row; column indexes are 0-based. A NULL
gives the getter's zero value (`0`, `null`, `T.init`): check `isNull` to tell
NULL apart. A getter that can't convert the column's type throws a
`ClientException`.

The connection stays busy until all rows are read or `close` is called. When
the rows end, the rest of the batch (later statements and result sets) is read
and discarded, which may throw a `ServerException` for a later statement.
+/
final class QueryResult
{
    private Connection conn;
    private ColumnInfo[] columnList; // the first result set's columns
    private ColumnInfo[] currentColumns; // the columns of the rows being read
    private bool haveResultSet;
    private ubyte[] rowData;
    private ValueRef[] values;
    private ubyte[] skippedData; // rows of later result sets
    private ValueRef[] skippedValues;
    private bool rowReady; // a row is loaded and not consumed
    private bool rowsEnded; // the first result set is over
    private bool finished; // the whole response is read
    private bool positioned; // next() was called
    private ulong rowsRead;

    package this(Connection conn) @safe
    {
        this.conn = conn;
        conn.guarded({ advance(); });
    }

    /// The columns of the result set (empty if the batch returned no result set).
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

    /// Number of rows read so far.
    @property ulong rowCount() const @safe pure nothrow
    {
        return rowsRead;
    }

    /// Whether the value in `column` is NULL.
    bool isNull(size_t column) @safe
    {
        return value(column).isNull;
    }

    /++
    The value in `column` as a `long`: integers and `bit`; decimals and money
    truncated towards zero.

    Throws: `ClientException` for other types, or if a decimal doesn't fit.
    +/
    long getLong(size_t column) @safe
    {
        const v = value(column);
        return v.isNull ? 0 : integerValue(columnList[column].type, bytes(v));
    }

    /++
    The value in `column` as an `int` (see `getLong`).

    Throws: `ClientException` for other types, or if the value does not fit.
    +/
    int getInt(size_t column) @safe
    {
        const v = getLong(column);
        if (v < int.min || v > int.max)
            throw new ClientException(
                    "Value " ~ toText(v) ~ " of column '" ~ columnList[column].name
                    ~ "' does not fit in an int");
        return cast(int) v;
    }

    /// The value in `column` as a `bool` (see `getLong`: non-zero is true).
    bool getBool(size_t column) @safe
    {
        return getLong(column) != 0;
    }

    /++
    The value in `column` as a `double`: `real`, `float`, integers, decimals and money.

    Throws: `ClientException` for other types.
    +/
    double getDouble(size_t column) @safe
    {
        const v = value(column);
        return v.isNull ? 0 : floatValue(columnList[column].type, bytes(v));
    }

    /++
    The value in `column` as an exact `Decimal`: `decimal`/`numeric` with their
    scale, `money`/`smallmoney` with scale 4, integers with scale 0.

    Throws: `ClientException` for other types.
    +/
    Decimal getDecimal(size_t column) @safe
    {
        const v = value(column);
        return v.isNull ? Decimal.init : decimalValue(columnList[column].type, bytes(v));
    }

    /++
    The value in `column` as text, as SQL Server writes it (see
    `mssql.types.values.textValue`): strings as they are, numbers in decimal,
    dates like `2024-01-31 12:34:56.1234567`.

    Throws: `ClientException` for types without a text form yet.
    +/
    string getString(size_t column) @safe
    {
        const v = value(column);
        return v.isNull ? null : textValue(columnList[column].type, bytes(v));
    }

    /// The raw bytes of the value in `column`, as the server sent them (a copy).
    ubyte[] getBytes(size_t column) @safe
    {
        const v = value(column);
        return v.isNull ? null : bytes(v).dup;
    }

    /++
    The date of the value in `column`: `date`, `datetime2`, `datetimeoffset`
    (its local date), `datetime`, `smalldatetime`.

    Throws: `ClientException` for other types.
    +/
    Date getDate(size_t column) @safe
    {
        Temporal t;
        return temporal(column, t) ? t.date : Date.init;
    }

    /++
    The time of day of the value in `column`, without the fraction of a second
    (see `getDuration`): `time`, `datetime2`, `datetimeoffset` (its local
    time), `datetime`, `smalldatetime`.

    Throws: `ClientException` for other types.
    +/
    TimeOfDay getTime(size_t column) @safe
    {
        Temporal t;
        return temporal(column, t) ? t.timeOfDay : TimeOfDay.init;
    }

    /++
    The time of day of the value in `column` as the exact time since midnight
    (100 ns precision); for the same types as `getTime`.

    Throws: `ClientException` for other types.
    +/
    Duration getDuration(size_t column) @safe
    {
        Temporal t;
        return temporal(column, t) ? t.sinceMidnight : Duration.zero;
    }

    /++
    The value in `column` as a `DateTime`, without the fraction of a second:
    `datetime2`, `datetimeoffset` (its local time), `datetime`,
    `smalldatetime`, `date` (at midnight).

    Throws: `ClientException` for other types.
    +/
    DateTime getDateTime(size_t column) @safe
    {
        Temporal t;
        if (!temporal(column, t))
            return DateTime.init;
        if (t.kind == TemporalKind.time)
            throw new ClientException("Cannot read a time value as a date and time");
        return t.dateTime;
    }

    /++
    The value in `column` as an exact `SysTime`: `datetimeoffset` with a time
    zone of its offset; `datetime2`, `datetime`, `smalldatetime` and `date` (at
    midnight) taken as UTC, as they have no time zone.

    Throws: `ClientException` for other types.
    +/
    SysTime getSysTime(size_t column) @safe
    {
        Temporal t;
        if (!temporal(column, t))
            return SysTime.init;
        if (t.kind == TemporalKind.time)
            throw new ClientException("Cannot read a time value as a point in time");
        return t.sysTime;
    }

    /++
    The `uniqueidentifier` in `column`.

    Throws: `ClientException` for other types.
    +/
    UUID getUUID(size_t column) @safe
    {
        const v = value(column);
        return v.isNull ? UUID.init : uuidValue(columnList[column].type, bytes(v));
    }

    /++
    The value in `column` as a `Variant` of its natural D type (see
    `mssql.types.values.variantValue`); an empty `Variant` for NULL.

    Throws: `ClientException` for types that are not supported yet.
    +/
    Variant getVariant(size_t column) @safe
    {
        const v = value(column);
        return v.isNull ? Variant.init : variantValue(columnList[column].type, bytes(v));
    }

    /++
    Reads the rest of the response and releases the connection; remaining rows
    and later result sets are discarded.

    Throws: `ServerException` if a statement of the batch failed.
    +/
    void close() @safe
    {
        rowReady = false;
        rowsEnded = true;
        if (!finished)
            conn.guarded({ advance(); });
    }

    private ValueRef value(size_t column) @safe
    {
        if (!rowReady)
            throw new ClientException("No current row");
        if (column >= values.length)
            throw new ClientException(
                    "Column index " ~ toText(column) ~ " out of range (" ~ toText(
                    values.length) ~ " columns)");
        return values[column];
    }

    /// Decodes the date/time in `column` into `t`; false for NULL.
    private bool temporal(size_t column, out Temporal t) @safe
    {
        const v = value(column);
        if (v.isNull)
            return false;
        t = decodeTemporal(columnList[column].type, bytes(v));
        return true;
    }

    private const(ubyte)[] bytes(const ValueRef v) const @safe pure nothrow
    {
        return rowData[v.offset .. v.offset + v.length];
    }

    /// Reads up to the next row of the first result set; after its last row, to the end of the response.
    private void advance() @safe
    {
        while (!rowReady && !finished)
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
            currentColumns = readColumnMetadata(conn.reader);
            if (!haveResultSet && !rowsEnded)
            {
                columnList = currentColumns;
                haveResultSet = true;
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
                conn.readRow(currentColumns, nullBitmap, skippedData, skippedValues);
            break;
        case Connection.Event.done:
            if (haveResultSet)
                rowsEnded = true; // the DONE of the first result set's statement
            if (conn.finishIfFinal(done))
                finished = true;
            break;
        }
    }
}

private string toText(T)(T value) @safe pure
{
    import std.conv : to;

    return value.to!string;
}
