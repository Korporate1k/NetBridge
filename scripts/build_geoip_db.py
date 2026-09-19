#!/usr/bin/env python3
"""Converts a DB-IP Lite City IPv4 CSV (the "-num" variant, where
ip_range_start/ip_range_end are plain integers) into the compact binary
format LocalProxy/GeoIPLookup.swift reads directly from the app bundle.

Source data: https://github.com/sapics/ip-location-db (dbip-city, CC BY 4.0
by DB-IP.com — see LocalProxy/Resources/GEOIP-ATTRIBUTION.md). This script is
a maintenance tool, run manually/periodically — it is NOT part of the Xcode
build, which stays network-free.

Usage:
    curl -L -o dbip-city-ipv4-num.csv.gz \\
        https://github.com/sapics/ip-location-db/releases/download/latest/dbip-city-ipv4-num.csv.gz
    python3 scripts/build_geoip_db.py dbip-city-ipv4-num.csv.gz LocalProxy/Resources/GeoIPv4.bin

Output format (all multi-byte integers big-endian):
    header:  recordCount: UInt32 | cityTableOffset: UInt32 (from file start)
    records: recordCount * { rangeStart: UInt32 | rangeEnd: UInt32 |
                              countryCode: 2 raw ASCII bytes |
                              cityIndex: UInt32 (0xFFFFFFFF = none) }
             sorted ascending by rangeStart, 14 bytes each
    city table: deduplicated NUL-terminated UTF-8 strings; cityIndex is a
                byte offset *within this table* (add cityTableOffset for the
                absolute file offset)
"""
import csv
import gzip
import struct
import sys

HEADER = struct.Struct(">II")
RECORD = struct.Struct(">II2sI")
NO_CITY = 0xFFFFFFFF


def open_maybe_gzip(path):
    if path.endswith(".gz"):
        return gzip.open(path, mode="rt", newline="", encoding="utf-8")
    return open(path, mode="rt", newline="", encoding="utf-8")


def read_rows(path):
    """Yields (start: int, end: int, country: str, city: str), merging
    adjacent ranges that share the same country+city (the source data is
    often split far finer than that, e.g. per announced prefix)."""
    pending = None
    with open_maybe_gzip(path) as f:
        for row in csv.reader(f):
            if len(row) < 6:
                continue
            start, end, country = int(row[0]), int(row[1]), row[2].strip()
            city = row[5].strip()
            if not country or country == "-":
                country = "??"
            country = country[:2].upper().ljust(2, "?")

            if pending is not None:
                pstart, pend, pcountry, pcity = pending
                if start == pend + 1 and country == pcountry and city == pcity:
                    pending = (pstart, end, pcountry, pcity)
                    continue
                yield pending
            pending = (start, end, country, city)
    if pending is not None:
        yield pending


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <dbip-city-ipv4-num.csv[.gz]> <output GeoIPv4.bin>", file=sys.stderr)
        sys.exit(1)
    src, dst = sys.argv[1], sys.argv[2]

    city_offsets: dict[str, int] = {}
    city_table = bytearray()

    def city_index(city: str) -> int:
        if not city:
            return NO_CITY
        if city in city_offsets:
            return city_offsets[city]
        offset = len(city_table)
        city_offsets[city] = offset
        city_table.extend(city.encode("utf-8"))
        city_table.append(0)
        return offset

    records = bytearray()
    count = 0
    prev_start = -1
    for start, end, country, city in read_rows(src):
        if start <= prev_start:
            # Source data is expected sorted; guard rather than silently
            # producing a table binary search can't trust.
            raise SystemExit(f"input not sorted ascending: {start} after {prev_start}")
        prev_start = start
        records += RECORD.pack(start, end, country.encode("ascii", "replace"), city_index(city))
        count += 1
        if count % 200_000 == 0:
            print(f"  ...{count} records so far", file=sys.stderr)

    city_table_offset = HEADER.size + len(records)
    with open(dst, "wb") as out:
        out.write(HEADER.pack(count, city_table_offset))
        out.write(records)
        out.write(city_table)

    total = HEADER.size + len(records) + len(city_table)
    print(f"wrote {dst}: {count} records, {len(city_offsets)} unique cities, "
          f"{total / 1_048_576:.1f} MiB total ({len(records) / 1_048_576:.1f} MiB records + "
          f"{len(city_table) / 1_048_576:.1f} MiB city table)")


if __name__ == "__main__":
    main()
