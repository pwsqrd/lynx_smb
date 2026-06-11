# Place the NES ROM here

This port extracts **all** of its graphics and game data from the original
*Super Mario Bros.* NES ROM at build time. The ROM is copyrighted and is **not**
included in this repository — you must supply your own legally-obtained copy.

Drop the ROM file into this directory. **Any filename works** — the build
matches it by checksum, not by name (`tools/verify_rom.py`).

The required dump is:

| Field | Value |
|-------|-------|
| Name  | `Super Mario Bros (JU) (PRG 0).nes` |
| Size  | 40976 bytes |
| MD5   | `811b027eaf99c2def7b933c5208636de` |
| SHA-1 | `ea343f4e445a9050d4b4fbac2c77d0693b1d0922` |

If the ROM is missing or does not match, the build stops with an error listing
exactly these values.
