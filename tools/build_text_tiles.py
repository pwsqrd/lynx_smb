#!/usr/bin/env python3
"""Build dense text tile subset for the Lynx port.

Extracts only the BG tiles needed for title screen text and HUD,
creates a dense blob + 256-byte index table. This replaces the full
bg_tiles.bin (4,096 bytes for all 256 BG tiles) with a much smaller
subset.

Text glyphs ($00-$09 digits, $0A-$23 letters, $28 dash, $29 multiply)
use a custom 4px-wide font (rightmost column always blank) for 1px
inter-character spacing on the 5px tile grid. Other tiles ($24 space,
$25-$27 fills, $CE mushroom, $CF copyright) use area downsampling.

Output:
  build/text_tiles.bin        - dense blob of 5x5 tile sprites (16 bytes each)
  build/text_tile_index.bin   - 256-byte lookup (tile index -> dense index, $FF=missing)
"""

import os
import subprocess
import sys
from PIL import Image

from area_downsample import area_downsample

# Paths
ROM_PATH = "rom/SuperMarioBros.nes"
SP65 = os.environ.get("SP65", "sp65")
OUTPUT_BLOB = "build/text_tiles.bin"
OUTPUT_INDEX = "build/text_tile_index.bin"
TEMP_DIR = "build/text_tiles_tmp"

# NES CHR-ROM layout
CHR_OFFSET = 0x8010
TILE_BYTES = 16

# Expected size of each converted tile (literal 1bpp 5x5)
TILE_SPRITE_SIZE = 11

# Tiles that need 2bpp (multi-color area-downsampled graphics)
TILES_2BPP = {0xCE, 0xCF}
TILE_2BPP_SIZE = 16

# Tile indices to include (BG Pattern Table 1)
# $00-$29: full alphanumeric + punctuation set
# $CE: mushroom icon, $CF: copyright symbol
NEEDED_TILES = list(range(0x00, 0x2A)) + [0x2B, 0x2E, 0xAF, 0xCE, 0xCF]

# 4-color grayscale palette
PALETTE = [
    (0, 0, 0),
    (85, 85, 85),
    (170, 170, 170),
    (255, 255, 255),
]

# ---------------------------------------------------------------------------
# Custom 4px-wide font — 1px strokes, rightmost column always blank.
# This gives 1px inter-character spacing when tiles are placed at 5px stride.
# '#' = color index 1, '.' = 0 (transparent).
# ---------------------------------------------------------------------------

def _g(*rows):
    """Parse 5 strings of '#'/'.' into a 5x5 pixel grid."""
    return [[1 if c == '#' else 0 for c in r] for r in rows]

CUSTOM_FONT = {
    # Digits 0-9
    0x00: _g(".##..",  # 0
             "#..#.",
             "#..#.",
             "#..#.",
             ".##.."),
    0x01: _g("..#..",  # 1
             ".##..",
             "..#..",
             "..#..",
             ".###."),
    0x02: _g(".##..",  # 2
             "...#.",
             ".##..",
             "#....",
             "####."),
    0x03: _g(".##..",  # 3
             "...#.",
             "..#..",
             "...#.",
             ".##.."),
    0x04: _g("#.#..",  # 4
             "#.#..",
             "####.",
             "..#..",
             "..#.."),
    0x05: _g("####.",  # 5
             "#....",
             "###..",
             "...#.",
             ".##.."),
    0x06: _g(".##..",  # 6
             "#....",
             "###..",
             "#..#.",
             ".##.."),
    0x07: _g("####.",  # 7
             "...#.",
             "..#..",
             "..#..",
             "..#.."),
    0x08: _g(".##..",  # 8
             "#..#.",
             ".##..",
             "#..#.",
             ".##.."),
    0x09: _g(".##..",  # 9
             "#..#.",
             ".###.",
             "...#.",
             ".##.."),
    # Letters A-Z
    0x0A: _g(".##..",  # A
             "#..#.",
             "####.",
             "#..#.",
             "#..#."),
    0x0B: _g("###..",  # B
             "#..#.",
             "###..",
             "#..#.",
             "###.."),
    0x0C: _g(".###.",  # C
             "#....",
             "#....",
             "#....",
             ".###."),
    0x0D: _g("###..",  # D
             "#..#.",
             "#..#.",
             "#..#.",
             "###.."),
    0x0E: _g("####.",  # E
             "#....",
             "###..",
             "#....",
             "####."),
    0x0F: _g("####.",  # F
             "#....",
             "###..",
             "#....",
             "#...."),
    0x10: _g(".###.",  # G
             "#....",
             "#.##.",
             "#..#.",
             ".##.."),
    0x11: _g("#..#.",  # H
             "#..#.",
             "####.",
             "#..#.",
             "#..#."),
    0x12: _g(".###.",  # I
             "..#..",
             "..#..",
             "..#..",
             ".###."),
    0x13: _g(".###.",  # J
             "..#..",
             "..#..",
             "#.#..",
             ".#..."),
    0x14: _g("#..#.",  # K
             "#.#..",
             "##...",
             "#.#..",
             "#..#."),
    0x15: _g("#....",  # L
             "#....",
             "#....",
             "#....",
             "####."),
    0x16: _g("#..#.",  # M — bridge at top (row 1), distinct from H (row 2)
             "####.",
             "#..#.",
             "#..#.",
             "#..#."),
    0x17: _g("#..#.",  # N — alternating inner pixels suggest diagonal
             "##.#.",
             "#.##.",
             "#..#.",
             "#..#."),
    0x18: _g(".##..",  # O
             "#..#.",
             "#..#.",
             "#..#.",
             ".##.."),
    0x19: _g("###..",  # P
             "#..#.",
             "###..",
             "#....",
             "#...."),
    0x1A: _g(".##..",  # Q — dot inside + tail at bottom-right
             "#..#.",
             "#.#..",
             "#..#.",
             ".###."),
    0x1B: _g("###..",  # R
             "#..#.",
             "###..",
             "#.#..",
             "#..#."),
    0x1C: _g(".###.",  # S — asymmetric top/bottom show direction
             "#....",
             ".##..",
             "...#.",
             "###.."),
    0x1D: _g("####.",  # T
             ".#...",
             ".#...",
             ".#...",
             ".#..."),
    0x1E: _g("#..#.",  # U
             "#..#.",
             "#..#.",
             "#..#.",
             ".##.."),
    0x1F: _g("#..#.",  # V — narrows to 1px, distinct from U (2px bottom)
             "#..#.",
             "#..#.",
             ".##..",
             "..#.."),
    0x20: _g("#..#.",  # W — bridge at bottom (row 3), distinct from M/H
             "#..#.",
             "#..#.",
             "####.",
             "#..#."),
    0x21: _g("#..#.",  # X
             ".##..",
             "..#..",
             ".##..",
             "#..#."),
    0x22: _g("#..#.",  # Y
             ".##..",
             "..#..",
             "..#..",
             "..#.."),
    0x23: _g("####.",  # Z
             "...#.",
             "..#..",
             ".#...",
             "####."),
    # Punctuation
    0x28: _g(".....",  # dash -
             ".....",
             ".###.",
             ".....",
             "....."),
    0x29: _g(".....",  # multiply x
             ".#.#.",
             "..#..",
             ".#.#.",
             "....."),
    # Icons
    0x2B: _g("..#..",  # ! (exclamation mark)
             "..#..",
             "..#..",
             ".....",
             "..#.."),
    0x2E: _g(".##..",  # coin icon (filled circle)
             "####.",
             "####.",
             "####.",
             ".##.."),
    0xAF: _g(".....",  # . (period)
             ".....",
             ".....",
             ".....",
             "..#.."),
}


def pixels_to_lynx_sprite_1bpp(grid):
    """Convert 5x5 pixel grid to 11-byte Lynx literal 1bpp sprite data.

    Format: 5 rows x [0x02, data_byte] + [0x00] terminator = 11 bytes.
    Pixels packed MSB-first, 1 bit per pixel.
    """
    data = bytearray()
    for row in grid:
        byte0 = (row[0] << 7) | (row[1] << 6) | (row[2] << 5) | (row[3] << 4) | (row[4] << 3)
        data.extend([0x02, byte0])
    data.append(0x00)  # terminator
    return bytes(data)


def pixels_to_lynx_sprite_2bpp(grid):
    """Convert 5x5 pixel grid to 16-byte Lynx literal 2bpp sprite data.

    Format: 5 rows x [0x03, data_hi, data_lo] + [0x00] terminator = 16 bytes.
    Pixels packed MSB-first, 2 bits per pixel.
    """
    data = bytearray()
    for row in grid:
        byte0 = (row[0] << 6) | (row[1] << 4) | (row[2] << 2) | row[3]
        byte1 = (row[4] << 6)
        data.extend([0x03, byte0, byte1])
    data.append(0x00)  # terminator
    return bytes(data)


def load_chr_rom():
    with open(ROM_PATH, 'rb') as f:
        f.seek(CHR_OFFSET)
        return f.read(8192)


def decode_tile_8x8(chr_data, tile_index):
    """Decode a BG tile (Pattern Table 1) into 8x8 pixel indices."""
    rom_tile = 256 + tile_index
    offset = rom_tile * TILE_BYTES
    tile_data = chr_data[offset:offset + TILE_BYTES]

    pixels = []
    for row in range(8):
        plane0 = tile_data[row]
        plane1 = tile_data[row + 8]
        row_pixels = []
        for bit in range(7, -1, -1):
            p0 = (plane0 >> bit) & 1
            p1 = (plane1 >> bit) & 1
            row_pixels.append((p1 << 1) | p0)
        pixels.append(row_pixels)
    return pixels


def main():
    os.makedirs(TEMP_DIR, exist_ok=True)
    os.makedirs("build", exist_ok=True)

    print(f"Loading CHR-ROM from {ROM_PATH}...")
    chr_data = load_chr_rom()

    dense_data = []
    index_table = [0xFF] * 256
    converted = 0
    custom_count = 0

    tiles_2bpp_data = {}  # tile_idx -> 2bpp sprite bytes

    for tile_idx in NEEDED_TILES:
        # Check for custom font glyph first
        if tile_idx in CUSTOM_FONT:
            data = pixels_to_lynx_sprite_1bpp(CUSTOM_FONT[tile_idx])
            dense_idx = len(dense_data)
            dense_data.append(data)
            index_table[tile_idx] = dense_idx
            converted += 1
            custom_count += 1
            continue

        # Area downsample from NES CHR-ROM
        pixels = decode_tile_8x8(chr_data, tile_idx)
        scaled = area_downsample(pixels, 8, 8, 5, 5)

        if tile_idx in TILES_2BPP:
            # Keep full 2bpp for multi-color tiles (mushroom, copyright)
            data = pixels_to_lynx_sprite_2bpp(scaled)
            tiles_2bpp_data[tile_idx] = data
            converted += 1
            # Don't add to dense_data / index_table (handled separately in asm)
            continue

        # Clamp to 1bpp: any non-zero pixel becomes 1
        grid_1bpp = [[min(p, 1) for p in row] for row in scaled]
        data = pixels_to_lynx_sprite_1bpp(grid_1bpp)

        dense_idx = len(dense_data)
        dense_data.append(data)
        index_table[tile_idx] = dense_idx
        converted += 1

    # Write 1bpp dense blob
    with open(OUTPUT_BLOB, 'wb') as f:
        for data in dense_data:
            f.write(data)
    blob_size = sum(len(d) for d in dense_data)

    # Write 2bpp tiles as separate file
    output_2bpp = "build/text_tiles_2bpp.bin"
    with open(output_2bpp, 'wb') as f:
        for tile_idx in sorted(tiles_2bpp_data.keys()):
            f.write(tiles_2bpp_data[tile_idx])
    bpp2_size = sum(len(d) for d in tiles_2bpp_data.values())

    # Write index table (2bpp tiles get $FF since they're handled separately)
    with open(OUTPUT_INDEX, 'wb') as f:
        f.write(bytes(index_table))

    total_size = blob_size + bpp2_size
    print(f"\nConverted {converted} text tiles ({custom_count} custom font, "
          f"{converted - custom_count} area downsampled, {len(tiles_2bpp_data)} kept as 2bpp)")
    print(f"1bpp blob: {OUTPUT_BLOB} ({blob_size} bytes, {len(dense_data)} tiles x {TILE_SPRITE_SIZE})")
    print(f"2bpp tiles: {output_2bpp} ({bpp2_size} bytes, {len(tiles_2bpp_data)} tiles x {TILE_2BPP_SIZE})")
    print(f"Total: {total_size} bytes (vs 4,096 for full bg_tiles.bin)")


if __name__ == "__main__":
    main()
