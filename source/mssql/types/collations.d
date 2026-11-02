/++
The code page of `char`/`varchar`/`text` values, from the column collation.

Generated from SQL Server 2022: every collation of `sys.fn_helpcollations()`,
its `COLLATIONPROPERTY(name, 'CodePage')`, and the collation bytes the server
sends for a column in it. SQL collations (`SQL_...`) are identified by their
sort id, Windows collations by their LCID; `_UTF8` collations use UTF-8 (65001).
Code page 0 means the collation is for Unicode data types only.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module mssql.types.collations;

import mssql.types.typeinfo : Collation;

/// The Windows code page of the 8-bit text of collation `c`, or -1 if the collation is unknown.
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
    case 30, 31, 32, 33, 34:
        return 437;
    case 40, 41, 42, 43, 44, 49, 55, 56, 57, 58, 59, 60, 61:
        return 850;
    case 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96:
        return 1250;
    case 105, 106, 107, 108:
        return 1251;
    case 51, 52, 53, 54, 183, 184, 185, 186, 210, 211, 212, 213, 214, 215, 216, 217:
        return 1252;
    case 113, 114, 120, 122, 124:
        return 1253;
    case 129, 130:
        return 1254;
    case 137, 138:
        return 1255;
    case 145, 146:
        return 1256;
    case 153, 154, 155, 156, 157, 158, 159, 160:
        return 1257;
    default:
        return -1;
    }
}

private int codePageOfLcid(uint lcid) @safe pure nothrow @nogc
{
    switch (lcid)
    {
    case 0x00439, 0x0043A, 0x00445, 0x0044D, 0x00451, 0x00453, 0x00454, 0x0045A, 0x00461, 0x00463,
        0x00465, 0x00481:
        return 0;
    case 0x0041E:
        return 874;
    case 0x00411, 0x10411, 0x40411:
        return 932;
    case 0x00804, 0x20804:
        return 936;
    case 0x00412:
        return 949;
    case 0x00404, 0x00C04, 0x01404, 0x21404, 0x30404:
        return 950;
    case 0x00405, 0x0040E, 0x00415, 0x00418, 0x0041A, 0x0041B, 0x0041C, 0x00424, 0x00442, 0x0081A,
        0x0141A, 0x1040E:
        return 1250;
    case 0x00419, 0x00422, 0x0042F, 0x0043F, 0x00444, 0x0046D, 0x00485, 0x0082C, 0x00C1A, 0x0201A:
        return 1251;
    case 0x00406, 0x00409, 0x0040A, 0x0040B, 0x0040C, 0x0040F, 0x00414, 0x00417, 0x0042E, 0x0043B,
        0x00452, 0x00462, 0x0047A, 0x0047C, 0x0047E, 0x00483, 0x0083B, 0x0085F, 0x00C0A, 0x10407,
        0x10437:
        return 1252;
    case 0x00408:
        return 1253;
    case 0x0041F, 0x0042C, 0x00443:
        return 1254;
    case 0x0040D:
        return 1255;
    case 0x00401, 0x00420, 0x00429, 0x00480, 0x0048C:
        return 1256;
    case 0x00425, 0x00426, 0x00427:
        return 1257;
    case 0x0042A:
        return 1258;
    default:
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
