/++
Column metadata and values on the wire: TYPE_INFO ([MS-TDS] 2.2.5.6),
COLMETADATA, and the value encodings of ROW and NBCROW ([MS-TDS] 2.2.5.2,
2.2.7.4, 2.2.7.15, 2.2.7.20).

Every type is parsed, so that a result set with types this library can't
convert yet still reads correctly: such values are kept as raw bytes.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.types.typeinfo;

import dbwire.io.buffer : BufferedReader;
import mssql.exception : ProtocolException;
import dbwire.charset.utf16 : decodeUtf16le;

/// Data type bytes ([MS-TDS] 2.2.5.4).
enum TdsType : ubyte
{
    null_ = 0x1F, /// NULLTYPE
    int1 = 0x30, /// tinyint
    bit = 0x32, /// bit
    int2 = 0x34, /// smallint
    int4 = 0x38, /// int
    datetime4 = 0x3A, /// smalldatetime
    float4 = 0x3B, /// real
    money = 0x3C, /// money
    datetime = 0x3D, /// datetime
    float8 = 0x3E, /// float
    money4 = 0x7A, /// smallmoney
    int8 = 0x7F, /// bigint
    guid = 0x24, /// uniqueidentifier
    intN = 0x26, /// nullable integer (1, 2, 4 or 8 bytes)
    decimal = 0x37, /// decimal (legacy)
    numeric = 0x3F, /// numeric (legacy)
    bitN = 0x68, /// nullable bit
    decimalN = 0x6A, /// decimal
    numericN = 0x6C, /// numeric
    floatN = 0x6D, /// nullable real or float
    moneyN = 0x6E, /// nullable money or smallmoney
    datetimeN = 0x6F, /// nullable datetime or smalldatetime
    dateN = 0x28, /// date
    timeN = 0x29, /// time(n)
    datetime2N = 0x2A, /// datetime2(n)
    datetimeOffsetN = 0x2B, /// datetimeoffset(n)
    char_ = 0x2F, /// char (legacy)
    varchar = 0x27, /// varchar (legacy)
    binary = 0x2D, /// binary (legacy)
    varbinary = 0x25, /// varbinary (legacy)
    bigVarbinary = 0xA5, /// varbinary(n), varbinary(max)
    bigVarchar = 0xA7, /// varchar(n), varchar(max)
    bigBinary = 0xAD, /// binary(n)
    bigChar = 0xAF, /// char(n)
    nvarchar = 0xE7, /// nvarchar(n), nvarchar(max)
    nchar = 0xEF, /// nchar(n)
    xml = 0xF1, /// xml
    udt = 0xF0, /// CLR user-defined types (hierarchyid, geometry, geography)
    text = 0x23, /// text (legacy)
    image = 0x22, /// image (legacy)
    ntext = 0x63, /// ntext (legacy)
    variant = 0x62, /// sql_variant
}

/// The user type of `timestamp`/`rowversion` columns (sent as `binary(8)`).
enum uint rowversionUserType = 80;

/// How a type's values are framed.
enum ValueFormat
{
    fixed, /// a fixed number of bytes (`TypeInfo.maxLength`), never NULL
    byteLength, /// a 1-byte length; 0 is NULL
    ushortLength, /// a 2-byte length; 0xFFFF is NULL
    textPointer, /// text/ntext/image: a text pointer and timestamp, then a 4-byte length
    longLength, /// a 4-byte length; 0 is NULL (sql_variant)
    plp, /// partially length-prefixed: (max) types, xml, UDTs
    none, /// NULLTYPE: no data
}

/// A collation ([MS-TDS] 2.2.5.1.2): LCID, flags, version and sort id, in 5 bytes.
struct Collation
{
    /// Windows locale id (20 bits).
    uint lcid;
    /// Comparison flags: ignore case (0x01), accent (0x02), kana (0x04), width (0x08), binary (0x10, 0x20).
    ubyte flags;
    /// Collation version (0 to 3).
    ubyte version_;
    /// SQL collation sort id; 0 for Windows collations.
    ubyte sortId;

    /// Whether the collation stores `char`/`varchar` as UTF-8 (`..._UTF8` collations).
    @property bool utf8() const @safe pure nothrow @nogc
    {
        return (flags & 0x40) != 0;
    }

    /// Parses the 5 bytes of a collation.
    static Collation fromBytes(scope const(ubyte)[] b) @safe pure nothrow @nogc
    {
        const info = b[0] | (b[1] << 8) | (b[2] << 16) | (cast(uint) b[3] << 24);
        return Collation(info & 0xFFFFF, cast(ubyte)((info >> 20) & 0xFF), cast(ubyte)(info >> 28), b[4]);
    }
}

/// The type of a column (or parameter): TYPE_INFO.
struct TypeInfo
{
    /// The type byte.
    TdsType type;
    /// How values are framed.
    ValueFormat format;
    /// Maximum size in bytes (the fixed size for fixed types); 0xFFFF for (max) types.
    uint maxLength;
    /// Precision and scale of decimals; scale (fraction digits) of time types.
    ubyte precision;
    /// ditto
    ubyte scale;
    /// Collation of character types.
    Collation collation;
    /// UDT type name (e.g. "hierarchyid"), for UDTs.
    string udtName;
    /// The column's user type (COLMETADATA): 80 for `timestamp`/`rowversion`, 0 for most.
    uint userType;

    /// The SQL Server type name, e.g. `"int"` or `"nvarchar"` (sizes left out).
    @property string name() const @safe pure nothrow
    {
        if (userType == rowversionUserType && type == TdsType.bigBinary)
            return "timestamp";
        switch (type)
        {
        case TdsType.intN:
            return maxLength == 1 ? "tinyint" : maxLength == 2 ? "smallint" : maxLength == 4 ? "int" : "bigint";
        case TdsType.floatN:
            return maxLength == 4 ? "real" : "float";
        case TdsType.moneyN:
            return maxLength == 4 ? "smallmoney" : "money";
        case TdsType.datetimeN:
            return maxLength == 4 ? "smalldatetime" : "datetime";
        case TdsType.udt:
            return udtName.length ? udtName : "udt";
        default:
            return typeName(type);
        }
    }
}

/// The SQL Server name of a type byte, e.g. "int" for `TdsType.int4`.
string typeName(TdsType type) @safe pure nothrow
{
    switch (type)
    {
    case TdsType.null_:
        return "null";
    case TdsType.int1:
        return "tinyint";
    case TdsType.bit:
    case TdsType.bitN:
        return "bit";
    case TdsType.int2:
        return "smallint";
    case TdsType.int4:
    case TdsType.intN:
        return "int";
    case TdsType.int8:
        return "bigint";
    case TdsType.datetime4:
        return "smalldatetime";
    case TdsType.float4:
        return "real";
    case TdsType.float8:
    case TdsType.floatN:
        return "float";
    case TdsType.money:
    case TdsType.moneyN:
        return "money";
    case TdsType.money4:
        return "smallmoney";
    case TdsType.datetime:
    case TdsType.datetimeN:
        return "datetime";
    case TdsType.guid:
        return "uniqueidentifier";
    case TdsType.decimal:
    case TdsType.decimalN:
        return "decimal";
    case TdsType.numeric:
    case TdsType.numericN:
        return "numeric";
    case TdsType.dateN:
        return "date";
    case TdsType.timeN:
        return "time";
    case TdsType.datetime2N:
        return "datetime2";
    case TdsType.datetimeOffsetN:
        return "datetimeoffset";
    case TdsType.char_:
    case TdsType.bigChar:
        return "char";
    case TdsType.varchar:
    case TdsType.bigVarchar:
        return "varchar";
    case TdsType.binary:
    case TdsType.bigBinary:
        return "binary";
    case TdsType.varbinary:
    case TdsType.bigVarbinary:
        return "varbinary";
    case TdsType.nvarchar:
        return "nvarchar";
    case TdsType.nchar:
        return "nchar";
    case TdsType.xml:
        return "xml";
    case TdsType.udt:
        return "udt";
    case TdsType.text:
        return "text";
    case TdsType.image:
        return "image";
    case TdsType.ntext:
        return "ntext";
    case TdsType.variant:
        return "sql_variant";
    default:
        return "type 0x" ~ hexByte(type);
    }
}

/// A result set column, from COLMETADATA.
struct ColumnInfo
{
    /// Column name (may be empty).
    string name;
    /// Its type.
    TypeInfo type;
    /// COLMETADATA flags: nullable (0x0001), identity (0x0010), computed (0x0020), ...
    ushort flags;

    /// Whether the column may hold NULLs.
    @property bool nullable() const @safe pure nothrow @nogc
    {
        return (flags & 0x0001) != 0;
    }
}

/++
Reads a TYPE_INFO.

Throws: `ProtocolException` for an unknown type byte (the stream can't be read
further) or malformed data.
+/
TypeInfo readTypeInfo(BufferedReader r) @safe
{
    TypeInfo t;
    const b = r.readFixed!ubyte();
    t.type = cast(TdsType) b;
    switch (b)
    {
    case TdsType.null_:
        t.format = ValueFormat.none;
        break;
    case TdsType.int1:
    case TdsType.bit:
        t.format = ValueFormat.fixed;
        t.maxLength = 1;
        break;
    case TdsType.int2:
        t.format = ValueFormat.fixed;
        t.maxLength = 2;
        break;
    case TdsType.int4:
    case TdsType.datetime4:
    case TdsType.float4:
    case TdsType.money4:
        t.format = ValueFormat.fixed;
        t.maxLength = 4;
        break;
    case TdsType.money:
    case TdsType.datetime:
    case TdsType.float8:
    case TdsType.int8:
        t.format = ValueFormat.fixed;
        t.maxLength = 8;
        break;
    case TdsType.guid:
    case TdsType.intN:
    case TdsType.bitN:
    case TdsType.floatN:
    case TdsType.moneyN:
    case TdsType.datetimeN:
    case TdsType.char_:
    case TdsType.varchar:
    case TdsType.binary:
    case TdsType.varbinary:
        t.format = ValueFormat.byteLength;
        t.maxLength = r.readFixed!ubyte();
        break;
    case TdsType.decimal:
    case TdsType.numeric:
    case TdsType.decimalN:
    case TdsType.numericN:
        t.format = ValueFormat.byteLength;
        t.maxLength = r.readFixed!ubyte();
        t.precision = r.readFixed!ubyte();
        t.scale = r.readFixed!ubyte();
        break;
    case TdsType.dateN:
        t.format = ValueFormat.byteLength;
        t.maxLength = 3;
        break;
    case TdsType.timeN:
    case TdsType.datetime2N:
    case TdsType.datetimeOffsetN:
        t.format = ValueFormat.byteLength;
        t.scale = r.readFixed!ubyte();
        if (t.scale > 7)
            throw new ProtocolException("Invalid time scale " ~ toText(t.scale));
        break;
    case TdsType.bigVarbinary:
    case TdsType.bigBinary:
        t.maxLength = r.readFixed!ushort();
        t.format = t.maxLength == 0xFFFF ? ValueFormat.plp : ValueFormat.ushortLength;
        break;
    case TdsType.bigVarchar:
    case TdsType.bigChar:
    case TdsType.nvarchar:
    case TdsType.nchar:
        t.maxLength = r.readFixed!ushort();
        t.format = t.maxLength == 0xFFFF ? ValueFormat.plp : ValueFormat.ushortLength;
        t.collation = readCollation(r);
        break;
    case TdsType.text:
    case TdsType.ntext:
        t.format = ValueFormat.textPointer;
        t.maxLength = r.readFixed!uint();
        t.collation = readCollation(r);
        break;
    case TdsType.image:
        t.format = ValueFormat.textPointer;
        t.maxLength = r.readFixed!uint();
        break;
    case TdsType.variant:
        t.format = ValueFormat.longLength;
        t.maxLength = r.readFixed!uint();
        break;
    case TdsType.xml:
        t.format = ValueFormat.plp;
        t.maxLength = 0xFFFF;
        if (r.readFixed!ubyte() != 0) // XML_INFO: a schema collection
        {
            readBVarchar(r); // database
            readBVarchar(r); // owning schema
            readUsVarchar(r); // XML schema collection
        }
        break;
    case TdsType.udt:
        t.format = ValueFormat.plp;
        t.maxLength = r.readFixed!ushort();
        readBVarchar(r); // database
        readBVarchar(r); // schema
        t.udtName = readBVarchar(r);
        readUsVarchar(r); // assembly qualified name
        break;
    default:
        throw new ProtocolException("Unknown data type 0x" ~ hexByte(b) ~ " in the server's response");
    }
    return t;
}

/++
Reads the columns of a COLMETADATA token (after its type byte); empty for
"no metadata" (count 0xFFFF).
+/
ColumnInfo[] readColumnMetadata(BufferedReader r) @safe
{
    const count = r.readFixed!ushort();
    if (count == 0xFFFF)
        return null;
    auto columns = new ColumnInfo[count];
    foreach (ref c; columns)
    {
        const userType = r.readFixed!uint();
        c.flags = r.readFixed!ushort();
        c.type = readTypeInfo(r);
        c.type.userType = userType;
        if (c.type.format == ValueFormat.textPointer)
        {
            // TableName: the parts of the table's name
            foreach (_; 0 .. r.readFixed!ubyte())
                readUsVarchar(r);
        }
        c.name = readBVarchar(r);
    }
    return columns;
}

/// Where a value lies in a row's data.
struct ValueRef
{
    /// Offset of the value's bytes in the row data.
    size_t offset;
    /// Number of bytes.
    size_t length;
    /// Whether the value is NULL.
    bool isNull = true;
}

/++
Reads one value of type `t`, appending its bytes to `data` (PLP chunks are
joined). Values longer than `maxLength` bytes are refused.

Throws: `ProtocolException` for malformed data or a value over `maxLength`.
+/
ValueRef readValue(BufferedReader r, const ref TypeInfo t, ref ubyte[] data, size_t maxLength) @safe
{
    ValueRef v;
    v.offset = data.length;
    size_t length;
    final switch (t.format)
    {
    case ValueFormat.none:
        return v;
    case ValueFormat.fixed:
        length = t.maxLength;
        break;
    case ValueFormat.byteLength:
        length = r.readFixed!ubyte();
        if (length == 0)
            return v;
        break;
    case ValueFormat.ushortLength:
        length = r.readFixed!ushort();
        if (length == 0xFFFF)
            return v;
        break;
    case ValueFormat.longLength:
        length = r.readFixed!uint();
        if (length == 0)
            return v;
        break;
    case ValueFormat.textPointer:
        const pointerLength = r.readFixed!ubyte();
        if (pointerLength == 0)
            return v;
        r.readExactBytes(pointerLength); // text pointer
        r.readExactBytes(8); // timestamp
        length = r.readFixed!uint();
        break;
    case ValueFormat.plp:
        const total = r.readFixed!ulong();
        if (total == ulong.max)
            return v;
        if (total != ulong.max - 1 && total > maxLength)
            throw tooLong(maxLength);
        for (;;)
        {
            const chunk = r.readFixed!uint();
            if (chunk == 0)
                break;
            if (data.length - v.offset + chunk > maxLength)
                throw tooLong(maxLength);
            append(r, data, chunk);
        }
        v.length = data.length - v.offset;
        v.isNull = false;
        return v;
    }
    if (length > maxLength)
        throw tooLong(maxLength);
    append(r, data, length);
    v.length = length;
    v.isNull = false;
    return v;
}

private void append(BufferedReader r, ref ubyte[] data, size_t length) @safe
{
    // grow with the data that arrives, not by a length the server announces
    enum size_t step = 1024 * 1024;
    while (length)
    {
        const n = length < step ? length : step;
        const start = data.length;
        data.length = start + n;
        r.readExact(data[start .. $]);
        length -= n;
    }
}

private ProtocolException tooLong(size_t maxLength) @safe pure
{
    return new ProtocolException(
            "A value in the server's response is longer than the limit of " ~ toText(
            maxLength) ~ " bytes");
}

private Collation readCollation(BufferedReader r) @safe
{
    ubyte[5] b;
    r.readExact(b[]);
    return Collation.fromBytes(b[]);
}

private string readBVarchar(BufferedReader r) @safe
{
    return decodeUtf16le(r.readExactBytes(2 * r.readFixed!ubyte()));
}

private string readUsVarchar(BufferedReader r) @safe
{
    return decodeUtf16le(r.readExactBytes(2 * r.readFixed!ushort()));
}

private string hexByte(ubyte b) @safe pure nothrow
{
    static immutable digits = "0123456789ABCDEF";
    return [digits[b >> 4], digits[b & 15]];
}

private string toText(T)(T value) @safe pure
{
    import std.conv : to;

    return value.to!string;
}

version (unittest)
{
    /// A COLMETADATA token (after its type byte) and an NBCROW, captured from SQL Server 2022 for
    /// SELECT 1 AS a, N'xй' AS b, CAST(NULL AS int) AS c, CAST(1 AS bit) AS d, CAST(5 AS bigint) AS e,
    /// CAST(NULL AS nvarchar(10)) AS f, CAST(7 AS smallint) AS g, CAST(200 AS tinyint) AS h
    package immutable ubyte[] capturedMetadata = [
        0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x38, 0x01, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x20,
        0x00, 0xE7, 0x04, 0x00, 0x09, 0x04, 0xD0, 0x00, 0x34, 0x01, 0x62, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x21,
        0x00, 0x26, 0x04, 0x01, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x68, 0x01, 0x01, 0x64,
        0x00,
        0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x26, 0x08, 0x01, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21,
        0x00,
        0xE7, 0x14, 0x00, 0x09, 0x04, 0xD0, 0x00, 0x34, 0x01, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21,
        0x00,
        0x26, 0x02, 0x01, 0x67, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x26, 0x01, 0x01, 0x68, 0x00
    ];
    /// ditto: the row's null bitmap and values (after the NBCROW type byte)
    package immutable ubyte[] capturedRow = [
        0x24, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x78, 0x00, 0x39, 0x04, 0x01, 0x01, 0x08, 0x05, 0x00,
        0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x07, 0x00, 0x01, 0xC8
    ];
}

///
@safe unittest
{
    import dbwire.io.mock : MockTransport;

    auto t = new MockTransport;
    t.feed(capturedMetadata);
    const columns = readColumnMetadata(new BufferedReader(t));
    assert(columns.length == 8);
    assert(columns[0].name == "a" && columns[0].type.type == TdsType.int4 && !columns[0].nullable);
    assert(columns[1].name == "b" && columns[1].type.name == "nvarchar" && columns[1].type.maxLength == 4);
    assert(columns[1].type.collation == Collation(0x409, 0x0D, 0, 52)); // SQL_Latin1_General_CP1_CI_AS
    assert(columns[2].type.name == "int" && columns[2].nullable);
    assert(columns[3].type.name == "bit" && columns[4].type.name == "bigint");
    assert(columns[6].type.name == "smallint" && columns[7].type.name == "tinyint");
}

@safe unittest
{
    import std.exception : assertThrown;
    import dbwire.io.mock : MockTransport;

    // Values of each format; a PLP value in chunks; limits
    auto t = new MockTransport;
    t.feed([0x00, 0xFF, 0xFF, 0x02, 0x00, 'h', 'i']); // byteLength NULL, ushortLength NULL, "hi"
    t.feed([
        0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1, 0, 0, 0, 'a', 2, 0, 0, 0, 'b', 'c', 0, 0, 0,
        0
    ]);
    t.feed([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]); // PLP NULL
    auto r = new BufferedReader(t);
    ubyte[] data;
    const intN = TypeInfo(TdsType.intN, ValueFormat.byteLength, 4);
    const varchar = TypeInfo(TdsType.bigVarchar, ValueFormat.ushortLength, 10);
    const max = TypeInfo(TdsType.bigVarchar, ValueFormat.plp, 0xFFFF);
    assert(readValue(r, intN, data, 100).isNull && readValue(r, varchar, data, 100).isNull);
    auto v = readValue(r, varchar, data, 100);
    assert(!v.isNull && data[v.offset .. v.offset + v.length] == "hi");
    v = readValue(r, max, data, 100);
    assert(data[v.offset .. v.offset + v.length] == "abc");
    assert(readValue(r, max, data, 100).isNull);

    t = new MockTransport;
    t.feed([0x05, 0x00, 'h', 'e', 'l', 'l', 'o']);
    assertThrown!ProtocolException(readValue(new BufferedReader(t), varchar, data, 4));
    t = new MockTransport;
    t.feed([0x99]);
    assertThrown!ProtocolException(readTypeInfo(new BufferedReader(t)));
}
