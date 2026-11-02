/++
LOGIN7 ([MS-TDS] 2.2.6.4): the login message of TDS 7.x, here for TDS 7.4 and
SQL Server authentication.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.protocol.login;

import mssql.protocol.packet : defaultPacketSize;
import dbwire.charset.utf16 : encodeUtf16le;

/// TDS 7.4 (SQL Server 2012 and newer), the version this client speaks.
enum uint tds74 = 0x74000004;

/// What a LOGIN7 message carries.
struct Login7
{
    /// Requested packet size; the server may answer with another one (ENVCHANGE).
    uint packetSize = defaultPacketSize;
    /// Client library version (informational).
    uint clientProgVersion;
    /// Client process id (informational).
    uint clientPid;
    /// Client machine name (shown in `sys.dm_exec_sessions`).
    string hostName;
    /// SQL Server login name.
    string userName;
    /// Password; sent obfuscated, so encrypt at least the login.
    string password;
    /// Application name (shown in `sys.dm_exec_sessions`).
    string appName;
    /// The server name the client connects to.
    string serverName;
    /// Client library name.
    string libraryName;
    /// Initial language; empty: the login's default.
    string language;
    /// Initial database; empty: the login's default.
    string database;
    /// Ask for a read-only replica (availability groups).
    bool readOnlyIntent;
}

/// Size of LOGIN7's fixed part and offset table, where the variable data starts.
enum size_t login7HeaderSize = 94;

/++
Builds the LOGIN7 message ([MS-TDS] 2.2.6.4).

Option flags: the server reports database and language changes and fails the
login if the initial database or language can't be used; ODBC behaviour is on
(`ANSI_NULLS`, `QUOTED_IDENTIFIER`, ... as ODBC and SqlClient have them).
+/
ubyte[] buildLogin7(const ref Login7 login) @safe pure
{
    ubyte[] data; // the variable part, after the fixed part and the offset table
    ubyte[] table;

    void field(const(ubyte)[] utf16)
    {
        const offset = login7HeaderSize + data.length;
        table ~= le16(offset);
        table ~= le16(utf16.length / 2); // in characters
        data ~= utf16;
    }

    field(encodeUtf16le(login.hostName));
    field(encodeUtf16le(login.userName));
    field(obfuscate(encodeUtf16le(login.password)));
    field(encodeUtf16le(login.appName));
    field(encodeUtf16le(login.serverName));
    field(null); // ibUnused/cbUnused: no extension block (fExtension is 0)
    field(encodeUtf16le(login.libraryName));
    field(encodeUtf16le(login.language));
    field(encodeUtf16le(login.database));
    table ~= [0, 0, 0, 0, 0, 0]; // ClientID (MAC address): informational
    field(null); // SSPI: none
    field(null); // AtchDBFile: none
    field(null); // ChangePassword: none
    table ~= le32(0); // cbSSPILong
    assert(table.length == login7HeaderSize - 36);

    ubyte[] message;
    const total = login7HeaderSize + data.length;
    message ~= le32(total); // Length
    message ~= le32(tds74); // TDSVersion
    message ~= le32(login.packetSize);
    message ~= le32(login.clientProgVersion);
    message ~= le32(login.clientPid);
    message ~= le32(0); // ConnectionID
    message ~= 0x20 | 0x40 | 0x80; // OptionFlags1: fUseDB, fDatabase (fatal), fSetLang
    message ~= 0x01 | 0x02; // OptionFlags2: fLanguage (fatal), fODBC
    message ~= login.readOnlyIntent ? 0x20 : 0x00; // TypeFlags: fReadOnlyIntent
    message ~= 0x00; // OptionFlags3
    message ~= le32(0); // ClientTimeZone: not used
    message ~= le32(0x0409); // ClientLCID
    return message ~ table ~ data;
}

/++
Obfuscates a password for LOGIN7: in each byte the two halves are swapped,
then XOR `0xA5` ([MS-TDS] 2.2.6.4). It is not encryption.
+/
ubyte[] obfuscate(scope const(ubyte)[] utf16) @safe pure nothrow
{
    auto result = new ubyte[utf16.length];
    foreach (i, b; utf16)
        result[i] = cast(ubyte)(((b << 4) | (b >> 4)) ^ 0xA5);
    return result;
}

private ubyte[2] le16(size_t v) @safe pure nothrow @nogc
{
    return [cast(ubyte) v, cast(ubyte)(v >> 8)];
}

private ubyte[4] le32(size_t v) @safe pure nothrow @nogc
{
    return [cast(ubyte) v, cast(ubyte)(v >> 8), cast(ubyte)(v >> 16), cast(ubyte)(v >> 24)];
}

///
@safe unittest
{
    Login7 login;
    login.hostName = "box";
    login.userName = "sa";
    login.password = "a";
    login.appName = "app";
    login.database = "master";
    const m = buildLogin7(login);

    assert(m[0 .. 4] == [cast(ubyte) m.length, 0, 0, 0]); // Length
    assert(m[4 .. 8] == [0x04, 0x00, 0x00, 0x74]); // TDS 7.4
    assert(m[8 .. 12] == [0x00, 0x10, 0, 0]); // packet size 4096
    assert(m[24 .. 28] == [0xE0, 0x03, 0x00, 0x00]); // option flags
    assert(m[36 .. 40] == [94, 0, 3, 0]); // ibHostName: the data starts after the table; 3 characters
    assert(m[94 .. 100] == [cast(ubyte) 'b', 0, 'o', 0, 'x', 0]);
    assert(m[40 .. 44] == [100, 0, 2, 0]); // ibUserName, cchUserName
    assert(m[44 .. 48] == [104, 0, 1, 0]); // ibPassword, cchPassword
    assert(m[104 .. 106] == [0xB3, 0xA5]); // "a" (61 00), obfuscated
    // ibDatabase: after host (6 bytes), user (4), password (2) and app (6); "master" ends the data
    assert(m[68 .. 72] == [112, 0, 6, 0] && m.length == 112 + 12);
}
