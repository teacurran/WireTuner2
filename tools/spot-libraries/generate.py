#!/usr/bin/env python3
"""Spot colour library generator (CMS-014; docs/_includes/cms/color-tables.adoc, decisions.adoc D-072).

Reads a vendor's ink table as CSV -- a header row, then one row per ink:
    name,lab_l,lab_a,lab_b,c,m,y,k
(Lab D50 2-degree measured values; nominal process mix as fractions 0..1) -- and writes the
SpotLibrary resource WTColor.SpotLibraryStore reads: the sketched protobuf message in wire format
(SpotLibrary: id 1, name 2, version 3, inks 4; SpotInk: name 1, lab_l 2 ... k 8 as float).

    generate.py --id pantone-solid-coated --name "PANTONE Solid Coated" --version 2023 inks.csv out.binpb

Only data whose licence has been checked and recorded in decisions.adoc may be bundled.
"""
import argparse
import csv
import struct
import sys


def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def length_delimited(field, payload):
    return varint(field << 3 | 2) + varint(len(payload)) + payload


def string(field, value):
    return length_delimited(field, value.encode("utf-8")) if value else b""


def float32(field, value):
    return varint(field << 3 | 5) + struct.pack("<f", value) if value != 0 else b""


def library(library_id, name, version, rows):
    out = string(1, library_id) + string(2, name) + string(3, version)
    for row in rows:
        ink = string(1, row["name"])
        for number, key in enumerate(["lab_l", "lab_a", "lab_b", "c", "m", "y", "k"], start=2):
            ink += float32(number, float(row[key]))
        out += length_delimited(4, ink)
    return out


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--id", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", default="")
    parser.add_argument("csv")
    parser.add_argument("output")
    args = parser.parse_args(argv)
    with open(args.csv, newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    with open(args.output, "wb") as handle:
        handle.write(library(args.id, args.name, args.version, rows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
