#!/usr/bin/env python3
"""Patch floating score number sprites with custom 5x4 pixel font glyphs.

SMB displays floating point numbers (100, 200, 400, etc.) when enemies are
stomped or items collected. These use pairs of 8x8 NES sprite tiles, each
containing two pre-rendered characters side by side. At 5x4 downscale, each
sub-character is ~2.5px wide and unreadable.

This script patches specific tiles in build/sprite_tiles.bin with hand-crafted
5x4 composite glyphs designed for legibility at the Lynx's resolution.

Tiles patched (Pattern Table 0 indices):
  $F6 (246) = "10"  (left half of 100/1000)
  $F7 (247) = "20"  (left half of 200/2000)
  $F8 (248) = "40"  (left half of 400/4000)
  $F9 (249) = "50"  (left half of 500/5000)
  $FA (250) = "80"  (left half of 800/8000)
  $50 (80)  = "00"  (right half of x000)
  $FB (251) = "0"   (right half of x00)
  $FD (253) = "1-"  (left half of 1-UP)
  $FE (254) = "UP"  (right half of 1-UP)
"""

import argparse
import os
import sys

SPRITE_TILES = "build/sprite_tiles.bin"


def _g(*rows):
    """Parse strings of '#'/'.' into a pixel grid.

    NES floating score sprites use color index 2 for strokes (not 1).
    """
    return [[2 if c == '#' else 0 for c in r] for r in rows]


def pixels_to_lynx_sprite(grid):
    """Convert pixel grid to Lynx literal 2bpp sprite data."""
    data = bytearray()
    for row in grid:
        byte0 = (row[0] << 6) | (row[1] << 4) | (row[2] << 2) | row[3]
        byte1 = (row[4] << 6)
        data.extend([0x03, byte0, byte1])
    data.append(0x00)
    return bytes(data)


# ---------------------------------------------------------------------------
# Composite score glyphs — two characters per 5x5 tile.
# Layout: 2px left digit + 3px right digit (diamond "0" pattern), or
#         1px left digit + 1px gap + 3px right digit for narrow characters.
# These use the full 5px width (no right margin — sprites are standalone).
# ---------------------------------------------------------------------------

SCORE_SPRITES = {
    # $F6 "10": 1px "1" at col 0, 1px gap, 3px diamond "0" at cols 2-4
    0xF6: _g("#..#.",
             "#.#.#",
             "#.#.#",
             "#..#."),

    # $F7 "20": 2px "2" at cols 0-1, 3px diamond "0" at cols 2-4
    0xF7: _g("##.#.",
             ".##.#",
             "#.#.#",
             "##.#."),

    # $F8 "40": 2px "4" at cols 0-1, 3px diamond "0" at cols 2-4
    0xF8: _g("##.#.",
             "###.#",
             ".##.#",
             ".#.#."),

    # $F9 "50": 2px "5" at cols 0-1, 3px diamond "0" at cols 2-4
    0xF9: _g("##.#.",
             "#.#.#",
             ".##.#",
             "##.#."),

    # $FA "80": 2px hourglass "8" at cols 0-1, 3px diamond "0" at cols 2-4
    0xFA: _g(".#.#.",
             "###.#",
             "###.#",
             ".#.#."),

    # $50 "00": two 2px diamond "0"s at cols 0-1 and 2-3, col 4 blank
    0x50: _g(".#.#.",
             "#.#.#",
             "#.#.#",
             ".#.#."),

    # $FB "0": single 3px diamond "0" at cols 0-2, cols 3-4 blank
    0xFB: _g(".#...",
             "#.#..",
             "#.#..",
             ".#..."),

    # $FD "1-": "1" at col 1, "-" at cols 3-4
    0xFD: _g(".#...",
             "##.##",
             ".#...",
             ".#..."),

    # $FE "UP": 2px "U" at cols 0-1, 2px "P" at cols 3-4, gap at col 2
    0xFE: _g("##.##",
             "##.##",
             "##.#.",
             ".#.#."),
}


def main():
    parser = argparse.ArgumentParser(description="Patch floating score number sprites")
    parser.add_argument('--tile-width', type=int, default=5, help='Tile width (default: 5)')
    parser.add_argument('--tile-height', type=int, default=4, help='Tile height (default: 4)')
    args = parser.parse_args()

    tile_h = args.tile_height
    TILE_SIZE = tile_h * 3 + 1  # 13 for h=4, 16 for h=5

    if not os.path.exists(SPRITE_TILES):
        print(f"Error: {SPRITE_TILES} not found (run asset build first)")
        sys.exit(1)

    with open(SPRITE_TILES, 'rb') as f:
        data = bytearray(f.read())

    expected_size = 256 * TILE_SIZE
    if len(data) != expected_size:
        print(f"Error: {SPRITE_TILES} is {len(data)} bytes, expected {expected_size}")
        sys.exit(1)

    patched = 0
    for tile_idx, grid in SCORE_SPRITES.items():
        # For 5x5 mode, pad 4-row grids with a blank 5th row
        if tile_h == 5 and len(grid) == 4:
            grid = grid + [[0, 0, 0, 0, 0]]
        sprite_data = pixels_to_lynx_sprite(grid)
        if len(sprite_data) != TILE_SIZE:
            print(f"Warning: tile ${tile_idx:02X} sprite size {len(sprite_data)} != {TILE_SIZE}")
            sprite_data = sprite_data[:TILE_SIZE].ljust(TILE_SIZE, b'\x00')
        offset = tile_idx * TILE_SIZE
        data[offset:offset + TILE_SIZE] = sprite_data
        patched += 1

    with open(SPRITE_TILES, 'wb') as f:
        f.write(data)

    print(f"Patched {patched} score sprite tiles in {SPRITE_TILES}")
    for tile_idx in sorted(SCORE_SPRITES.keys()):
        print(f"  ${tile_idx:02X} ({tile_idx})")


if __name__ == "__main__":
    main()
