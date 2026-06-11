#!/usr/bin/env python3
"""Extract NES CHR-ROM tiles from Super Mario Bros ROM to individual PCX files.

NES CHR-ROM format: 512 tiles, each 8x8 pixels, 2bpp planar.
Each tile = 16 bytes: bytes 0-7 = bit plane 0, bytes 8-15 = bit plane 1.
Pixel color index = (plane1_bit << 1) | plane0_bit, giving values 0-3.

Output: 512 PCX files (tile_000.pcx through tile_511.pcx) in character_data/
       Each tile is resized from 8x8 using area-based downsampling
       for the Lynx 160x102 display.
"""

import argparse
import os
import sys
from PIL import Image

from area_downsample import area_downsample

ROM_PATH = "rom/SuperMarioBros.nes"
CHR_OFFSET = 0x8010  # 16-byte iNES header + 32KB PRG-ROM
CHR_SIZE = 8192       # 8KB CHR-ROM
TILE_BYTES = 16       # 16 bytes per tile (2bpp planar)
TILE_COUNT = CHR_SIZE // TILE_BYTES  # 512 tiles
OUTPUT_DIR = "character_data"

# 4-color palette for the PCX files (just for visual representation)
# Actual colors applied at runtime via Lynx palette
PALETTE = [
    (0, 0, 0),         # Index 0: black
    (85, 85, 85),      # Index 1: dark gray
    (170, 170, 170),   # Index 2: light gray
    (255, 255, 255),   # Index 3: white
]


def decode_tile(tile_data):
    """Decode a 16-byte NES 2bpp planar tile into 8x8 pixel indices (0-3)."""
    pixels = []
    for row in range(8):
        plane0 = tile_data[row]
        plane1 = tile_data[row + 8]
        row_pixels = []
        for bit in range(7, -1, -1):  # MSB first
            p0 = (plane0 >> bit) & 1
            p1 = (plane1 >> bit) & 1
            row_pixels.append((p1 << 1) | p0)
        pixels.append(row_pixels)
    return pixels


def create_pcx(pixels, filepath, tile_w, tile_h):
    """Create an indexed-color PCX file from pixel data (resized from 8x8)."""
    scaled = area_downsample(pixels, 8, 8, tile_w, tile_h)

    img = Image.new('P', (tile_w, tile_h))

    # Set palette (256 entries required for P mode, pad with black)
    pal = []
    for r, g, b in PALETTE:
        pal.extend([r, g, b])
    pal.extend([0, 0, 0] * (256 - len(PALETTE)))  # Pad to 256 colors
    img.putpalette(pal)

    # Set pixel data
    for y, row in enumerate(scaled):
        for x, val in enumerate(row):
            img.putpixel((x, y), val)


    img.save(filepath, format='PCX')


def main():
    parser = argparse.ArgumentParser(description="Extract NES CHR-ROM tiles to PCX files")
    parser.add_argument('--tile-width', type=int, default=5, help='Output tile width (default: 5)')
    parser.add_argument('--tile-height', type=int, default=4, help='Output tile height (default: 4)')
    args = parser.parse_args()

    if not os.path.exists(ROM_PATH):
        print(f"Error: ROM not found at {ROM_PATH}")
        sys.exit(1)

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    with open(ROM_PATH, 'rb') as f:
        f.seek(CHR_OFFSET)
        chr_data = f.read(CHR_SIZE)

    if len(chr_data) < CHR_SIZE:
        print(f"Error: CHR-ROM too small ({len(chr_data)} bytes, expected {CHR_SIZE})")
        sys.exit(1)

    print(f"Extracting {TILE_COUNT} tiles from {ROM_PATH} ({args.tile_width}x{args.tile_height})...")

    for i in range(TILE_COUNT):
        tile_data = chr_data[i * TILE_BYTES : (i + 1) * TILE_BYTES]
        pixels = decode_tile(tile_data)
        filepath = os.path.join(OUTPUT_DIR, f"tile_{i:03d}.pcx")
        create_pcx(pixels, filepath, args.tile_width, args.tile_height)

    print(f"Done. {TILE_COUNT} tiles written to {OUTPUT_DIR}/")

    # Show a few notable tiles
    print(f"\nNotable tiles:")
    print(f"  tile_206.pcx = Mushroom icon ($CE)")
    print(f"  tile_036.pcx = Blank tile ($24)")


if __name__ == "__main__":
    main()
