# Benchmarks

`bench/` (dub subpackage `:bench`) times the client's own work against an
in-memory fake server (`bench/source/benchmarks/fakeserver.d`): a `Transport`
that answers PRELOGIN (no encryption) and LOGIN7 (LOGINACK and the usual
ENVCHANGEs), so a real `Connection` logs in, then hands out scripted token
streams, one per request. Neither the network nor a real server is measured.
The `value/` and `params/` cases call the getters and `Parameter.of`
directly. Each case is prepared once, then run at least 5 times and for at
least the minimum time; the runner reports the median and minimum time and
the bytes allocated per row (per call or per value for the cases without
rows).

```sh
dub run :bench -b release                       # all cases
dub run :bench -b release -- --filter value/    # the cases whose name contains the text
dub run :bench -b release -- --rows 10000 --min-time 2 --csv results.csv
```

On a busy machine compare the `min ms` column; the median moves with
background load.

## Results

Issue #43 (allocation and performance fixes from the code review), LDC 1.36
`-b release`, WSL2 on a shared machine: `main` and the branch run
alternately, three times each, the minimum of the runs kept (approximate:
compare ratios, not absolute numbers). Minimum time in ms, allocated bytes
per row.

| case | rows | before ms | after ms | speed-up | before B/row | after B/row |
|---|---:|---:|---:|---:|---:|---:|
| query/rows | 100000 | 19.32 | 19.46 | 1.0× | 0 | 0 |
| query/rows NBCROW | 100000 | 23.27 | 18.19 | 1.3× | 32 | 0 |
| query/rows+getters | 100000 | 56.96 | 56.19 | 1.0× | 160 | 160 |
| query/rows getString | 100000 | 158.88 | 71.03 | 2.2× | 320 | 160 |
| query/rows getDouble, getLong of decimal | 100000 | 87.60 | 21.99 | 4.0× | 320 | 0 |
| query/query!T | 100000 | 39.02 | 37.73 | 1.0× | 32 | 32 |
| query/queryValue with 1 parameter (per call) | 50000 | 137.99 | 83.49 | 1.7× | 2992 | 1856 |
| query/1 MB nvarchar(max) getString (per value) | 50 | 27.95 | 28.74 | 1.0× | 564253 | 623024 |
| query/column metadata, 8 columns (per query) | 50000 | 63.61 | 40.47 | 1.6× | 1392 | 1232 |
| exec/5 parameters (per call) | 50000 | 189.21 | 65.16 | 2.9× | 4288 | 928 |
| exec/1 int parameter (per call) | 100000 | 125.07 | 43.15 | 2.9× | 1152 | 144 |
| exec/batch without parameters (per call) | 100000 | 19.81 | 14.17 | 1.4× | 64 | 0 |
| exec/prepared, 5 parameters (per call) | 50000 | 135.91 | 61.89 | 2.2× | 3408 | 944 |
| insert/structs, 5 fields | 20000 | 59.10 | 15.31 | 3.9× | 4951 | 124 |
| bulk/addRow, 5 columns | 50000 | 61.73 | 34.84 | 1.8× | 1248 | 208 |
| bulk/structs, 5 fields | 50000 | 91.22 | 33.75 | 2.7× | 2608 | 208 |
| value/int getString | 1000000 | 38.79 | 31.94 | 1.2× | 16 | 16 |
| value/decimal(18,2) getString | 1000000 | 67.64 | 61.03 | 1.1× | 16 | 16 |
| value/decimal(18,2) getDouble | 1000000 | 512.00 | 6.51 | 78.7× | 192 | 0 |
| value/decimal(18,2) getLong | 1000000 | 315.35 | 6.63 | 47.6× | 128 | 0 |
| value/money getDouble | 1000000 | 516.46 | 6.02 | 85.8× | 192 | 0 |
| value/money getLong | 1000000 | 307.28 | 6.09 | 50.4× | 128 | 0 |
| value/float getString | 1000000 | 282.38 | 251.47 | 1.1× | 16 | 16 |
| value/datetime2(7) getString | 1000000 | 1030.71 | 68.66 | 15.0× | 192 | 32 |
| value/datetimeoffset(7) getString | 1000000 | 1415.36 | 76.95 | 18.4× | 288 | 48 |
| value/datetimeoffset(7) getSysTime | 1000000 | 44.66 | 11.93 | 3.7× | 96 | 0 |
| value/date getString | 1000000 | 353.25 | 48.10 | 7.3× | 48 | 16 |
| value/datetime getString | 1000000 | 1041.68 | 67.81 | 15.4× | 192 | 32 |
| value/uniqueidentifier getString | 1000000 | 621.42 | 46.78 | 13.3× | 128 | 48 |
| value/varbinary(32) getString | 1000000 | 3761.51 | 61.46 | 61.2× | 272 | 96 |
| params/Parameter.of Variant int | 1000000 | 44.58 | 43.61 | 1.0× | 16 | 16 |
| params/Parameter.of Variant Date | 1000000 | 52.58 | 50.33 | 1.0× | 16 | 16 |
| params/Parameter.of Variant UUID | 1000000 | 51.05 | 47.12 | 1.1× | 32 | 32 |
| params/Parameter.of int | 1000000 | 33.31 | 31.11 | 1.1× | 16 | 16 |
| params/Parameter.of string | 1000000 | 42.27 | 40.41 | 1.0× | 32 | 32 |
| params/Parameter.of Decimal | 1000000 | 193.22 | 42.76 | 4.5× | 96 | 32 |
| params/Parameter.of DateTime | 1000000 | 116.36 | 47.80 | 2.4× | 48 | 16 |
| params/Parameter.of SysTime | 1000000 | 188.12 | 74.96 | 2.5× | 64 | 16 |
| params/rewritePlaceholders, 5 placeholders | 1000000 | 691.84 | 211.78 | 3.3× | 416 | 128 |

The requests are byte for byte what `main` sends (checked by capturing every
request of a script of batches, `exec` with parameters, prepared statements,
`insert` and bulk loads through the fake server).

Not changed by #43: plain row decoding (values are offsets into a reused
buffer), `query!T`, `Parameter.of` of plain values and `Variant`s (#42
already compares `TypeInfo` by identity first), float text (dbwire's
`shortestDigits`, #41) and `nvarchar(max)` text, whose cost is dbwire's
UTF-16 decoder. Not measured here: the extra `recv` per TDS packet (the
header is read separately) and the 4096-byte default packet size, which need
a real server.
