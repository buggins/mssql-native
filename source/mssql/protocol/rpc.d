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

With `numberedNames` the parameters are sent as `@p1`, `@p2`, ... (see
`putParameter`), so their own names aren't checked.

Throws: `ClientException` otherwise.
+/
void checkRpc(string name, scope const Parameter[] params, bool numberedNames = false) @safe
{
    import std.utf : codeLength;

    if (codeLength!wchar(name) >= 0xFFFF)
        throw new ClientException("Procedure name too long");
    foreach (ref p; params)
    {
        if (!numberedNames && codeLength!wchar(p.name) > 255)
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

/++
Writes one parameter: name, status, TYPE_INFO and value. String types get
`collation`. A `number` above 0 names it `@p<number>` instead of its own name.
+/
void putParameter(PacketWriter w, const ref Parameter p, Collation collation, size_t number = 0) @safe
{
    import mssql.params : parameterName;

    if (number)
    {
        char[24] name;
        const length = parameterName(number, name);
        w.putByte(cast(ubyte) length);
        w.putUtf16(name[0 .. length]);
    }
    else
    {
        const n = encodeUtf16le(p.name);
        w.putByte(cast(ubyte)(n.length / 2));
        w.put(n);
    }
    w.putByte(p.isOutput ? ParamStatus.byRefValue : 0);
    putTypeInfo(w, p.type, collation);
    if (putValueStart(w, p.type.format, p.isNull, p.data.length))
        w.put(p.data);
    putValueEnd(w, p.type.format, p.isNull);
}

/++
Writes an unnamed `nvarchar` parameter holding `text`, with the same bytes as
`putParameter` of `Parameter.of(text)`: `nvarchar(4000)` up to 8000 bytes of
UTF-16, else `nvarchar(max)`. ASCII text is written without allocating.
+/
void putTextParameter(PacketWriter w, scope const(char)[] text, Collation collation) @safe
{
    import mssql.protocol.packet : isAscii;

    const ascii = isAscii(text);
    const utf16 = ascii ? null : encodeUtf16le(text);
    const length = ascii ? 2 * text.length : utf16.length;
    const max = length > 8000; // as Parameter.of chooses
    const type = TypeInfo(TdsType.nvarchar, max ? ValueFormat.plp : ValueFormat.ushortLength, max ? 0xFFFF : 8000);
    w.putByte(0); // no name
    w.putByte(0); // status
    putTypeInfo(w, type, collation);
    if (putValueStart(w, type.format, false, length))
    {
        if (ascii)
            w.putUtf16(text);
        else
            w.put(utf16);
    }
    putValueEnd(w, type.format, false);
}

// TYPE_INFO of a parameter
private void putTypeInfo(PacketWriter w, const ref TypeInfo type, Collation collation) @safe
{
    w.putByte(type.type);
    switch (type.type)
    {
    case TdsType.dateN:
        break;
    case TdsType.timeN:
    case TdsType.datetime2N:
    case TdsType.datetimeOffsetN:
        w.putByte(type.scale);
        break;
    case TdsType.decimalN:
    case TdsType.numericN:
        w.putByte(cast(ubyte) type.maxLength);
        w.putByte(type.precision);
        w.putByte(type.scale);
        break;
    case TdsType.nvarchar:
    case TdsType.nchar:
    case TdsType.bigVarchar:
    case TdsType.bigChar:
        w.putLE!ushort(cast(ushort) type.maxLength);
        putCollation(w, collation);
        break;
    case TdsType.bigVarbinary:
    case TdsType.bigBinary:
        w.putLE!ushort(cast(ushort) type.maxLength);
        break;
    default:
        w.putByte(cast(ubyte) type.maxLength);
        break;
    }
}

// The length prefix of a value of `length` bytes (PLP: the total, then one chunk); returns whether its bytes follow.
private bool putValueStart(PacketWriter w, ValueFormat format, bool isNull, size_t length) @safe
{
    final switch (format)
    {
    case ValueFormat.byteLength:
        w.putByte(isNull ? 0 : cast(ubyte) length);
        return !isNull;
    case ValueFormat.ushortLength:
        w.putLE!ushort(isNull ? 0xFFFF : cast(ushort) length);
        return !isNull;
    case ValueFormat.plp:
        if (isNull)
        {
            w.putLE!ulong(ulong.max);
            return false;
        }
        w.putLE!ulong(length);
        if (length == 0)
            return false;
        w.putLE!uint(cast(uint) length); // one chunk
        return true;
    case ValueFormat.fixed:
    case ValueFormat.textPointer:
    case ValueFormat.longLength:
    case ValueFormat.none:
        assert(0, "not a parameter value format");
    }
}

// After the value's bytes: the PLP terminator
private void putValueEnd(PacketWriter w, ValueFormat format, bool isNull) @safe
{
    if (format == ValueFormat.plp && !isNull)
        w.putLE!uint(0);
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

// putTextParameter and numbered names write the same bytes as the Parameter-based calls
@safe unittest
{
    import std.array : replicate;
    import dbwire.io.mock : MockTransport;
    import mssql.params : numbered, parameters;
    import mssql.protocol.packet : PacketType;

    const collation = Collation(0x409, 0x0D, 0, 52);
    const(ubyte)[] written(scope void delegate(PacketWriter) @safe write)
    {
        auto t = new MockTransport;
        auto w = new PacketWriter(t, 32_767);
        w.begin(PacketType.rpc);
        write(w);
        w.end();
        return t.written.idup;
    }

    foreach (text; [
        "", "SELECT @p1", "é 😀", "x".replicate(4000), "x".replicate(4001),
        "ж".replicate(4001)
    ])
    {
        void direct(PacketWriter w) @safe
        {
            putTextParameter(w, text, collation);
        }

        void viaParameter(PacketWriter w) @safe
        {
            const p = Parameter.of(text);
            putParameter(w, p, collation);
        }

        assert(written(&direct) == written(&viaParameter));
    }
    const params = parameters(42, "a", 2.5);
    void numberedDirect(PacketWriter w) @safe
    {
        foreach (i, ref p; params)
            putParameter(w, p, collation, i + 1);
    }

    void numberedCopies(PacketWriter w) @safe
    {
        foreach (ref p; numbered(params))
            putParameter(w, p, collation);
    }

    assert(written(&numberedDirect) == written(&numberedCopies));
}
