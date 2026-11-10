/++
Benchmark cases: queries, requests with parameters, prepared statements,
`insert`, bulk loads and value conversions, against the in-memory
`FakeServer` or directly on the decoders.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.cases;

import core.time : Duration;
import std.datetime.date : Date, DateTime;
import std.datetime.systime : SysTime;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;

import dbwire.io.transport : Transport;
import dbwire.types.decimal : Decimal;
import mssql;
import mssql.params : Parameter, rewritePlaceholders;
import mssql.types.typeinfo : TdsType, TypeInfo, ValueFormat;
import mssql.value : Value;

import benchmarks.fakeserver;
import benchmarks.runner : BenchCase, Prepared;

/// All cases.
BenchCase[] allCases()
{
    return queryCases() ~ requestCases() ~ valueCases() ~ parameterCases();
}

private:

// A check that release builds keep (they drop asserts, and with them the work inside).
void check(bool ok) @safe
{
    if (!ok)
        throw new Exception("benchmark check failed");
}

// A connection to `server`.
Connection connect(FakeServer server)
{
    ConnectionOptions o;
    o.user = "bench";
    o.password = "bench";
    o.encrypt = false;
    Transport factory(string, ushort, Duration) @safe
    {
        return server;
    }

    o.transportFactory = &factory;
    return new Connection(o);
}

// A fake server answering every request with `tokens`, and a connection to it.
Connection connectAnswering(const(ubyte)[] tokens)
{
    auto server = new FakeServer;
    const(ubyte)[] answer(MessageType, const(ubyte)[]) @safe
    {
        return tokens;
    }

    server.respond = &answer;
    return connect(server);
}

// --- token streams ---

immutable nvarchar100 = cast(immutable(ubyte)[])[0xE7, 200, 0, 0x09, 0x04, 0xD0, 0x00, 0x34];

// int not null, bigint, nvarchar(100), decimal(18,2), datetime2(7), float, bit, int
immutable Col[] rowColumns = [
    Col("id", [0x38], 0x0020), Col("big", [0x26, 8]), Col("name", nvarchar100),
    Col("amount", [0x6A, 9, 18, 2]),
    Col("created", [0x2A, 7]), Col("ratio", [0x6D, 8]), Col("flag", [0x68, 1]),
    Col("maybe", [0x26, 4])
];

// `rows` rows of `rowColumns`; with `nbc`, NBCROW tokens with the last column NULL
const(ubyte)[] rowsResponse(size_t rows, bool nbc = false) @safe
{
    Tokens t;
    t.columns(rowColumns);
    foreach (i; 0 .. rows)
    {
        t.u8(nbc ? 0xD2 : 0xD1);
        if (nbc)
            t.u8(0x80); // column 7 NULL
        t.u32(cast(uint) i);
        t.u8(8);
        t.u64(1_000_000_000_000 + i);
        const name = "customer name 12";
        t.u16(cast(uint) name.length * 2);
        t.utf16(name);
        t.bytes([9, 1]); // decimal: length, positive
        t.u64(12_345 + i);
        t.u8(8);
        t.bytes([0x87, 0xEE, 0x97, 0x76, 0x69, 0x63, 0x46, 0x0B]); // 2024-01-31 12:34:56.1234567
        t.u8(8);
        t.bytes([0x9A, 0x99, 0x99, 0x99, 0x99, 0x99, 0xB9, 0x3F]); // 0.1
        t.bytes([1, 1]);
        if (!nbc)
        {
            t.u8(4);
            t.u32(7);
        }
    }
    t.done(0xFD, 0x10, 0xC1, rows);
    return t.b;
}

// sp_executesql: DONEINPROC with a count, RETURNSTATUS, DONEPROC
const(ubyte)[] execResponse(ulong rows) @safe
{
    Tokens t;
    t.done(0xFF, 0x11, 0xC5, rows);
    t.u8(0x79);
    t.u32(0);
    t.done(0xFE, 0x00, 0xE0, 0);
    return t.b;
}

// sp_prepexec: as `execResponse`, plus the handle (RETURNVALUE of an int)
const(ubyte)[] prepExecResponse() @safe
{
    Tokens t;
    t.done(0xFF, 0x11, 0xC5, 1);
    t.u8(0x79);
    t.u32(0);
    t.u8(0xAC); // RETURNVALUE: ordinal, name, status, user type, flags, intN(4), value 1
    t.u16(0);
    t.u8(0);
    t.u8(1);
    t.u32(0);
    t.u16(0);
    t.bytes([0x26, 4, 4, 1, 0, 0, 0]);
    t.done(0xFE, 0x00, 0xE0, 0);
    return t.b;
}

const(ubyte)[] doneResponse(ulong rows) @safe
{
    Tokens t;
    t.done(0xFD, 0x10, 0xC3, rows);
    return t.b;
}

// BEGIN TRANSACTION (descriptor 1) and COMMIT TRANSACTION
const(ubyte)[] transactionResponse(bool begin) @safe
{
    Tokens t;
    t.u8(0xE3);
    t.u16(11);
    t.u8(begin ? 8 : 9);
    t.u8(begin ? 8 : 0);
    if (begin)
        t.u64(1);
    t.u8(begin ? 0 : 8);
    if (!begin)
        t.u64(1);
    t.done(0xFD, 0, 0xC4, 0);
    return t.b;
}

// One nvarchar(max) value of `bytes` bytes in `chunk`-byte PLP chunks
const(ubyte)[] plpResponse(size_t bytes, size_t chunk) @safe
{
    Tokens t;
    t.columns([Col("doc", [0xE7, 0xFF, 0xFF, 0x09, 0x04, 0xD0, 0x00, 0x34])]);
    t.u8(0xD1);
    t.u64(bytes);
    for (size_t left = bytes; left;)
    {
        const n = left < chunk ? left : chunk;
        t.u32(cast(uint) n);
        foreach (i; 0 .. n / 2)
            t.bytes([cast(ubyte)('a' + i % 26), 0]);
        left -= n;
    }
    t.u32(0);
    t.done(0xFD, 0x10, 0xC1, 1);
    return t.b;
}

struct RowStruct
{
    int id;
    long big;
    string name;
    Decimal amount;
    DateTime created;
    double ratio;
    bool flag;
    Nullable!int maybe;
}

struct Order
{
    int id;
    string name;
    Decimal amount;
    DateTime created;
    double ratio;
}

// --- queries ---

BenchCase[] queryCases()
{
    BenchCase[] cases;
    cases ~= BenchCase("query/rows", (size_t rows) {
        auto conn = connectAnswering(rowsResponse(rows));
        void run()
        {
            size_t n;
            foreach (r; conn.query("SELECT ..."))
                n++;
            check(n == rows);
        }

        return Prepared(rows, 0, &run);
    }, 100_000);
    cases ~= BenchCase("query/rows NBCROW", (size_t rows) {
        auto conn = connectAnswering(rowsResponse(rows, true));
        void run()
        {
            size_t n;
            foreach (r; conn.query("SELECT ..."))
                n++;
            check(n == rows);
        }

        return Prepared(rows, 0, &run);
    }, 100_000);
    cases ~= BenchCase("query/rows+getters", (size_t rows) {
        auto conn = connectAnswering(rowsResponse(rows));
        void run()
        {
            long sum;
            foreach (r; conn.query("SELECT ..."))
            {
                sum += r.getInt(0) + r.getLong(1) + r.getString(2).length + r.getDecimal(3).toLong();
                sum += r.getDateTime(4).hour + cast(long) r.getDouble(5) + r.getBool(6) + r.isNull(7);
            }
            check(sum != 0);
        }

        return Prepared(rows, 0, &run);
    }, 100_000);
    cases ~= BenchCase("query/rows getString", (size_t rows) {
        auto conn = connectAnswering(rowsResponse(rows));
        void run()
        {
            size_t length;
            foreach (r; conn.query("SELECT ..."))
                foreach (c; 0 .. rowColumns.length)
                    length += r.getString(c).length;
            check(length > 0);
        }

        return Prepared(rows, 0, &run);
    }, 100_000);
    cases ~= BenchCase("query/rows getDouble, getLong of decimal", (size_t rows) {
        auto conn = connectAnswering(rowsResponse(rows));
        void run()
        {
            double sum = 0;
            foreach (r; conn.query("SELECT ..."))
                sum += r.getDouble(3) + r.getLong(3);
            check(sum > 0);
        }

        return Prepared(rows, 0, &run);
    }, 100_000);
    cases ~= BenchCase("query/query!T", (size_t rows) {
        auto conn = connectAnswering(rowsResponse(rows));
        void run()
        {
            long sum;
            foreach (r; conn.query!RowStruct("SELECT ..."))
                sum += r.id;
            check(sum >= 0);
        }

        return Prepared(rows, 0, &run);
    }, 100_000);
    cases ~= BenchCase("query/queryValue with 1 parameter (per call)", (size_t rows) {
        auto conn = connectAnswering(rowsResponse(1));
        void run()
        {
            long sum;
            foreach (i; 0 .. rows)
                sum += conn.queryValue!int("SELECT id FROM t WHERE id = ?", 5);
            check(sum == 0);
        }

        return Prepared(rows, 0, &run);
    }, 50_000);
    cases ~= BenchCase("query/1 MB nvarchar(max) getString (per value)", (size_t rows) {
        auto conn = connectAnswering(plpResponse(1 << 20, 8000));
        void run()
        {
            foreach (i; 0 .. rows)
                foreach (r; conn.query("SELECT ..."))
                    check(r.getString(0).length == 1 << 19);
        }

        return Prepared(rows, 0, &run);
    }, 50);
    cases ~= BenchCase("query/column metadata, 8 columns (per query)", (size_t rows) {
        Tokens t;
        t.columns(rowColumns);
        t.done(0xFD, 0x10, 0xC1, 0);
        auto conn = connectAnswering(t.b);
        void run()
        {
            foreach (i; 0 .. rows)
                foreach (r; conn.query("SELECT ..."))
                {
                }
        }

        return Prepared(rows, 0, &run);
    }, 50_000);
    return cases;
}

// --- requests with parameters, insert, bulk loads ---

enum updateSql = "UPDATE t SET name = ?, amount = ?, created = ?, ratio = ? WHERE id = ?";

BenchCase[] requestCases()
{
    BenchCase[] cases;
    const amount = Decimal.fromString("123.45");
    const created = DateTime(2024, 1, 31, 12, 34, 56);
    cases ~= BenchCase("exec/5 parameters (per call)", (size_t rows) {
        auto conn = connectAnswering(execResponse(1));
        void run()
        {
            ulong n;
            foreach (i; 0 .. rows)
                n += conn.exec(updateSql, "customer name", amount, created, 2.5, 42);
            check(n == rows);
        }

        return Prepared(rows, 0, &run);
    }, 50_000);
    cases ~= BenchCase("exec/1 int parameter (per call)", (size_t rows) {
        auto conn = connectAnswering(execResponse(1));
        void run()
        {
            ulong n;
            foreach (i; 0 .. rows)
                n += conn.exec("DELETE FROM t WHERE id = ?", 42);
            check(n == rows);
        }

        return Prepared(rows, 0, &run);
    }, 100_000);
    cases ~= BenchCase("exec/batch without parameters (per call)", (size_t rows) {
        auto conn = connectAnswering(doneResponse(1));
        void run()
        {
            ulong n;
            foreach (i; 0 .. rows)
                n += conn.exec("DELETE FROM t WHERE id = 42");
            check(n == rows);
        }

        return Prepared(rows, 0, &run);
    }, 100_000);
    cases ~= BenchCase("exec/prepared, 5 parameters (per call)", (size_t rows) {
        auto server = new FakeServer;
        bool prepared;
        const(ubyte)[] answer(MessageType, const(ubyte)[]) @safe
        {
            scope (exit)
                prepared = true;
            return prepared ? execResponse(1) : prepExecResponse();
        }

        server.respond = &answer;
        auto conn = connect(server);
        auto statement = conn.prepare(updateSql);
        statement.exec("customer name", amount, created, 2.5, 42);
        const execTokens = execResponse(1);
        const(ubyte)[] same(MessageType, const(ubyte)[]) @safe
        {
            return execTokens;
        }

        server.respond = &same;
        void run()
        {
            ulong n;
            foreach (i; 0 .. rows)
                n += statement.exec("customer name", amount, created, 2.5, 42);
            check(n == rows);
        }

        return Prepared(rows, 0, &run);
    }, 50_000);
    cases ~= BenchCase("insert/structs, 5 fields", (size_t rows) {
        Order[] orders;
        foreach (i; 0 .. rows)
            orders ~= Order(cast(int) i, "customer name", amount, created, 0.25);
        auto server = new FakeServer;
        const begin = transactionResponse(true);
        const commit = transactionResponse(false);
        const inserted = execResponse(400);
        const(ubyte)[] answer(MessageType type, const(ubyte)[] payload) @safe
        {
            if (type == MessageType.rpc)
                return inserted;
            const sql = batchText(payload);
            return sql == "BEGIN TRANSACTION" ? begin : commit;
        }

        server.respond = &answer;
        auto conn = connect(server);
        void run()
        {
            conn.insert("orders", orders);
        }

        return Prepared(rows, 0, &run);
    }, 20_000);
    cases ~= BenchCase("bulk/addRow, 5 columns", (size_t rows) {
        auto server = new FakeServer;
        const meta = bulkMetadata();
        const done = doneResponse(rows);
        const(ubyte)[] answer(MessageType type, const(ubyte)[] payload) @safe
        {
            return type == MessageType.batch && batchText(payload)[0 .. 6] == "SELECT" ? meta : done;
        }

        server.respond = &answer;
        auto conn = connect(server);
        void run()
        {
            auto b = conn.bulkInsert("orders", ["id", "name", "amount", "created", "ratio"]);
            foreach (i; 0 .. rows)
                b.addRow(cast(int) i, "customer name", amount, created, 0.25);
            check(b.finish() == rows);
        }

        return Prepared(rows, 0, &run);
    }, 50_000);
    cases ~= BenchCase("bulk/structs, 5 fields", (size_t rows) {
        Order[] orders;
        foreach (i; 0 .. rows)
            orders ~= Order(cast(int) i, "customer name", amount, created, 0.25);
        auto server = new FakeServer;
        const meta = bulkMetadata();
        const done = doneResponse(rows);
        const(ubyte)[] answer(MessageType type, const(ubyte)[] payload) @safe
        {
            return type == MessageType.batch && batchText(payload)[0 .. 6] == "SELECT" ? meta : done;
        }

        server.respond = &answer;
        auto conn = connect(server);
        void run()
        {
            check(conn.bulkInsert("orders", orders) == rows);
        }

        return Prepared(rows, 0, &run);
    }, 50_000);
    return cases;
}

const(ubyte)[] bulkMetadata() @safe
{
    Tokens t;
    t.columns([
        Col("id", [0x38], 0x0020), Col("name", nvarchar100), Col("amount", [0x6A, 9, 18, 2]),
        Col("created", [0x2A, 7]), Col("ratio", [0x6D, 8])
    ]);
    t.done(0xFD, 0x10, 0xC1, 0);
    return t.b;
}

// --- single values ---

Value value(TdsType type, uint length, immutable(ubyte)[] bytes, ubyte scale = 0, ubyte precision = 0) @safe
{
    auto t = TypeInfo(type, ValueFormat.byteLength, length);
    t.scale = scale;
    t.precision = precision;
    return Value(t, bytes, false);
}

BenchCase valueCase(T)(string name, Value v, T delegate(ref Value) get)
{
    return BenchCase("value/" ~ name, (size_t rows) {
        void run()
        {
            foreach (i; 0 .. rows)
                cast(void) get(v);
        }

        return Prepared(rows, 0, &run);
    }, 1_000_000);
}

BenchCase[] valueCases()
{
    const decimal = value(TdsType.decimalN, 9, [1, 0x39, 0x30, 0, 0, 0, 0, 0, 0], 2, 18); // 123.45
    const money = value(TdsType.moneyN, 8, [0, 0, 0, 0, 0x4E, 0x61, 0xBC, 0]); // 1234567.8901
    const dt2 = value(TdsType.datetime2N, 8, [0x87, 0xEE, 0x97, 0x76, 0x69, 0x63, 0x46, 0x0B], 7);
    const dto = value(TdsType.datetimeOffsetN, 10, [
        0x87, 0x2A, 0x50, 0x90, 0x97, 0x63, 0x46, 0x0B, 0xB6, 0xFE
    ], 7);
    const date = value(TdsType.dateN, 3, [0x63, 0x46, 0x0B]);
    const datetime = value(TdsType.datetimeN, 8, [0x8D, 0xB1, 0, 0, 0x2F, 0xD3, 0xCF, 0]);
    const guid = value(TdsType.guid, 16, [
        0xFF, 0x19, 0x96, 0x6F, 0x86, 0x8B, 0x11, 0xD0, 0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF
    ]);
    auto binary = Value(TypeInfo(TdsType.bigVarbinary, ValueFormat.ushortLength, 100), new immutable(ubyte)[32], false);
    const float8 = value(TdsType.floatN, 8, [0x8F, 0xC2, 0xF5, 0x28, 0x5C, 0x8F, 0x2A, 0x41]); // 870318.08
    const int4 = value(TdsType.intN, 4, [0x2A, 0, 0, 0]);

    return [
        valueCase("int getString", int4, (ref Value v) => v.getString()),
        valueCase("decimal(18,2) getString", decimal, (ref Value v) => v.getString()),
        valueCase("decimal(18,2) getDouble", decimal, (ref Value v) => v.getDouble()),
        valueCase("decimal(18,2) getLong", decimal, (ref Value v) => v.getLong()),
        valueCase("money getDouble", money, (ref Value v) => v.getDouble()),
        valueCase("money getLong", money, (ref Value v) => v.getLong()),
        valueCase("float getString", float8, (ref Value v) => v.getString()),
        valueCase("datetime2(7) getString", dt2, (ref Value v) => v.getString()),
        valueCase("datetimeoffset(7) getString", dto, (ref Value v) => v.getString()),
        valueCase("datetimeoffset(7) getSysTime", dto, (ref Value v) => v.getSysTime()),
        valueCase("date getString", date, (ref Value v) => v.getString()),
        valueCase("datetime getString", datetime, (ref Value v) => v.getString()),
        valueCase("uniqueidentifier getString", guid, (ref Value v) => v.getString()),
        valueCase("varbinary(32) getString", binary, (ref Value v) => v.getString()),
    ];
}

// --- parameters ---

BenchCase parameterCase(string name, Parameter delegate() make)
{
    return BenchCase("params/" ~ name, (size_t rows) {
        void run()
        {
            foreach (i; 0 .. rows)
                cast(void) make();
        }

        return Prepared(rows, 0, &run);
    }, 1_000_000);
}

BenchCase[] parameterCases()
{
    Variant vInt = 42;
    Variant vDate = Date(2024, 1, 31);
    Variant vUuid = UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff");
    const amount = Decimal.fromLong(12_345);
    const created = DateTime(2024, 1, 31, 12, 34, 56);
    const sysTime = SysTime(created);
    auto cases = [
        parameterCase("Parameter.of Variant int", () => Parameter.of(vInt)),
        parameterCase("Parameter.of Variant Date", () => Parameter.of(vDate)),
        parameterCase("Parameter.of Variant UUID", () => Parameter.of(vUuid)),
        parameterCase("Parameter.of int", () => Parameter.of(42)),
        parameterCase("Parameter.of string", () => Parameter.of("customer name")),
        parameterCase("Parameter.of Decimal", () => Parameter.of(amount)),
        parameterCase("Parameter.of DateTime", () => Parameter.of(created)),
        parameterCase("Parameter.of SysTime", () => Parameter.of(sysTime)),
    ];
    cases ~= BenchCase("params/rewritePlaceholders, 5 placeholders", (size_t rows) {
        void run()
        {
            size_t count;
            foreach (i; 0 .. rows)
                cast(void) rewritePlaceholders(updateSql, count);
            check(count == 5);
        }

        return Prepared(rows, 0, &run);
    }, 1_000_000);
    return cases;
}
