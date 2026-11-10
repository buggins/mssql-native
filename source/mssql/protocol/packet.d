/++
TDS packets ([MS-TDS] 2.2.3): every message is sent as one or more packets,
each with an 8-byte header (type, status, big-endian length including the
header, SPID, packet id, window). The last packet of a message has the
end-of-message status bit.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.protocol.packet;

import std.conv : to;
import core.time : Duration;

import dbwire.io.buffer : fromBigEndian, isFixedWireType, toBigEndian, toLittleEndian;
import dbwire.io.transport : Transport;
import mssql.exception : ConnectionException, ProtocolException;

/// Packet types ([MS-TDS] 2.2.3.1.1).
enum PacketType : ubyte
{
    sqlBatch = 1, /// SQL batch
    rpc = 3, /// remote procedure call
    tabularResult = 4, /// server response
    attention = 6, /// cancel
    bulkLoad = 7, /// bulk load data
    federatedAuthToken = 8, /// federated authentication token
    transactionManager = 14, /// transaction manager request
    login7 = 16, /// TDS 7 login
    sspi = 17, /// integrated authentication
    prelogin = 18, /// pre-login (also carries the TLS handshake)
}

/// Packet status bits ([MS-TDS] 2.2.3.1.2).
enum PacketStatus : ubyte
{
    normal = 0x00, /// more packets follow
    endOfMessage = 0x01, /// the last packet of the message
    ignore = 0x02, /// ignore this message (with endOfMessage)
    resetConnection = 0x08, /// reset the session before the request (first packet only)
    resetConnectionSkipTran = 0x10, /// reset, keeping the transaction
}

/// Size of a packet header.
enum size_t packetHeaderSize = 8;
/// Packet size before the login negotiates another one.
enum uint defaultPacketSize = 4096;
/// Smallest packet size.
enum uint minPacketSize = 512;
/// Largest packet size.
enum uint maxPacketSize = 32_767;

/// Writes messages as packets of `packetSize` bytes.
final class PacketWriter
{
    /// The transport the packets go to.
    Transport transport;
    private ubyte[] buffer;
    private size_t used;
    private ubyte type;
    private ubyte firstStatus;
    private ubyte packetId = 1;
    private bool inMessage;

    /// Creates a writer for packets of `packetSize` bytes, header included.
    this(Transport transport, uint packetSize = defaultPacketSize) @safe
    {
        this.transport = transport;
        this.packetSize = packetSize;
    }

    /// Packet size, header included (from `minPacketSize` to `maxPacketSize`).
    @property uint packetSize() const @safe pure nothrow @nogc
    {
        return cast(uint) buffer.length;
    }

    /// ditto
    @property void packetSize(uint size) @safe pure
    {
        assert(!inMessage, "cannot change the packet size inside a message");
        assert(size >= minPacketSize && size <= maxPacketSize, "packet size out of range");
        buffer = new ubyte[size];
    }

    /// Starts a message of `messageType`; `status` bits such as `resetConnection` go into its first packet.
    void begin(PacketType messageType, ubyte status = PacketStatus.normal) @safe pure nothrow @nogc
    {
        assert(!inMessage, "a message is already being written");
        type = messageType;
        firstStatus = status;
        used = packetHeaderSize;
        inMessage = true;
    }

    /// Appends data to the message, sending full packets.
    void put(scope const(ubyte)[] data) @safe
    {
        assert(inMessage, "begin() first");
        while (data.length)
        {
            if (used == buffer.length)
                send(false);
            const n = data.length < buffer.length - used ? data.length : buffer.length - used;
            buffer[used .. used + n] = data[0 .. n];
            used += n;
            data = data[n .. $];
        }
    }

    /// Appends one byte.
    void putByte(ubyte b) @safe
    {
        const ubyte[1] one = [b];
        put(one[]);
    }

    /++
    Appends `text` as UTF-16LE, exactly as `encodeUtf16le` encodes it
    (invalid UTF-8 as U+FFFD), straight into the packets: nothing is
    allocated. `utf16Length` gives its length.
    +/
    void putUtf16(scope const(char)[] text) @safe
    {
        import dbwire.charset.utf16 : encodeUtf16leInto;

        assert(inMessage, "begin() first");
        size_t pos;
        while (pos < text.length)
        {
            if (buffer.length - used >= 4)
                used += encodeUtf16leInto(text, pos, buffer[used .. $]); // whole characters, at least one
            else
            {
                ubyte[4] piece; // the end of the packet: a character may go on in the next one
                put(piece[0 .. encodeUtf16leInto(text, pos, piece[])]);
            }
        }
    }

    /// Appends a little-endian value.
    void putLE(T)(T value) @safe if (isFixedWireType!T)
    {
        auto bytes = toLittleEndian(value);
        put(bytes[]);
    }

    /// Sends the last packet of the message.
    void end() @safe
    {
        assert(inMessage, "begin() first");
        send(true);
        inMessage = false;
    }

    /++
    Ends the message with the IGNORE flag: the server discards the whole
    message (what was already sent of it included), e.g. to abort a bulk load.
    +/
    void endIgnored() @safe
    {
        assert(inMessage, "begin() first");
        firstStatus |= PacketStatus.ignore;
        send(true);
        inMessage = false;
    }

    /// Sends a whole message.
    void message(PacketType messageType, scope const(ubyte)[] data, ubyte status = PacketStatus.normal) @safe
    {
        begin(messageType, status);
        put(data);
        end();
    }

    private void send(bool last) @safe
    {
        buffer[0] = type;
        buffer[1] = cast(ubyte)((last ? PacketStatus.endOfMessage : PacketStatus.normal) | firstStatus);
        buffer[2 .. 4] = toBigEndian(cast(ushort) used);
        buffer[4] = buffer[5] = 0; // SPID: a client may send 0
        buffer[6] = packetId++; // ignored by the server, incremented modulo 256
        buffer[7] = 0; // window: unused
        transport.write(buffer[0 .. used]);
        firstStatus = PacketStatus.normal; // status bits such as reset go into the first packet only
        used = packetHeaderSize;
    }
}

/++
Presents the data of incoming packets as a byte stream, one message at a time:
`beginMessage` before reading each message; reading past its end throws.
+/
final class PacketReader : Transport
{
    /// The transport the packets come from.
    Transport transport;
    private size_t remaining; // data bytes left in the current packet
    private bool lastPacket; // the current packet ends the message
    private bool started;
    private ubyte currentType;

    /// Creates a reader.
    this(Transport transport) @safe pure nothrow
    {
        this.transport = transport;
    }

    /// Prepares to read the next message.
    void beginMessage() @safe pure nothrow
    {
        remaining = 0;
        lastPacket = false;
        started = false;
    }

    /// Whether the whole current message has been read.
    @property bool messageEnded() const @safe pure nothrow @nogc
    {
        return started && lastPacket && remaining == 0;
    }

    /// Type of the current message (after its first byte was read).
    @property PacketType messageType() const @safe pure nothrow @nogc
    {
        return cast(PacketType) currentType;
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        while (remaining == 0) // empty packets: a loop, not recursion (a server may send many)
        {
            if (started && lastPacket)
                throw new ProtocolException("The server's message ended before the data it announced");
            readHeader();
        }
        const want = buffer.length < remaining ? buffer.length : remaining;
        const n = transport.read(buffer[0 .. want]);
        if (n == 0)
            throw new ConnectionException("Connection closed by the server");
        remaining -= n;
        return n;
    }

    /// Writing is not supported: use `PacketWriter`.
    override void write(scope const(ubyte)[] data) @safe
    {
        assert(false, "PacketReader is read-only");
    }

    override bool dataAvailable() @safe
    {
        return transport.dataAvailable();
    }

    override void close() @safe nothrow
    {
        transport.close();
    }

    override bool connected() const @safe nothrow
    {
        return transport.connected;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
        transport.setTimeouts(receive, send);
    }

    private void readHeader() @safe
    {
        ubyte[packetHeaderSize] header;
        size_t got;
        while (got < header.length)
        {
            const n = transport.read(header[got .. $]);
            if (n == 0)
                throw new ConnectionException("Connection closed by the server");
            got += n;
        }
        const length = fromBigEndian!ushort(header[2 .. 4]);
        if (length < packetHeaderSize)
            throw new ProtocolException("Invalid TDS packet length " ~ length.to!string);
        if (started && header[0] != currentType)
            throw new ProtocolException("TDS packet type changed inside a message");
        currentType = header[0];
        lastPacket = (header[1] & PacketStatus.endOfMessage) != 0;
        remaining = length - packetHeaderSize;
        started = true;
    }
}

///
@safe unittest
{
    import dbwire.io.mock : MockTransport;

    // A message longer than one packet: 512-byte packets carry 504 data bytes each
    auto t = new MockTransport;
    auto w = new PacketWriter(t, 512);
    auto data = new ubyte[600];
    foreach (i, ref b; data)
        b = cast(ubyte) i;
    w.message(PacketType.sqlBatch, data, PacketStatus.resetConnection);
    assert(t.written.length == 600 + 2 * packetHeaderSize);
    assert(t.written[0 .. 8] == [1, 0x08, 0x02, 0x00, 0, 0, 1, 0]); // reset in the first packet only
    assert(t.written[512 .. 520] == [1, 0x01, 0x00, 104, 0, 0, 2, 0]); // last packet: end of message

    // Read back as one stream
    t.feed(t.written);
    auto r = new PacketReader(t);
    r.beginMessage();
    auto got = new ubyte[600];
    size_t n;
    while (n < got.length)
        n += r.read(got[n .. $]);
    assert(got == data && r.messageEnded && r.messageType == PacketType.sqlBatch);
}

@safe unittest
{
    import std.exception : assertThrown;
    import dbwire.io.mock : MockTransport;

    // Reading past the end of a message, a bad length, a type change, a closed connection
    auto t = new MockTransport;
    t.feed([4, 1, 0, 9, 0, 0, 1, 0, 0xAA]);
    auto r = new PacketReader(t);
    r.beginMessage();
    ubyte[4] b;
    assert(r.read(b[]) == 1 && r.messageEnded);
    assertThrown!ProtocolException(r.read(b[]));

    t = new MockTransport;
    t.feed([4, 1, 0, 7, 0, 0, 1, 0]);
    r = new PacketReader(t);
    r.beginMessage();
    assertThrown!ProtocolException(r.read(b[]));

    t = new MockTransport;
    t.feed([4, 0, 0, 9, 0, 0, 1, 0, 1, 18, 1, 0, 9, 0, 0, 2, 0, 2]);
    r = new PacketReader(t);
    r.beginMessage();
    r.read(b[0 .. 1]);
    assertThrown!ProtocolException(r.read(b[]));

    t = new MockTransport;
    t.feed([4, 0, 0, 12, 0]);
    r = new PacketReader(t);
    r.beginMessage();
    assertThrown!ConnectionException(r.read(b[]));
}

// putUtf16 writes what encodeUtf16le gives, ASCII or not, across packet boundaries
@safe unittest
{
    import std.array : replicate;
    import dbwire.charset.utf16 : encodeUtf16le;
    import dbwire.io.mock : MockTransport;

    foreach (text; [
        "", "SELECT 1", "x".replicate(700), "é😀\xFF ok", "ab".replicate(300) ~ "ж",
        "ж".replicate(300), "😀".replicate(200), "a" ~ "😀".replicate(200),
        "ab" ~ "😀".replicate(200)
    ])
    {
        auto t = new MockTransport;
        auto w = new PacketWriter(t, 512);
        w.begin(PacketType.sqlBatch);
        w.putUtf16(text);
        w.end();
        ubyte[] payload;
        for (auto rest = t.written; rest.length;)
        {
            const len = (rest[2] << 8) | rest[3];
            payload ~= rest[packetHeaderSize .. len];
            rest = rest[len .. $];
        }
        assert(payload == encodeUtf16le(text));
    }
}
