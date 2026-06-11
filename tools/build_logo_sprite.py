#!/usr/bin/env python3
"""Build pre-composited title logo sprite for the Lynx port.

Composites the 22x11 title logo tile grid from NES CHR-ROM at full 8x8
resolution (176x88), then downscales to Lynx size (110x44) and converts
to a packed Lynx sprite via sp65.

Output:
  character_data/logo/logo_unscaled.pcx  - full 176x88 composite
  character_data/logo/logo_scaled.pcx    - downscaled 110x44
  build/logo_sprite.bin                  - packed Lynx sprite (2bpp)
"""

import argparse
import os
import subprocess
import sys
from PIL import Image

from area_downsample import area_downsample

# Paths
ROM_PATH = "rom/SuperMarioBros.nes"
SP65 = os.environ.get("SP65", "sp65")
LOGO_DIR = "character_data/logo"
OUTPUT_BIN = "build/logo_sprite.bin"

# NES CHR-ROM layout
CHR_OFFSET = 0x8010  # 16-byte iNES header + 32KB PRG-ROM
TILE_BYTES = 16       # 16 bytes per NES tile (2bpp planar)

# Logo grid: 22 columns x 11 rows (from TitleLogoTiles in lynx_sprites.s)
LOGO_COLS = 22
LOGO_ROWS = 11

# Tile grid data (BG tile indices from Pattern Table 1)
# Extracted from TitleLogoTiles in lynx_sprites.s
LOGO_TILES = [
    # Row  4: border top
    [0x44, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x48, 0x49],
    # Row  5: "SUPER" top row + fill
    [0x46, 0xD0, 0xD1, 0xD8, 0xD8, 0xDE, 0xD1, 0xD0, 0xDA, 0xDE, 0xD1, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x4A],
    # Row  6
    [0x46, 0xD2, 0xD3, 0xDB, 0xDB, 0xDB, 0xD9, 0xDB, 0xDC, 0xDB, 0xDF, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x4A],
    # Row  7
    [0x46, 0xD4, 0xD5, 0xD4, 0xD9, 0xDB, 0xE2, 0xD4, 0xDA, 0xDB, 0xE0, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x4A],
    # Row  8: "SUPER" bottom row
    [0x46, 0xD6, 0xD7, 0xD6, 0xD7, 0xE1, 0x26, 0xD6, 0xDD, 0xE1, 0xE1, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x26, 0x4A],
    # Row  9: "MARIO BROS." top row
    [0x46, 0xD0, 0xE8, 0xD1, 0xD0, 0xD1, 0xDE, 0xD1, 0xD8, 0xD0, 0xD1, 0x26, 0xDE, 0xD1, 0xDE, 0xD1, 0xD0, 0xD1, 0xD0, 0xD1, 0x26, 0x4A],
    # Row 10
    [0x46, 0xDB, 0x42, 0x42, 0xDB, 0x42, 0xDB, 0x42, 0xDB, 0xDB, 0x42, 0x26, 0xDB, 0x42, 0xDB, 0x42, 0xDB, 0x42, 0xDB, 0x42, 0x26, 0x4A],
    # Row 11
    [0x46, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0xDF, 0xDB, 0xDB, 0xDB, 0x26, 0xDB, 0xDF, 0xDB, 0xDF, 0xDB, 0xDB, 0xE4, 0xE5, 0x26, 0x4A],
    # Row 12
    [0x46, 0xDB, 0xDB, 0xDB, 0xDE, 0x43, 0xDB, 0xE0, 0xDB, 0xDB, 0xDB, 0x26, 0xDB, 0xE3, 0xDB, 0xE0, 0xDB, 0xDB, 0xE6, 0xE3, 0x26, 0x4A],
    # Row 13: "MARIO BROS." bottom row
    [0x46, 0xDB, 0xDB, 0xDB, 0xDB, 0x42, 0xDB, 0xDB, 0xDB, 0xD4, 0xD9, 0x26, 0xDB, 0xD9, 0xDB, 0xDB, 0xD4, 0xD9, 0xD4, 0xD9, 0xE7, 0x4A],
    # Row 14: decorative ground line
    [0x5F, 0x95, 0x95, 0x95, 0x95, 0x95, 0x95, 0x95, 0x95, 0x97, 0x98, 0x78, 0x95, 0x96, 0x95, 0x95, 0x97, 0x98, 0x97, 0x98, 0x95, 0x7A],
]

# 4-color grayscale palette (matches extract_chr.py)
PALETTE = [
    (0, 0, 0),         # Index 0: black
    (85, 85, 85),      # Index 1: dark gray
    (170, 170, 170),   # Index 2: light gray
    (255, 255, 255),   # Index 3: white
]


def load_chr_rom():
    """Load NES CHR-ROM data from ROM file."""
    with open(ROM_PATH, 'rb') as f:
        f.seek(CHR_OFFSET)
        return f.read(8192)


def decode_tile_8x8(chr_data, tile_index):
    """Decode a NES 2bpp planar tile (Pattern Table 1) into 8x8 pixel indices."""
    rom_tile = 256 + tile_index  # BG tiles are in Pattern Table 1
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


def make_palette_image(width, height):
    """Create a blank indexed-color image with our 4-color palette."""
    img = Image.new('P', (width, height))
    pal = []
    for r, g, b in PALETTE:
        pal.extend([r, g, b])
    pal.extend([0, 0, 0] * (256 - len(PALETTE)))
    img.putpalette(pal)
    return img


def main():
    parser = argparse.ArgumentParser(description="Build pre-composited title logo sprite")
    parser.add_argument('--tile-width', type=int, default=5, help='Tile width (default: 5)')
    parser.add_argument('--tile-height', type=int, default=4, help='Tile height (default: 4)')
    args = parser.parse_args()

    tile_h = args.tile_height

    os.makedirs(LOGO_DIR, exist_ok=True)
    os.makedirs("build", exist_ok=True)

    print(f"Loading CHR-ROM from {ROM_PATH}...")
    chr_data = load_chr_rom()

    # Composite all tiles at full 8x8 resolution into 176x88 image
    width = LOGO_COLS * 8   # 176
    height = LOGO_ROWS * 8  # 88
    full_img = make_palette_image(width, height)

    for row_idx, row_tiles in enumerate(LOGO_TILES):
        for col_idx, tile_idx in enumerate(row_tiles):
            if tile_idx == 0x24:
                continue  # blank tile, leave as pen 0

            pixels = decode_tile_8x8(chr_data, tile_idx)
            x_off = col_idx * 8
            y_off = row_idx * 8
            for y in range(8):
                for x in range(8):
                    full_img.putpixel((x_off + x, y_off + y), pixels[y][x])

    # Save unscaled composite
    unscaled_path = os.path.join(LOGO_DIR, "logo_unscaled.pcx")
    full_img.save(unscaled_path, format='PCX')
    print(f"Saved unscaled logo: {unscaled_path} ({width}x{height})")

    # Downscale to Lynx size: 5/8 X, tile_h/8 Y via area-based sampling
    lynx_w = width * 5 // 8   # 110
    lynx_h = height * tile_h // 8  # 44 for h=4, 55 for h=5

    # Extract pixel array for area downsampling
    src_pixels = []
    for y in range(height):
        row = []
        for x in range(width):
            row.append(full_img.getpixel((x, y)))
        src_pixels.append(row)

    scaled = area_downsample(src_pixels, width, height, lynx_w, lynx_h)

    scaled_img = make_palette_image(lynx_w, lynx_h)
    for y in range(lynx_h):
        for x in range(lynx_w):
            scaled_img.putpixel((x, y), scaled[y][x])

    scaled_path = os.path.join(LOGO_DIR, "logo_scaled.pcx")
    scaled_img.save(scaled_path, format='PCX')
    print(f"Saved scaled logo: {scaled_path} ({lynx_w}x{lynx_h})")

    # Convert to packed Lynx sprite via sp65
    ax = lynx_w // 2
    ay = lynx_h // 2
    result = subprocess.run(
        [SP65, "--read", scaled_path,
         "--convert-to", f"lynx-sprite,mode=packed,ax={ax},ay={ay},bpp=2",
         "--write", OUTPUT_BIN],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        print(f"sp65 failed: {result.stderr}")
        # Try literal as fallback
        print("Trying literal mode as fallback...")
        result = subprocess.run(
            [SP65, "--read", scaled_path,
             "--convert-to", f"lynx-sprite,mode=literal,ax={ax},ay={ay},bpp=2",
             "--write", OUTPUT_BIN],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"sp65 literal also failed: {result.stderr}")
            sys.exit(1)
        print("WARNING: Using literal mode (packed not supported)")

    # Report size
    size = os.path.getsize(OUTPUT_BIN)
    print(f"Logo sprite: {OUTPUT_BIN} ({size} bytes)")
    print(f"  vs 256 individual tiles at 16 bytes each = 4,096 bytes")
    print(f"  vs literal 110x55 estimate = ~1,596 bytes")


if __name__ == "__main__":
    main()
