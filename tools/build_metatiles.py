#!/usr/bin/env python3
"""Build pre-composited metatile sprites for the Lynx port.

Parses MetatileGraphics tables from smb_lynx.s, composites each metatile's
4 sub-tiles at full NES resolution (8x8 → 16x16), then downscales to 10x8
for the Lynx display (5/8 X, 4/8 Y). This produces better results than
compositing already-downscaled tiles.

Output:
  character_data/metatiles/meta_XX.pcx  - verification PCXes (10x8)
  build/metatile_tiles.bin              - dense blob (only defined metatiles)
  build/metatile_index.bin              - 256-byte lookup (metatile byte → dense index, $FF=blank)
"""

import argparse
import os
import re
import subprocess
import sys
from PIL import Image

from area_downsample import area_downsample, outline_aware_downsample, skeleton_projection_downsample

# Paths
SMB_SRC = "lynx_port/smb_lynx.s"
ROM_PATH = "rom/SuperMarioBros.nes"
META_DIR = "character_data/metatiles"
SP65 = os.environ.get("SP65", "sp65")
OUTPUT_BLOB = "build/metatile_tiles.bin"

# NES CHR-ROM layout
CHR_OFFSET = 0x8010  # 16-byte iNES header + 32KB PRG-ROM
TILE_BYTES = 16       # 16 bytes per NES tile (2bpp planar)

# 4-color grayscale palette (matches extract_chr.py)
PALETTE = [
    (0, 0, 0),         # Index 0: black
    (85, 85, 85),      # Index 1: dark gray
    (170, 170, 170),   # Index 2: light gray
    (255, 255, 255),   # Index 3: white
]

# Metatile table ranges (palette_index, label, start_id, count)
METATILE_TABLES = [
    (0, "Palette0_MTiles", 0x00, 39),
    (1, "Palette1_MTiles", 0x40, 46),
    (2, "Palette2_MTiles", 0x80, 10),
    (3, "Palette3_MTiles", 0xC0, 6),
]


def parse_metatile_tables(src_path):
    """Parse metatile graphics from smb_lynx.s assembly source.

    Returns dict: metatile_id -> (tl, bl, tr, br) tile indices.
    Table entries are column-major: TL, BL, TR, BR.
    """
    with open(src_path, 'r') as f:
        lines = f.readlines()

    metatiles = {}

    for _pal_idx, label, start_id, count in METATILE_TABLES:
        # Find the label line
        label_line = None
        for i, line in enumerate(lines):
            if re.match(rf'^{label}\s*:', line):
                label_line = i
                break

        if label_line is None:
            print(f"Error: Could not find label '{label}' in {src_path}")
            sys.exit(1)

        # Parse 'count' entries (each is a .byte line with 4 values)
        entry_idx = 0
        line_idx = label_line + 1
        while entry_idx < count and line_idx < len(lines):
            line = lines[line_idx].strip()
            line_idx += 1

            # Skip empty lines and comments
            if not line or line.startswith(';'):
                continue

            # Match .byte lines
            m = re.match(r'\.byte\s+(.+)', line)
            if not m:
                continue

            # Parse hex/decimal values (strip comments)
            vals_str = m.group(1).split(';')[0].strip()
            vals = []
            for v in vals_str.split(','):
                v = v.strip()
                if v.startswith('$'):
                    vals.append(int(v[1:], 16))
                elif v.startswith('%'):
                    vals.append(int(v[1:], 2))
                else:
                    vals.append(int(v))

            if len(vals) != 4:
                print(f"Warning: Expected 4 values, got {len(vals)} at line {line_idx}: {line}")
                continue

            metatile_id = start_id + entry_idx
            tl, bl, tr, br = vals  # column-major order
            metatiles[metatile_id] = (tl, bl, tr, br)
            entry_idx += 1

        if entry_idx < count:
            print(f"Warning: Only found {entry_idx}/{count} entries for {label}")

    return metatiles


def load_chr_rom():
    """Load NES CHR-ROM data from ROM file."""
    with open(ROM_PATH, 'rb') as f:
        f.seek(CHR_OFFSET)
        return f.read(8192)  # 8KB CHR-ROM, 512 tiles


def decode_tile_8x8(chr_data, tile_index):
    """Decode a NES 2bpp planar tile into 8x8 pixel indices (0-3).

    Metatile sub-tile indices reference Pattern Table 1 (BG tiles),
    which is the second 4KB of CHR-ROM (tiles 256-511).
    """
    rom_tile = 256 + tile_index  # BG tiles are in Pattern Table 1
    offset = rom_tile * TILE_BYTES
    tile_data = chr_data[offset:offset + TILE_BYTES]

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


def make_palette_image(width, height):
    """Create a blank indexed-color image with our 4-color palette."""
    img = Image.new('P', (width, height))
    pal = []
    for r, g, b in PALETTE:
        pal.extend([r, g, b])
    pal.extend([0, 0, 0] * (256 - len(PALETTE)))
    img.putpalette(pal)
    return img


def get_downsample_method_5x5(meta_id):
    """Return the optimal downsampling method for a metatile in 5x5 mode.

    Based on visual comparison across all categories at 10x10 output size.
    """
    # Castle turret crenellations — skeleton projection for 1px edges
    if meta_id in (0x45, 0x49):
        return "skeleton"
    # Items (Palette 3) — PIL Nearest preserves strong shapes
    if meta_id >= 0xC0:
        return "nearest"
    # Water tiles — PIL Nearest for clean shapes
    if meta_id in (0x86, 0x87, 0x89):
        return "nearest"
    # Cloud terrain — nearest preserves circular outline best
    if meta_id == 0x88:
        return "nearest"
    # Bricks and brick variants — edge preservation for mortar lines
    if meta_id in range(0x51, 0x60) or meta_id in (0x17, 0x47):
        return "area_edge"
    # Structures — edge preservation for thin structural details
    if meta_id in (0x53, 0x55, 0x62, 0x64, 0x65, 0x66, 0x69):
        return "area_edge"
    # Everything else (hills, pipes, castle, scenery, clouds)
    return "area"


def pil_nearest_downsample(src_pixels, src_w, src_h, dst_w, dst_h):
    """Downsample using PIL NEAREST then snap back to 4-color indexed palette.

    Builds an RGB image from indexed source, resizes with NEAREST, then maps
    each pixel to the closest palette entry.
    """
    # Build RGB image from indexed pixels
    rgb_img = Image.new('RGB', (src_w, src_h))
    for y in range(src_h):
        for x in range(src_w):
            rgb_img.putpixel((x, y), PALETTE[src_pixels[y][x]])

    # Resize with nearest neighbor
    resized = rgb_img.resize((dst_w, dst_h), Image.NEAREST)

    # Snap each pixel back to nearest palette index
    result = []
    for y in range(dst_h):
        row = []
        for x in range(dst_w):
            r, g, b = resized.getpixel((x, y))
            # Find closest palette entry by squared distance
            best_idx = 0
            best_dist = float('inf')
            for i, (pr, pg, pb) in enumerate(PALETTE):
                d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
                if d < best_dist:
                    best_dist = d
                    best_idx = i
            row.append(best_idx)
        result.append(row)
    return result


def composite_metatile(chr_data, tl, bl, tr, br, tile_w=5, tile_h=4, method="area"):
    """Composite 4 sub-tiles at full 8x8 into 16x16, then downscale.

    Layout: TL at (0,0), TR at (8,0), BL at (0,8), BR at (8,8)
    Tile $24 = blank (fill with index 0)
    Downscale 16x16 → (2*tile_w)x(2*tile_h).

    method: downsampling algorithm to use:
        "area"      - area-based sampling (default)
        "area_edge" - area-based with edge preservation (threshold=0.12)
        "nearest"   - PIL nearest neighbor

    Returns (unscaled_16x16, scaled).
    """
    out_w = 2 * tile_w
    out_h = 2 * tile_h
    full = make_palette_image(16, 16)

    for tile_idx, x_off, y_off in [(tl, 0, 0), (tr, 8, 0), (bl, 0, 8), (br, 8, 8)]:
        if tile_idx == 0x24:
            continue  # blank tile, leave as pen 0

        pixels = decode_tile_8x8(chr_data, tile_idx)
        for y in range(8):
            for x in range(8):
                full.putpixel((x_off + x, y_off + y), pixels[y][x])

    # Extract source pixels for downsampling
    src_pixels = []
    for y in range(16):
        row = []
        for x in range(16):
            row.append(full.getpixel((x, y)))
        src_pixels.append(row)

    if method == "nearest":
        scaled = pil_nearest_downsample(src_pixels, 16, 16, out_w, out_h)
    elif method == "area_edge":
        scaled = area_downsample(src_pixels, 16, 16, out_w, out_h, edge_threshold=0.12)
    elif method == "outline_aware":
        scaled = outline_aware_downsample(src_pixels, 16, 16, out_w, out_h)
    elif method == "skeleton":
        scaled = skeleton_projection_downsample(src_pixels, 16, 16, out_w, out_h)
    else:  # "area"
        scaled = area_downsample(src_pixels, 16, 16, out_w, out_h, edge_threshold=None)

    result = make_palette_image(out_w, out_h)
    for y in range(out_h):
        for x in range(out_w):
            result.putpixel((x, y), scaled[y][x])

    return full, result


def convert_to_lynx_sprite(pcx_path, bin_path):
    """Convert PCX to Lynx sprite binary via sp65."""
    result = subprocess.run(
        [SP65, "--read", pcx_path,
         "--convert-to", "lynx-sprite,mode=literal,ax=0,ay=0,bpp=2",
         "--write", bin_path],
        capture_output=True, text=True
    )
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description="Build pre-composited metatile sprites")
    parser.add_argument('--tile-width', type=int, default=5, help='Tile width (default: 5)')
    parser.add_argument('--tile-height', type=int, default=4, help='Tile height (default: 4)')
    args = parser.parse_args()

    tile_w = args.tile_width
    tile_h = args.tile_height
    out_w = 2 * tile_w
    out_h = 2 * tile_h
    # sp65 literal 2bpp: per scanline = 1 byte offset + ceil(width*2/8) pixel bytes
    # For 10px wide: 20 bits = 3 bytes → 1+3=4 per line. Total = lines*4 + 1 terminator
    bytes_per_line = 1 + (out_w * 2 + 7) // 8  # offset byte + pixel data bytes
    METATILE_SIZE = out_h * bytes_per_line + 1  # + terminator byte

    unscaled_dir = os.path.join(META_DIR, "unscaled")
    os.makedirs(META_DIR, exist_ok=True)
    os.makedirs(unscaled_dir, exist_ok=True)
    os.makedirs("build", exist_ok=True)

    print(f"Parsing metatile tables from {SMB_SRC}...")
    metatiles = parse_metatile_tables(SMB_SRC)
    print(f"Found {len(metatiles)} metatile definitions")
    print(f"Metatile size: {out_w}x{out_h} ({METATILE_SIZE} bytes each)")

    print(f"Loading CHR-ROM from {ROM_PATH}...")
    chr_data = load_chr_rom()

    # Convert all defined metatiles and build dense blob + index table
    dense_data = []             # list of sprite binaries
    index_table = [0xFF] * 256  # 256-byte table: metatile byte → dense index ($FF=blank)
    converted = 0
    failed = 0

    for meta_id, (tl, bl, tr, br) in sorted(metatiles.items()):
        pcx_path = os.path.join(META_DIR, f"meta_{meta_id:02X}.pcx")
        unscaled_path = os.path.join(unscaled_dir, f"meta_{meta_id:02X}.pcx")
        bin_path = os.path.join(META_DIR, f"meta_{meta_id:02X}.bin")

        # Select downsampling method per tile category.
        # 5x5 mode: per-category optimal algorithms from visual comparison.
        # 5x4 mode: edge-aware for terrain (Palettes 0-2), plain area for items.
        if tile_h == 5:
            method = get_downsample_method_5x5(meta_id)
        else:
            if meta_id in (0x45, 0x49):
                method = "outline_aware"
            elif meta_id < 0xC0:
                method = "area_edge"
            else:
                method = "area"
        unscaled, img = composite_metatile(chr_data, tl, bl, tr, br,
                                           tile_w=tile_w, tile_h=tile_h,
                                           method=method)

        # Skip entirely blank metatiles (all pen 0) - leave index as $FF
        # so LynxRedrawBG skips them, preventing opaque blanks from erasing
        # sprites drawn in earlier passes (e.g. vine stems behind BG layer)
        all_blank = all(img.getpixel((x, y)) == 0
                        for y in range(out_h) for x in range(out_w))
        if all_blank:
            print(f"  meta_{meta_id:02X}: all blank, skipping (index=$FF)")
            continue

        img.save(pcx_path, format='PCX')
        unscaled.save(unscaled_path, format='PCX')

        # Convert to Lynx sprite
        if convert_to_lynx_sprite(pcx_path, bin_path):
            with open(bin_path, 'rb') as f:
                data = f.read()
            if len(data) != METATILE_SIZE:
                print(f"Warning: meta_{meta_id:02X} size {len(data)} != {METATILE_SIZE}")
                data = data[:METATILE_SIZE].ljust(METATILE_SIZE, b'\x00')
            dense_idx = len(dense_data)
            if dense_idx > 254:
                print(f"Error: too many metatiles (max 254 dense slots)")
                sys.exit(1)
            dense_data.append(data)
            index_table[meta_id] = dense_idx
            converted += 1
        else:
            print(f"FAILED: meta_{meta_id:02X}")
            failed += 1

    # Write dense blob
    with open(OUTPUT_BLOB, 'wb') as f:
        for data in dense_data:
            f.write(data)
    dense_size = len(dense_data) * METATILE_SIZE

    # Write index table
    index_path = OUTPUT_BLOB.replace("metatile_tiles.bin", "metatile_index.bin")
    with open(index_path, 'wb') as f:
        f.write(bytes(index_table))

    total_size = dense_size + 256
    print(f"\nConverted {converted} metatiles ({failed} failed)")
    print(f"Dense blob: {OUTPUT_BLOB} ({dense_size} bytes, {len(dense_data)} metatiles × {METATILE_SIZE})")
    print(f"Index table: {index_path} (256 bytes)")
    print(f"Total data: {total_size} bytes (vs {256 * METATILE_SIZE} for fixed-slot)")

    # Show some notable metatiles
    notable = {
        0x00: "blank",
        0x05: "mountain left",
        0x10: "warp pipe end left",
        0x17: "breakable brick w/ line",
        0x23: "blank (hit block)",
        0x47: "breakable brick",
        0x53: "solid block (3D)",
        0x80: "cloud left",
        0xC0: "question block (coin)",
        0xC2: "coin",
        0xC5: "axe",
    }
    print("\nNotable metatiles:")
    for mid, desc in sorted(notable.items()):
        idx = index_table[mid]
        status = f"index {idx}" if idx != 0xFF else "blank"
        print(f"  meta_{mid:02X} = {desc} ({status})")


if __name__ == "__main__":
    main()
