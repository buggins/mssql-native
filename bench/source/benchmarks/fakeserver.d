/++
An in-memory SQL Server for the benchmarks: a `Transport` that answers
PRELOGIN (no encryption) and LOGIN7 (LOGINACK, the usual ENVCHANGEs), then
every request message with the token stream a callback returns, split into
TDS packets. Nothing is parsed beyond the packet headers, so the client's
own work is what gets measured.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.fakeserver;

import core.time : Duration;
import dbwire.io.transport : Transport;

/// TDS message types the client sends.
enum MessageType : ubyte
{
    batch = 0x01, ///
    rpc = 0x03, ///
    attention = 0x06, ///
    bulkLoad = 0x07, ///
    login7 = 0x10, ///
    prelogin = 0x12, ///
}

/// The fake server.
final class FakeServer : Transport
{
    /// Answers a request message (after login) with a token stream.
    const(ubyte)[]delegate(MessageType type, const(ubyte)[] payload) @safe respond;
    /// Bytes the client wrote (all packets, headers included).
    size_t bytesWritten;

    private ubyte[] pending; // response packets still to be read
    private size_t pos;
    private ubyte[] message; // payload of the request being received
    private ubyte[] partial; // bytes of a packet not complete yet
    private const(ubyte)[] lastTokens; // the token stream `pending` was built from
    private uint packetSize = 4096;

    override size_t read(scope ubyte[] buffer) @safe
    {
        auto n = pending.length - pos;
        if (n > buffer.length)
            n = buffer.length;
        buffer[0 .. n] = pending[pos .. pos + n];
        pos += n;
        return n;
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        bytesWritten += data.length;
        partial ~= data;
        size_t start;
        while (partial.length - start >= 8)
        {
            const len = (partial[start + 2] << 8) | partial[start + 3];
            if (partial.length - start < len)
                break;
            const type = cast(MessageType) partial[start];
            const last = (partial[start + 1] & 1) != 0;
            if (type != MessageType.attention)
            {
                message ~= partial[start + 8 .. start + len];
                if (last)
                {
                    answer(type, message);
                    message.length = 0;
                    (() @trusted => message.assumeSafeAppend())(); // the old contents are no longer used
                }
            }
            start += len;
        }
        if (start == partial.length)
        {
            partial.length = 0;
            (() @trusted => partial.assumeSafeAppend())(); // as above
        }
        else if (start)
            partial = partial[start .. $].dup;
    }

    private void answer(MessageType type, const(ubyte)[] payload) @safe
    {
        if (type == MessageType.prelogin)
            setResponse(preloginResponse, 0x04);
        else if (type == MessageType.login7)
            setResponse(loginResponse(), 0x04);
        else
            setResponse(respond(type, payload), 0x04);
    }

    // Splits `tokens` into packets of `packetSize` bytes (kept while the same stream is answered again).
    private void setResponse(const(ubyte)[] tokens, ubyte type) @safe
    {
        pos = 0;
        if (tokens is lastTokens && pending.length)
            return;
        lastTokens = tokens;
        pending = null;
        const room = packetSize - 8;
        do
        {
            const n = tokens.length < room ? tokens.length : room;
            const len = n + 8;
            pending ~= [
                type, cast(ubyte)(n == tokens.length ? 1 : 0), cast(ubyte)(len >> 8), cast(ubyte) len,
                0, 0, 1, 0
            ];
            pending ~= tokens[0 .. n];
            tokens = tokens[n .. $];
        }
        while (tokens.length);
    }

    override bool dataAvailable() @safe
    {
        return pos < pending.length;
    }

    override void close() @safe nothrow
    {
    }

    override bool connected() const @safe nothrow
    {
        return true;
    }

    override void setTimeouts(Duration, Duration) @safe
    {
    }
}

// PRELOGIN: VERSION 16.0.4305 (option 0, 6 bytes at 11), ENCRYPTION NOT_SUP (option 1, 1 byte at 17)
private immutable ubyte[] preloginResponse = [
    0x00, 0x00, 0x0B, 0x00, 0x06, 0x01, 0x00, 0x11, 0x00, 0x01, 0xFF, 0x10, 0x00, 0x10, 0xD1, 0x00,
    0x00, 0x02
];

// The answer to LOGIN7: database, collation and language changes, LOGINACK, packet size, DONE.
private const(ubyte)[] loginResponse() @safe
{
    Tokens t;
    t.envChange(1, "master", "master");
    t.u8(0xE3); // ENVCHANGE collation: B_VARBYTE new (5 bytes), old (empty)
    t.u16(8);
    t.bytes([7, 5]);
    t.collation();
    t.u8(0);
    t.envChange(2, "us_english", "");
    t.u8(0xAD); // LOGINACK
    const program = "Microsoft SQL Server";
    t.u16(cast(uint)(1 + 4 + 1 + 2 * program.length + 4));
    t.bytes([1, 0x74, 0x00, 0x00, 0x04]); // SQL_TSQL, TDS 7.4
    t.u8(cast(uint) program.length);
    t.utf16(program);
    t.bytes([16, 0, 0x10, 0xD1]); // 16.0.4305
    t.envChange(4, "4096", "4096");
    t.done(0xFD, 0, 0, 0);
    return t.b;
}

/// Builds token streams.
struct Tokens
{
    /// The bytes so far.
    ubyte[] b;

    /// Little-endian integers.
    void u8(uint v) @safe
    {
        b ~= cast(ubyte) v;
    }

    /// ditto
    void u16(uint v) @safe
    {
        b ~= [cast(ubyte) v, cast(ubyte)(v >> 8)];
    }

    /// ditto
    void u32(uint v) @safe
    {
        foreach (i; 0 .. 4)
            b ~= cast(ubyte)(v >> (8 * i));
    }

    /// ditto
    void u64(ulong v) @safe
    {
        foreach (i; 0 .. 8)
            b ~= cast(ubyte)(v >> (8 * i));
    }

    /// Raw bytes.
    void bytes(const(ubyte)[] v) @safe
    {
        b ~= v;
    }

    /// ASCII text as UTF-16LE.
    void utf16(string s) @safe
    {
        foreach (c; s)
            b ~= [cast(ubyte) c, 0];
    }

    /// SQL_Latin1_General_CP1_CI_AS.
    void collation() @safe
    {
        b ~= [0x09, 0x04, 0xD0, 0x00, 0x34];
    }

    /// An ENVCHANGE with B_VARCHAR values.
    void envChange(ubyte type, string newValue, string oldValue) @safe
    {
        u8(0xE3);
        u16(cast(uint)(1 + 1 + 2 * newValue.length + 1 + 2 * oldValue.length));
        u8(type);
        u8(cast(uint) newValue.length);
        utf16(newValue);
        u8(cast(uint) oldValue.length);
        utf16(oldValue);
    }

    /// A DONE, DONEPROC or DONEINPROC token.
    void done(ubyte token, ushort status, ushort command, ulong rows) @safe
    {
        u8(token);
        u16(status);
        u16(command);
        u64(rows);
    }

    /// COLMETADATA.
    void columns(const Col[] cols) @safe
    {
        u8(0x81);
        u16(cast(uint) cols.length);
        foreach (c; cols)
        {
            u32(0); // user type
            u16(c.flags);
            bytes(c.typeInfo);
            u8(cast(uint) c.name.length);
            utf16(c.name);
        }
    }
}

/// A column for `Tokens.columns`.
struct Col
{
    string name; ///
    immutable(ubyte)[] typeInfo; /// TYPE_INFO bytes
    ushort flags = 0x0009; /// nullable, updatable
}

/// The SQL text of a batch request (after ALL_HEADERS), as ASCII.
string batchText(const(ubyte)[] payload) @safe
{
    if (payload.length < 4)
        return null;
    const skip = payload[0] | (payload[1] << 8) | (payload[2] << 16) | (payload[3] << 24);
    char[] s;
    for (size_t i = skip; i + 1 < payload.length; i += 2)
        s ~= cast(char) payload[i];
    return s.idup;
}
