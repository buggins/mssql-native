/++
Exceptions thrown by mssql-native.

All of them derive from `dbwire.exception.DbException`:
$(UL
    $(LI `ServerException`: SQL Server reported an error (an ERROR token).
        Unless its severity is 20 or higher, the connection stays usable.)
    $(LI `ConnectionException`: network failure or timeout. The connection is closed.)
    $(LI `ProtocolException`: malformed or unexpected data from the server. The connection is closed.)
    $(LI `ClientException`: invalid use of the library or an unsupported feature.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.exception;

public import dbwire.exception : ClientException, ConnectionException, DbException, ProtocolException;

/// A message from the server: an error (ERROR token) or an informational message (INFO token).
struct ServerMessage
{
    /// Message number, e.g. 102 (syntax error) or 18456 (login failed).
    int number;
    /// Error state, which tells apart situations with the same number.
    ubyte state;
    /// Severity ("class"): below 10 informational, 11 to 16 user errors, 20 and above fatal.
    ubyte severity;
    /// Message text.
    string message;
    /// Name of the server that sent it.
    string serverName;
    /// Stored procedure or trigger where it happened, or empty.
    string procName;
    /// Line in the batch or procedure.
    int lineNumber;

    /// The message as `sqlcmd` prints it: `Msg 102, Level 15, State 1, Line 1: ...`.
    string toString() const @safe pure nothrow
    {
        import std.conv : to;

        const procedure = procName.length ? ", Procedure " ~ procName : "";
        return "Msg " ~ number.to!string ~ ", Level " ~ severity.to!string ~ ", State " ~ state.to!string
            ~ procedure ~ ", Line " ~ lineNumber.to!string ~ ": " ~ message;
    }
}

/++
An error reported by SQL Server, e.g. a syntax error or a failed login.

When a statement produces several errors, the first is in the exception's
fields and all of them are in `errors`. Errors of severity 20 or higher close
the connection.
+/
class ServerException : DbException
{
    /// The first error.
    ServerMessage error;
    /// All errors of the statement, the first included (the first 100, and any fatal ones after them).
    ServerMessage[] errors;

    /++
    Creates the exception for `errors` (at least one).

    Params:
        errors = the errors, in the order the server sent them.
        file = source file (filled in automatically).
        line = source line (filled in automatically).
    +/
    this(ServerMessage[] errors, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        assert(errors.length > 0);
        string text = errors[0].toString();
        foreach (e; errors[1 .. $])
            text ~= "\n" ~ e.toString();
        super(text, file, line);
        this.error = errors[0];
        this.errors = errors;
    }

    /// Message number of the first error, e.g. 102 or 18456.
    @property int number() const @safe pure nothrow @nogc
    {
        return error.number;
    }

    /// Severity of the first error.
    @property ubyte severity() const @safe pure nothrow @nogc
    {
        return error.severity;
    }
}

///
@safe unittest
{
    auto e = new ServerException([
        ServerMessage(102, 1, 15, "Incorrect syntax near 'x'.", "db1", "", 1)
    ]);
    assert(e.number == 102 && e.severity == 15);
    assert(e.msg == "Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'x'.");
    const DbException base = e; // all exceptions share dbwire's base class
    assert(base !is null);
}
