#!/usr/bin/env python3
"""Convert cc65 .dbg debug file to VICE .lab label file for Felix emulator."""

import re
import sys


def convert_dbg_to_lab(dbg_path, lab_path):
    symbols = []
    with open(dbg_path, "r") as f:
        for line in f:
            if not line.startswith("sym\t"):
                continue
            name_m = re.search(r'name="([^"]+)"', line)
            val_m = re.search(r'val=0x([0-9A-Fa-f]+)', line)
            type_m = re.search(r'type=(\w+)', line)
            if name_m and val_m:
                # Skip equates (type=equ) — only emit labels
                if type_m and type_m.group(1) == "equ":
                    continue
                name = name_m.group(1)
                addr = int(val_m.group(1), 16)
                if addr <= 0xFFFF:
                    symbols.append((addr, name))

    symbols.sort()

    with open(lab_path, "w") as f:
        for addr, name in symbols:
            f.write(f"al {addr:04X} .{name}\n")

    print(f"Wrote {len(symbols)} symbols to {lab_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.dbg output.lab", file=sys.stderr)
        sys.exit(1)
    convert_dbg_to_lab(sys.argv[1], sys.argv[2])
