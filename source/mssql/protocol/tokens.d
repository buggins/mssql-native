/++
The tokens of server responses ([MS-TDS] 2.2.7), except the result set ones
(COLMETADATA, ROW, NBCROW: see `mssql.types.typeinfo`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.protocol.tokens;

import dbwire.io.buffer : BufferedReader;
import mssql.exception : ProtocolException, ServerMessage;
import mssql.protocol.text : fromUtf16le;

/// Token types ([MS-TDS] 2.2.7).
enum TokenType : ubyte
{
    returnStatus = 0x79, /// RETURNSTATUS
    colMetadata = 0x81, /// COLMETADATA
    tabName = 0xA4, /// TABNAME
    colInfo = 0xA5, /// COLINFO
    order = 0xA9, /// ORDER
    error = 0xAA, /// ERROR
    info = 0xAB, /// INFO
    returnValue = 0xAC, /// RETURNVALUE
    loginAck = 0xAD, /// LOGINACK
    featureExtAck = 0xAE, /// FEATUREEXTACK
    row = 0xD1, /// ROW
    nbcRow = 0xD2, /// NBCROW (row with a null bitmap)
    envChange = 0xE3, /// ENVCHANGE
    sessionState = 0xE4, /// SESSIONSTATE
    sspi = 0xED, /// SSPI
    fedAuthInfo = 0xEE, /// FEDAUTHINFO
    done = 0xFD, /// DONE
    doneProc = 0xFE, /// DONEPROC
    doneInProc = 0xFF, /// DONEINPROC
}

/// Status bits of DONE, DONEPROC and DONEINPROC.
enum DoneStatus : ushort
{
    final_ = 0x000, /// the last DONE of the response
    more = 0x001, /// more results follow
    error = 0x002, /// the statement failed
    inTransaction = 0x004, /// in a transaction (not set by SQL Server)
    count = 0x010, /// `rowCount` is valid
    attention = 0x020, /// acknowledges an attention (cancel)
    rpcInBatch = 0x080, /// not the last RPC of a batch (DONEPROC)
    serverError = 0x100, /// a severe error: the results are to be discarded
}

/// A DONE, DONEPROC or DONEINPROC token.
struct Done
{
    /// Which of the three tokens.
    TokenType token;
    /// `DoneStatus` bits.
    ushort status;
    /// The current command (e.g. 0xC1 for SELECT).
    ushort command;
    /// Rows affected or returned, when `hasCount`.
    ulong rowCount;

    /// Whether more results follow.
    @property bool more() const @safe pure nothrow @nogc
    {
        return (status & DoneStatus.more) != 0;
    }

    /// Whether `rowCount` is valid.
    @property bool hasCount() const @safe pure nothrow @nogc
    {
        return (status & DoneStatus.count) != 0;
    }

    /// Whether this acknowledges an attention (cancel).
    @property bool attention() const @safe pure nothrow @nogc
    {
        return (status & DoneStatus.attention) != 0;
    }

    /// Whether the statement failed.
    @property bool failed() const @safe pure nothrow @nogc
    {
        return (status & (DoneStatus.error | DoneStatus.serverError)) != 0;
    }
}

/// LOGINACK: the server accepted the login.
struct LoginAck
{
    /// The TDS version the server speaks, e.g. `0x74000004`.
    uint tdsVersion;
    /// Server program name, e.g. "Microsoft SQL Server".
    string programName;
    /// Server version: major, minor, build.
    ubyte majorVersion;
    /// ditto
    ubyte minorVersion;
    /// ditto
    ushort build;
}

/// ENVCHANGE types ([MS-TDS] 2.2.7.9).
enum EnvChangeType : ubyte
{
    database = 1, /// current database
    language = 2, /// language
    charset = 3, /// character set (TDS 7.0)
    packetSize = 4, /// packet size
    unicodeSortLocale = 5, /// (TDS 7.0)
    unicodeSortFlags = 6, /// (TDS 7.0)
    collation = 7, /// default collation
    beginTransaction = 8, /// a transaction began: new descriptor
    commitTransaction = 9, /// committed
    rollbackTransaction = 10, /// rolled back
    enlistDtcTransaction = 11, /// enlisted in a DTC transaction
    defectTransaction = 12, /// defected from a transaction
    mirroringPartner = 13, /// database mirroring partner
    promoteTransaction = 15, /// promoted to a DTC transaction
    transactionManagerAddress = 16, /// transaction manager address
    transactionEnded = 17, /// transaction ended
    resetAck = 18, /// session reset acknowledged
    userInstance = 19, /// user instance name
    routing = 20, /// redirect to another server
    enhancedRouting = 21, /// redirect to another server and database
}

/// An ENVCHANGE token.
struct EnvChange
{
    /// What changed.
    EnvChangeType type;
    /// New and old values of the text types (database, language, packet size, ...).
    string newValue;
    /// ditto
    string oldValue;
    /// New and old values of the binary types (collation, transaction descriptors).
    const(ubyte)[] newBytes;
    /// ditto
    const(ubyte)[] oldBytes;
}

/// Reads bounded fields from a token's bytes; out-of-range reads throw `ProtocolException`.
struct ByteParser
{
    /// The bytes.
    const(ubyte)[] data;
    /// Read position.
    size_t pos;
    /// Token name for error messages.
    string what;

    /// Reads `n` bytes.
    const(ubyte)[] bytes(size_t n) @safe pure
    {
        if (n > data.length - pos)
            throw new ProtocolException("Truncated " ~ what ~ " token");
        auto result = data[pos .. pos + n];
        pos += n;
        return result;
    }

    /// Reads a little-endian unsigned integer of `n` bytes.
    ulong unsigned(size_t n) @safe pure
    {
        const b = bytes(n);
        ulong v;
        foreach_reverse (x; b)
            v = (v << 8) | x;
        return v;
    }

    /// Reads a byte.
    ubyte u8() @safe pure
    {
        return bytes(1)[0];
    }

    /// Reads a little-endian `ushort`.
    ushort u16() @safe pure
    {
        return cast(ushort) unsigned(2);
    }

    /// Reads a little-endian `uint`.
    uint u32() @safe pure
    {
        return cast(uint) unsigned(4);
    }

    /// B_VARCHAR: a byte count of UTF-16 characters, then the characters.
    string bVarchar() @safe pure
    {
        return fromUtf16le(bytes(2 * u8()));
    }

    /// US_VARCHAR: a ushort count of UTF-16 characters, then the characters.
    string usVarchar() @safe pure
    {
        return fromUtf16le(bytes(2 * u16()));
    }

    /// B_VARBYTE: a byte count, then the bytes.
    const(ubyte)[] bVarbyte() @safe pure
    {
        return bytes(u8());
    }

    /// Whether everything was read.
    @property bool empty() const @safe pure nothrow @nogc
    {
        return pos == data.length;
    }
}

/// Reads the bytes of a token with a `ushort` length (after its type byte).
const(ubyte)[] readShortToken(BufferedReader r) @safe
{
    return r.readExactBytes(r.readFixed!ushort());
}

/// Reads an ERROR or INFO token (after its type byte).
ServerMessage readMessage(BufferedReader r) @safe
{
    auto p = ByteParser(readShortToken(r), 0, "ERROR/INFO");
    ServerMessage m;
    m.number = cast(int) p.u32();
    m.state = p.u8();
    m.severity = p.u8();
    m.message = p.usVarchar();
    m.serverName = p.bVarchar();
    m.procName = p.bVarchar();
    m.lineNumber = cast(int) p.u32(); // LONG since TDS 7.2
    return m;
}

/// Reads a LOGINACK token (after its type byte).
LoginAck readLoginAck(BufferedReader r) @safe
{
    auto p = ByteParser(readShortToken(r), 0, "LOGINACK");
    LoginAck ack;
    p.u8(); // interface: SQL_TSQL
    // TDSVersion: the server's value, e.g. 0x74000004 (bytes 74 00 00 04)
    const v = p.bytes(4);
    ack.tdsVersion = (v[0] << 24) | (v[1] << 16) | (v[2] << 8) | v[3];
    ack.programName = p.bVarchar();
    ack.majorVersion = p.u8();
    ack.minorVersion = p.u8();
    ack.build = cast(ushort)((p.u8() << 8) | p.u8());
    return ack;
}

/// Reads an ENVCHANGE token (after its type byte).
EnvChange readEnvChange(BufferedReader r) @safe
{
    auto p = ByteParser(readShortToken(r), 0, "ENVCHANGE");
    EnvChange e;
    e.type = cast(EnvChangeType) p.u8();
    switch (e.type)
    {
    case EnvChangeType.database:
    case EnvChangeType.language:
    case EnvChangeType.charset:
    case EnvChangeType.packetSize:
    case EnvChangeType.mirroringPartner:
    case EnvChangeType.userInstance:
        e.newValue = p.bVarchar();
        if (!p.empty)
            e.oldValue = p.bVarchar();
        break;
    case EnvChangeType.routing:
    case EnvChangeType.enhancedRouting:
        e.newBytes = p.bytes(p.data.length - p.pos); // routing data: not followed
        break;
    default:
        // collation, transactions and the rest: B_VARBYTE new value, then old value
        if (!p.empty)
            e.newBytes = p.bVarbyte();
        if (!p.empty)
            e.oldBytes = p.bVarbyte();
        break;
    }
    return e;
}

/// Reads a DONE, DONEPROC or DONEINPROC token (after its type byte `token`).
Done readDone(BufferedReader r, TokenType token) @safe
{
    Done d;
    d.token = token;
    d.status = r.readFixed!ushort();
    d.command = r.readFixed!ushort();
    d.rowCount = r.readFixed!ulong(); // ULONGLONG since TDS 7.2
    return d;
}

/// Skips a FEATUREEXTACK token (after its type byte): features until the terminator.
void skipFeatureExtAck(BufferedReader r) @safe
{
    for (;;)
    {
        const id = r.readFixed!ubyte();
        if (id == 0xFF)
            return;
        r.readExactBytes(r.readFixed!uint());
    }
}

///
@safe unittest
{
    import dbwire.io.mock : MockTransport;
    import mssql.protocol.text : toUtf16le;

    // An ERROR token: Msg 208, Level 16, State 1, Line 1: Invalid object name 'x'.
    const text = toUtf16le("Invalid object name 'x'.");
    const server = toUtf16le("db1");
    ubyte[] body;
    body ~= [208, 0, 0, 0, 1, 16];
    body ~= [cast(ubyte)(text.length / 2), 0];
    body ~= text;
    body ~= cast(ubyte)(server.length / 2);
    body ~= server;
    body ~= [0, 1, 0, 0, 0];
    auto t = new MockTransport;
    t.feed([cast(ubyte)
        body.length, 0]);
    t.feed(body);
    const m = readMessage(new BufferedReader(t));
    assert(m.number == 208 && m.severity == 16 && m.state == 1 && m.lineNumber == 1);
    assert(m.message == "Invalid object name 'x'." && m.serverName == "db1" && m.procName == "");
}

@safe unittest
{
    import std.exception : assertThrown;
    import dbwire.io.mock : MockTransport;

    // ENVCHANGE packet size 4096 -> 8000; DONE with a row count; a truncated token
    auto t = new MockTransport;
    t.feed([
        0x13, 0x00, 0x04, 0x04, '8', 0, '0', 0, '0', 0, '0', 0, 0x04, '4', 0, '0', 0, '9', 0, '6', 0
    ]);
    const e = readEnvChange(new BufferedReader(t));
    assert(e.type == EnvChangeType.packetSize && e.newValue == "8000" && e.oldValue == "4096");

    t = new MockTransport;
    t.feed([0x10, 0x00, 0xC1, 0x00, 3, 0, 0, 0, 0, 0, 0, 0]);
    const d = readDone(new BufferedReader(t), TokenType.done);
    assert(d.hasCount && !d.more && d.rowCount == 3 && d.command == 0xC1);

    t = new MockTransport;
    t.feed([0x05, 0x00, 208, 0, 0, 0, 1]); // ERROR cut short inside its length
    assertThrown!ProtocolException(readMessage(new BufferedReader(t)));
}
