/++
PRELOGIN ([MS-TDS] 2.2.6.5): the first exchange of a connection, which agrees
on encryption, and the transport that carries the TLS handshake inside
PRELOGIN packets.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.protocol.prelogin;

import std.conv : to;
import core.time : Duration;

import dbwire.io.buffer : fromBigEndian;
import dbwire.io.transport : Transport;
import mssql.exception : ConnectionException, ProtocolException;
import mssql.protocol.packet : PacketReader, PacketType, PacketWriter;

/// PRELOGIN option tokens.
enum PreloginOption : ubyte
{
    version_ = 0x00, /// client or server version (must be first)
    encryption = 0x01, /// encryption setting
    instOpt = 0x02, /// instance name
    threadId = 0x03, /// client thread id
    mars = 0x04, /// multiple active result sets
    traceId = 0x05, /// connection and activity ids
    fedAuthRequired = 0x06, /// federated authentication
    nonceOpt = 0x07, /// nonce for federated authentication
    terminator = 0xFF, /// end of the option table
}

/// ENCRYPTION option values.
enum Encryption : ubyte
{
    off = 0x00, /// available but off: only the login packet is encrypted (if both sides say so)
    on = 0x01, /// available and on
    notSupported = 0x02, /// not available
    required = 0x03, /// required
}

/// How a connection is encrypted, as agreed in PRELOGIN.
enum EncryptionMode
{
    none, /// no TLS at all
    loginOnly, /// TLS for the LOGIN7 packet only
    full, /// TLS for the whole connection
}

/// The server's PRELOGIN response.
struct PreloginResponse
{
    /// Server version: major, minor, build (e.g. 16, 0, 4305 for SQL Server 2022).
    ubyte majorVersion;
    /// ditto
    ubyte minorVersion;
    /// ditto
    ushort build;
    /// The server's ENCRYPTION value (without the client-certificate bit).
    ubyte encryption;
    /// INSTOPT: true if the instance name did not match.
    bool instanceMismatch;
    /// MARS: whether the server enabled it.
    bool mars;
}

/++
Builds the PRELOGIN request: VERSION, ENCRYPTION, INSTOPT, THREADID, MARS.

Params:
    encryption = `Encryption.on` to require TLS, `Encryption.off` to allow
        login-only or no encryption.
    clientVersion = client library version as major, minor, build.
+/
ubyte[] buildPrelogin(Encryption encryption, uint[3] clientVersion) @safe pure
{
    // option data, in table order
    const ubyte[] versionData = [
        cast(ubyte) clientVersion[0], cast(ubyte) clientVersion[1], cast(ubyte)(clientVersion[2] >> 8),
        cast(ubyte) clientVersion[2], 0, 0
    ];
    const ubyte[] encryptionData = [cast(ubyte) encryption];
    const ubyte[] instOptData = [0x00]; // an empty instance name
    const ubyte[] threadIdData = [0, 0, 0, 0];
    const ubyte[] marsData = [0x00]; // off
    const ubyte[][5] values = [versionData, encryptionData, instOptData, threadIdData, marsData];
    static immutable ubyte[5] tokens = [
        PreloginOption.version_, PreloginOption.encryption, PreloginOption.instOpt,
        PreloginOption.threadId, PreloginOption.mars
    ];
    ubyte[] table;
    ubyte[] data;
    const tableSize = tokens.length * 5 + 1;
    foreach (i, token; tokens)
    {
        // offsets count from the start of the PRELOGIN data; big-endian
        const offset = tableSize + data.length;
        table ~= [
            token, cast(ubyte)(offset >> 8), cast(ubyte) offset, cast(ubyte)(values[i].length >> 8),
            cast(ubyte) values[i].length
        ];
        data ~= values[i];
    }
    return table ~ PreloginOption.terminator ~ data;
}

/++
Parses the server's PRELOGIN response.

Throws: `ProtocolException` if the option table is malformed or VERSION or
ENCRYPTION is missing.
+/
PreloginResponse parsePrelogin(scope const(ubyte)[] data) @safe pure
{
    ProtocolException error(string what)
    {
        return new ProtocolException("Invalid PRELOGIN response: " ~ what);
    }

    PreloginResponse response;
    bool haveVersion, haveEncryption;
    size_t pos;
    for (;;)
    {
        if (pos >= data.length)
            throw error("no terminator");
        const token = data[pos];
        if (token == PreloginOption.terminator)
            break;
        if (pos + 5 > data.length)
            throw error("truncated option table");
        const offset = fromBigEndian!ushort(data[pos + 1 .. $][0 .. 2]);
        const length = fromBigEndian!ushort(data[pos + 3 .. $][0 .. 2]);
        if (offset + length > data.length)
            throw error("option data out of range");
        const value = data[offset .. offset + length];
        switch (token)
        {
        case PreloginOption.version_:
            if (length < 4)
                throw error("short VERSION");
            response.majorVersion = value[0];
            response.minorVersion = value[1];
            response.build = fromBigEndian!ushort(value[2 .. 4]);
            haveVersion = true;
            break;
        case PreloginOption.encryption:
            if (length < 1)
                throw error("short ENCRYPTION");
            response.encryption = value[0] & 0x7F; // without the client-certificate bit
            haveEncryption = true;
            break;
        case PreloginOption.instOpt:
            response.instanceMismatch = length >= 1 && value[0] == 1;
            break;
        case PreloginOption.mars:
            response.mars = length >= 1 && value[0] == 1;
            break;
        default:
            break; // THREADID, TRACEID, FEDAUTHREQUIRED, NONCEOPT, unknown: not needed
        }
        pos += 5;
    }
    if (!haveVersion || !haveEncryption)
        throw error("VERSION or ENCRYPTION missing");
    return response;
}

/++
The encryption mode that the client's and the server's ENCRYPTION values
agree on ([MS-TDS] 2.2.6.5).

Throws: `ConnectionException` when they don't agree (the client requires
encryption that the server lacks or refuses).
+/
EncryptionMode agreeEncryption(Encryption client, ubyte server) @safe pure
{
    if (server == Encryption.on || server == Encryption.required)
        return EncryptionMode.full;
    if (client == Encryption.on)
        throw new ConnectionException(server == Encryption.notSupported
                ? "The server does not support encryption, which the client requires"
                : "The server did not agree to encryption, which the client requires");
    if (server == Encryption.off)
        return EncryptionMode.loginOnly;
    if (server == Encryption.notSupported)
        return EncryptionMode.none;
    throw new ConnectionException("Unknown encryption value from the server: " ~ server.to!string);
}

/++
Carries a TLS handshake inside PRELOGIN packets ([MS-TDS] 2.2.6.5): each write
becomes a PRELOGIN message; reads return the data of the server's packets.
For `dbwire.tls.transport.TlsTransport`'s `handshakeTransport`.
+/
final class PreloginTlsFraming : Transport
{
    private Transport raw;
    private PacketWriter writer;
    private PacketReader reader;

    /// Creates the adapter over the raw connection.
    this(Transport raw, uint packetSize) @safe
    {
        this.raw = raw;
        writer = new PacketWriter(raw, packetSize);
        reader = new PacketReader(raw);
        reader.beginMessage();
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        if (reader.messageEnded)
            reader.beginMessage(); // a handshake flight may span several messages
        return reader.read(buffer);
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        writer.message(PacketType.prelogin, data);
    }

    override bool dataAvailable() @safe
    {
        return raw.dataAvailable();
    }

    override void close() @safe nothrow
    {
        raw.close();
    }

    override bool connected() const @safe nothrow
    {
        return raw.connected;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
        raw.setTimeouts(receive, send);
    }
}

///
@safe unittest
{
    // The request: five options, a terminator, then the data the offsets point to
    const request = buildPrelogin(Encryption.on, [0, 1, 2]);
    assert(request[0 .. 5] == [0x00, 0x00, 0x1A, 0x00, 0x06]); // VERSION at 26, 6 bytes
    assert(request[5 .. 10] == [0x01, 0x00, 0x20, 0x00, 0x01]); // ENCRYPTION at 32
    assert(request[25] == 0xFF && request[26 .. 32] == [0, 1, 0, 2, 0, 0] && request[32] == 0x01);
    assert(request.length == 26 + 6 + 1 + 1 + 4 + 1);
}

@safe unittest
{
    import std.exception : assertThrown;

    // A response captured from SQL Server 2022 (16.0.4305), which answered ENCRYPTION=ON
    const ubyte[] response = [
        0x00, 0x00, 0x0B, 0x00, 0x06, 0x01, 0x00, 0x11, 0x00, 0x01, 0xFF, 0x10, 0x00, 0x10,
        0xD1, 0x00, 0x00, 0x01
    ];
    const r = parsePrelogin(response);
    assert(r.majorVersion == 16 && r.minorVersion == 0 && r.build == 4305 && r.encryption == Encryption.on);

    assertThrown!ProtocolException(parsePrelogin([])); // no terminator
    assertThrown!ProtocolException(parsePrelogin([0x00, 0x00, 0x0B])); // truncated table
    assertThrown!ProtocolException(parsePrelogin([0x00, 0x00, 0x30, 0x00, 0x06, 0xFF])); // data out of range
    assertThrown!ProtocolException(parsePrelogin([0xFF])); // VERSION and ENCRYPTION missing

    // The agreement table of [MS-TDS] 2.2.6.5
    with (Encryption) with (EncryptionMode)
    {
        assert(agreeEncryption(off, off) == loginOnly && agreeEncryption(off, on) == full);
        assert(agreeEncryption(off, required) == full && agreeEncryption(off, notSupported) == none);
        assert(agreeEncryption(on, on) == full && agreeEncryption(on, required) == full);
        assertThrown!ConnectionException(agreeEncryption(on, off));
        assertThrown!ConnectionException(agreeEncryption(on, notSupported));
    }
}
