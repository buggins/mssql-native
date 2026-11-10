/++
Remote procedure calls ([MS-TDS] 2.2.6.6): the RPC request, and the
RETURNVALUE token that carries output parameters back (2.2.7.18).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.protocol.rpc;

import dbwire.charset.utf16 : decodeUtf16le, encodeUtf16le;
import dbwire.io.buffer : BufferedReader;
import mssql.exception : ClientException, ProtocolException;
import mssql.params : Parameter;
import mssql.protocol.packet : PacketWriter;
import mssql.types.typeinfo : Collation, TdsType, TypeInfo, ValueFormat, readTypeInfo, readValue;
import mssql.value : Value;

/// Ids of the system procedures that can be called by number ([MS-TDS] 2.2.6.6).
enum ProcId : ushort
{
    executeSql = 10, /// sp_executesql
    prepare = 11, /// sp_prepare
    execute = 12, /// sp_execute
    prepExec = 13, /// sp_prepexec
    unprepare = 15, /// sp_unprepare
}

/// Status flags of an RPC parameter.
enum ParamStatus : ubyte
{
    byRefValue = 0x01, /// an output parameter
    defaultValue = 0x02, /// the procedure's default value
}

/// An output parameter's value, from a RETURNVALUE token.
struct OutputParameter
{
    /// Position of the parameter in the call (0-based).
    ushort ordinal;
    /// The name with its `@` (empty for positional parameters of some calls).
    string name;
    /// The value.
    Value value;
    alias value this;
}

/++
Writes the beginning of an RPC request after ALL_HEADERS: a procedure called
by name, or a system procedure by id (`name` empty).
+/
void putProcedure(PacketWriter w, string name, ushort id) @safe
{
    if (name.length)
    {
        const n = encodeUtf16le(name);
        w.putLE!ushort(cast(ushort)(n.length / 2));
        w.put(n);
    }
    else
    {
        w.putLE!ushort(0xFFFF);
        w.putLE!ushort(id);
    }
    w.putLE!ushort(0); // option flags
}

/++
Checks what `putProcedure` and `putParameter` would write before anything
is sent: the lengths fit their fields (a procedure name 65534 UTF-16 units,
a parameter name 255, a value its 1- or 2-byte length), and each parameter's
value format can be sent.

Throws: `ClientException` otherwise.
+/
void checkRpc(string name, scope const Parameter[] params) @safe
{
    import std.utf : codeLength;

    if (codeLength!wchar(name) >= 0xFFFF)
        throw new ClientException("Procedure name too long");
    foreach (ref p; params)
    {
        if (codeLength!wchar(p.name) > 255)
            throw new ClientException("Parameter name '" ~ p.name ~ "' longer than 255 UTF-16 code units");
        final switch (p.type.format)
        {
        case ValueFormat.fixed:
        case ValueFormat.textPointer:
        case ValueFormat.longLength:
        case ValueFormat.none:
            throw new ClientException("A parameter of type " ~ p.type.name ~ " can't be sent");
        case ValueFormat.byteLength:
            if (p.data.length > 255) // a 1-byte length
                throw new ClientException("A " ~ p.type.name ~ " parameter longer than 255 bytes");
            break;
        case ValueFormat.ushortLength:
            if (p.data.length >= 0xFFFF) // a 2-byte length; 0xFFFF is NULL
                throw new ClientException("A " ~ p.type.name ~ " parameter longer than 65534 bytes");
            break;
        case ValueFormat.plp:
            break;
        }
    }
}

/// Writes one parameter: name, status, TYPE_INFO and value. String types get `collation`.
void putParameter(PacketWriter w, const ref Parameter p, Collation collation) @safe
{
    const n = encodeUtf16le(p.name);
    w.putByte(cast(ubyte)(n.length / 2));
    w.put(n);
    w.putByte(p.isOutput ? ParamStatus.byRefValue : 0);
    // TYPE_INFO
    w.putByte(p.type.type);
    switch (p.type.type)
    {
    case TdsType.dateN:
        break;
    case TdsType.timeN:
    case TdsType.datetime2N:
    case TdsType.datetimeOffsetN:
        w.putByte(p.type.scale);
        break;
    case TdsType.decimalN:
    case TdsType.numericN:
        w.putByte(cast(ubyte) p.type.maxLength);
        w.putByte(p.type.precision);
        w.putByte(p.type.scale);
        break;
    case TdsType.nvarchar:
    case TdsType.nchar:
    case TdsType.bigVarchar:
    case TdsType.bigChar:
        w.putLE!ushort(cast(ushort) p.type.maxLength);
        putCollation(w, collation);
        break;
    case TdsType.bigVarbinary:
    case TdsType.bigBinary:
        w.putLE!ushort(cast(ushort) p.type.maxLength);
        break;
    default:
        w.putByte(cast(ubyte) p.type.maxLength);
        break;
    }
    // value
    final switch (p.type.format)
    {
    case ValueFormat.byteLength:
        w.putByte(p.isNull ? 0 : cast(ubyte) p.data.length);
        break;
    case ValueFormat.ushortLength:
        w.putLE!ushort(p.isNull ? 0xFFFF : cast(ushort) p.data.length);
        break;
    case ValueFormat.plp:
        if (p.isNull)
        {
            w.putLE!ulong(ulong.max);
            return;
        }
        w.putLE!ulong(p.data.length);
        if (p.data.length)
        {
            w.putLE!uint(cast(uint) p.data.length); // one chunk
            w.put(p.data);
        }
        w.putLE!uint(0); // terminator
        return;
    case ValueFormat.fixed:
    case ValueFormat.textPointer:
    case ValueFormat.longLength:
    case ValueFormat.none:
        assert(0, "not a parameter value format");
    }
    if (!p.isNull)
        w.put(p.data);
}

private void putCollation(PacketWriter w, Collation c) @safe
{
    const info = c.lcid | (cast(uint) c.flags << 20) | (cast(uint) c.version_ << 28);
    w.putLE!uint(info);
    w.putByte(c.sortId);
}

/// Reads a RETURNVALUE token (after its type byte).
OutputParameter readReturnValue(BufferedReader r, size_t maxLength) @safe
{
    OutputParameter p;
    p.ordinal = r.readFixed!ushort();
    p.name = decodeUtf16le(r.readExactBytes(2 * r.readFixed!ubyte()));
    r.readFixed!ubyte(); // status: output parameter (1) or user-defined function result (2)
    const userType = r.readFixed!uint();
    r.readFixed!ushort(); // flags
    auto type = readTypeInfo(r);
    type.userType = userType;
    ubyte[] data;
    const v = readValue(r, type, data, maxLength);
    p.value = Value(type, v.isNull ? null : data, v.isNull);
    return p;
}

///
@safe unittest
{
    import dbwire.io.mock : MockTransport;

    // RETURNVALUE of `@out int OUTPUT` = 42 (from SQL Server 2022)
    auto t = new MockTransport;
    t.feed([
        0x01, 0x00, 0x04, '@', 0, 'o', 0, 'u', 0, 't', 0, 0x01, 0, 0, 0, 0, 0x09, 0x00, 0x26, 0x04,
        0x04, 0x2A, 0x00, 0x00, 0x00
    ]);
    const p = readReturnValue(new BufferedReader(t), 1024);
    assert(p.ordinal == 1 && p.name == "@out" && p.getInt() == 42);
}

@safe unittest
{
    import dbwire.io.mock : MockTransport;
    import mssql.params : numbered, parameters;
    import mssql.protocol.packet : PacketType;

    // sp_executesql N'SELECT @p1', N'@p1 int', @p1 = 42 ([MS-TDS] 2.2.6.6)
    auto t = new MockTransport;
    auto w = new PacketWriter(t);
    const collation = Collation(0x409, 0x0D, 0, 52); // SQL_Latin1_General_CP1_CI_AS
    w.begin(PacketType.rpc);
    putProcedure(w, null, ProcId.executeSql);
    const params = parameters("SELECT @p1", "@p1 int") ~ numbered(parameters(42));
    foreach (ref p; params)
        putParameter(w, p, collation);
    w.end();
    const ubyte[] nvarchar4000 = [0xE7, 0x40, 0x1F, 0x09, 0x04, 0xD0, 0x00, 0x34]; // type, max 8000, collation
    ubyte[] expected = [0xFF, 0xFF, 10, 0, 0, 0]; // by id, sp_executesql, no option flags
    const ubyte[] noNameNoStatus = [0, 0];
    expected ~= noNameNoStatus ~ nvarchar4000; // TYPE_INFO
    expected ~= [20, 0]; // 20 bytes
    expected ~= encodeUtf16le("SELECT @p1");
    expected ~= noNameNoStatus ~ nvarchar4000;
    expected ~= [14, 0];
    expected ~= encodeUtf16le("@p1 int");
    expected ~= [3, '@', 0, 'p', 0, '1', 0, 0, 0x26, 4, 4, 42, 0, 0, 0]; // @p1 INTN(4) = 42
    assert(t.written[0] == PacketType.rpc && t.written[1] == 0x01); // end of message
    assert(t.written[8 .. $] == expected);

    // an output nvarchar(max) parameter, NULL: PLP null; and a PLP value in one chunk
    t.clearWritten();
    w.begin(PacketType.rpc);
    auto out_ = Parameter.outputOf!string();
    out_.type = TypeInfo(TdsType.nvarchar, ValueFormat.plp, 0xFFFF);
    putParameter(w, out_, collation);
    const big = Parameter.of(new ubyte[9000]);
    putParameter(w, big, collation);
    w.end();
    const b = t.written[8 .. $];
    // no name, output; nvarchar(max) and collation; PLP NULL
    assert(b[0 .. 5] == [0, 0x01, 0xE7, 0xFF, 0xFF] && b[10 .. 18] == [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    ]);
    // varbinary(max): total length 9000 (0x2328)
    assert(b[18 .. 23] == [0, 0, 0xA5, 0xFF, 0xFF] && b[23 .. 31] == [0x28, 0x23, 0, 0, 0, 0, 0, 0]);
    assert(b[31 .. 35] == [0x28, 0x23, 0, 0] && b[$ - 4 .. $] == [0, 0, 0, 0]); // one chunk, terminator
}
