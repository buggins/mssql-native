#!/usr/bin/env dub
/+ dub.sdl:
    name "collations"
    dependency "mssql-native" path=".."
+/
/++
Generates `source/mssql/types/collations.d`: the code page of `char`/`varchar`
values for each collation. For every collation of `sys.fn_helpcollations()` it
reads `COLLATIONPROPERTY(name, 'CodePage')` and the collation bytes the server
sends for an `nvarchar` column in it (`nvarchar`, since Unicode-only
collations refuse `varchar`). SQL collations are keyed by their sort id,
Windows collations by their LCID; `_UTF8` collations must have code page 65001.

    tools/collations.d <connection string> > source/mssql/types/collations.d

(or `dub run --single tools/collations.d -- ...` where scripts can't be run
directly, e.g. on Windows). The connection string is in URL or ADO style, e.g.
`sqlserver://sa:secret@localhost/master?trust_server_certificate=true`.
+/
module collations;

import std.algorithm : map, sort;
import std.array : appender, array, join;
import std.conv : to;
import std.format : format;
import std.stdio;
import mssql;

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writeln("usage: collations <connection string>");
        return 2;
    }
    auto conn = new Connection(args[1]);
    scope (exit)
        conn.close();

    string productVersion;
    foreach (row; conn.query("SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),"
            ~ " CAST(SERVERPROPERTY('ProductMajorVersion') AS int)"))
        productVersion = sqlServerName(row.getInt(1)) ~ " (" ~ row.getString(0) ~ ")";

    string[] names;
    int[string] codePages;
    foreach (row; conn.query(
            "SELECT name, CAST(COLLATIONPROPERTY(name, 'CodePage') AS int)"
            ~ " FROM sys.fn_helpcollations() ORDER BY name"))
    {
        names ~= row.getString(0);
        codePages[names[$ - 1]] = row.getInt(1);
    }

    int[uint] bySortId, byLcid;
    void add(ref int[uint] map, uint key, int codePage, string name)
    {
        if (auto known = key in map)
        {
            if (*known != codePage)
                throw new Exception(format!"%s: code page %s, another collation with key 0x%X has %s"(name,
                        codePage, key, *known));
            return;
        }
        map[key] = codePage;
    }

    enum batch = 500; // columns per query (at most 4096)
    for (size_t start = 0; start < names.length; start += batch)
    {
        const part = names[start .. start + batch < names.length ? start + batch : names.length];
        auto sql = "SELECT TOP 0 " ~ part.map!(n => "CAST(N'' AS nvarchar(1)) COLLATE " ~ n).join(", ");
        auto result = conn.query(sql);
        const columns = result.columns.dup;
        result.close();
        foreach (i, name; part)
        {
            const c = columns[i].type.collation;
            const codePage = codePages[name];
            if (c.utf8)
            {
                if (codePage != 65_001)
                    throw new Exception(name ~ ": a UTF-8 collation with code page " ~ codePage.to!string);
            }
            else if (c.sortId != 0)
                add(bySortId, c.sortId, codePage, name);
            else
                add(byLcid, c.lcid, codePage, name);
        }
    }

    writeModule(productVersion, names.length, bySortId, byLcid);
    return 0;
}

/// The product name of a major version.
string sqlServerName(int major)
{
    switch (major)
    {
    case 14:
        return "SQL Server 2017";
    case 15:
        return "SQL Server 2019";
    case 16:
        return "SQL Server 2022";
    case 17:
        return "SQL Server 2025";
    default:
        return "SQL Server " ~ major.to!string;
    }
}

/// The `case` lines of a switch: the keys of each code page, in order of code page, wrapped at 100 columns.
string cases(const int[uint] map, string delegate(uint) formatKey)
{
    uint[][int] keysOf;
    foreach (key, codePage; map)
        keysOf[codePage] ~= key;
    auto text = appender!string;
    foreach (codePage; keysOf.keys.sort)
    {
        enum first = "    case ", next = "        ";
        auto keys = keysOf[codePage].sort.map!formatKey.array;
        string line = first;
        foreach (i, key; keys)
        {
            const item = key ~ (i + 1 < keys.length ? "," : ":");
            const fresh = line == first || line == next;
            if (!fresh && line.length + 1 + item.length > 104)
            {
                text ~= line ~ "\n";
                line = next;
            }
            line ~= (line == first || line == next ? "" : " ") ~ item;
        }
        const value = codePage >= 10_000 ? format!"%,?d"('_', codePage) : codePage.to!string;
        text ~= line ~ "\n        return " ~ value ~ ";\n";
    }
    return text[];
}

/// Writes the module to stdout.
void writeModule(string productVersion, size_t count, const int[uint] bySortId, const int[uint] byLcid)
{
    writef(`/++
The code page of %1$schar%1$s/%1$svarchar%1$s/%1$stext%1$s values, from the column collation.

Generated by %1$stools/collations.d%1$s from %2$s: every collation of
%1$ssys.fn_helpcollations()%1$s (%3$s), its %1$sCOLLATIONPROPERTY(name, 'CodePage')%1$s,
and the collation bytes the server sends for a column in it. SQL collations
(%1$sSQL_...%1$s) are identified by their sort id, Windows collations by their
LCID; %1$s_UTF8%1$s collations use UTF-8 (65001). Code page 0 means the collation
is for Unicode data types only.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.types.collations;

import mssql.types.typeinfo : Collation;

/// The Windows code page of the 8-bit text of collation %1$sc%1$s, or -1 if the collation is unknown.
int codePageOf(const Collation c) @safe pure nothrow @nogc
{
    if (c.utf8)
        return 65_001;
    return c.sortId != 0 ? codePageOfSortId(c.sortId) : codePageOfLcid(c.lcid);
}

private int codePageOfSortId(uint sortId) @safe pure nothrow @nogc
{
    switch (sortId)
    {
%4$s    default:
        return -1;
    }
}

private int codePageOfLcid(uint lcid) @safe pure nothrow @nogc
{
    switch (lcid)
    {
%5$s    default:
        return -1;
    }
}

///
@safe unittest
{
    assert(codePageOf(Collation(0x00409, 0x0D, 0, 52)) == 1252); // SQL_Latin1_General_CP1_CI_AS
    assert(codePageOf(Collation(0x00409, 0x0D, 0, 0)) == 1252); // Latin1_General_CI_AS
    assert(codePageOf(Collation(0x00419, 0x0D, 0, 0)) == 1251); // Cyrillic_General_CI_AS
    assert(codePageOf(Collation(0x00409, 0x4D, 2, 0)) == 65_001); // Latin1_General_100_CI_AS_SC_UTF8
    assert(codePageOf(Collation(0x00439, 0x0D, 2, 0)) == 0); // Indic_General_100_CI_AS: Unicode only
    assert(codePageOf(Collation(0x00409, 0, 0, 250)) == -1); // an unknown sort id
}
`, "`", productVersion, count.to!string ~ " collations", cases(bySortId, k => k.to!string),
            cases(byLcid, k => format!"0x%05X"(k)));
}
