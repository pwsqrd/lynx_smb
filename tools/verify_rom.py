#!/usr/bin/env python3
"""Verify the Super Mario Bros NES ROM by checksum (not by filename).

The asset pipeline reads the ROM from ``rom/SuperMarioBros.nes``. This script
scans the ``rom/`` directory for *any* file whose contents match the expected
ROM, and if found makes ``rom/SuperMarioBros.nes`` point at it. This means the
user can drop the ROM in under any filename.

On failure it prints exactly what it is looking for (size + MD5 + SHA-1) so the
user knows which dump is required.

Exit codes: 0 = ROM present and verified, 1 = not found / mismatch.
"""

import hashlib
import os
import sys

ROM_DIR = "rom"
CANONICAL = os.path.join(ROM_DIR, "SuperMarioBros.nes")

# Super Mario Bros. (World) — iNES dump, PRG0. The single ROM this port targets.
EXPECTED_NAME = "Super Mario Bros (JU) (PRG 0).nes"
EXPECTED_SIZE = 40976  # 16-byte iNES header + 32 KB PRG + 8 KB CHR
EXPECTED_MD5 = "811b027eaf99c2def7b933c5208636de"
EXPECTED_SHA1 = "ea343f4e445a9050d4b4fbac2c77d0693b1d0922"


def hashes(path):
    md5 = hashlib.md5()
    sha1 = hashlib.sha1()
    size = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            md5.update(chunk)
            sha1.update(chunk)
            size += len(chunk)
    return size, md5.hexdigest(), sha1.hexdigest()


def is_match(path):
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    if size != EXPECTED_SIZE:
        return False
    _, _, sha1 = hashes(path)
    return sha1 == EXPECTED_SHA1


def fail():
    sys.stderr.write(
        "\n"
        "ERROR: Required NES ROM not found in '{rom}/'.\n\n"
        "This port extracts all graphics and data from the original ROM at build\n"
        "time, so you must supply your own copy. Place the ROM file anywhere in\n"
        "the '{rom}/' directory (any filename is fine — it is matched by checksum).\n\n"
        "Expected ROM:\n"
        "  Name : {name}\n"
        "  Size : {size} bytes\n"
        "  MD5  : {md5}\n"
        "  SHA-1: {sha1}\n\n".format(
            rom=ROM_DIR,
            name=EXPECTED_NAME,
            size=EXPECTED_SIZE,
            md5=EXPECTED_MD5,
            sha1=EXPECTED_SHA1,
        )
    )
    sys.exit(1)


def main():
    if not os.path.isdir(ROM_DIR):
        fail()

    # If the canonical path already resolves to the right ROM, we are done.
    if os.path.exists(CANONICAL) and is_match(CANONICAL):
        print("ROM verified: {} (SHA-1 {})".format(CANONICAL, EXPECTED_SHA1))
        return

    # Otherwise scan rom/ for any file matching by checksum.
    for entry in sorted(os.listdir(ROM_DIR)):
        path = os.path.join(ROM_DIR, entry)
        if not os.path.isfile(path):
            continue
        if os.path.realpath(path) == os.path.realpath(CANONICAL):
            continue
        if is_match(path):
            # Point the canonical name at the verified file for the pipeline.
            if os.path.lexists(CANONICAL):
                os.remove(CANONICAL)
            try:
                os.symlink(os.path.basename(path), CANONICAL)
            except (OSError, NotImplementedError):
                import shutil
                shutil.copyfile(path, CANONICAL)
            print("ROM verified: {} -> {} (SHA-1 {})".format(
                CANONICAL, entry, EXPECTED_SHA1))
            return

    fail()


if __name__ == "__main__":
    main()
