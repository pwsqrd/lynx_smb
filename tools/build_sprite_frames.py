#!/usr/bin/env python3
"""Build pre-composited sprite frames for player and enemy objects.

Parses PlayerGraphicsTable (26 frames x 8 tiles) and EnemyGraphicsTable
(44 frames x 6 tiles) from smb_lynx.s. Composites multi-tile character
sprites into single larger sprites at full NES resolution, downscales to
Lynx resolution, and converts via sp65 to packed 2bpp Lynx sprites.

Also identifies sprite tile IDs NOT used in any composite frame and builds
a dense misc tile subset for non-composite sprites (fireballs, coins, etc.).

Output:
  character_data/sprite_frames/player_NN.pcx   - verification PCXes
  character_data/sprite_frames/enemy_NN.pcx    - verification PCXes
  build/sprite_frames.bin          - concatenated packed sprites (variable size)
  build/sprite_frame_index.bin     - 70 entries x 4 bytes: [off_lo, off_hi, height_px, y_trim_px]
  build/enemy_frame_offset_lut.bin - 256-byte lookup: raw offset -> dense frame index
  build/misc_sprite_tiles.bin      - dense tile blob for non-composite sprites
  build/misc_sprite_index.bin      - 256-byte lookup: tile ID -> dense index ($FF=missing)
"""

import argparse
import os
import re
import struct
import subprocess
import sys
from PIL import Image

from area_downsample import area_downsample

# Paths
SMB_SRC = "lynx_port/smb_lynx.s"
ROM_PATH = "rom/SuperMarioBros.nes"
SP65 = os.environ.get("SP65", "sp65")
FRAME_DIR = "character_data/sprite_frames"
FRAME_UNSCALED_DIR = "character_data/sprite_frames/unscaled"
OUTPUT_FRAMES = "build/sprite_frames.bin"
OUTPUT_FRAME_INDEX = "build/sprite_frame_index.bin"
OUTPUT_ENEMY_LUT = "build/enemy_frame_offset_lut.bin"
OUTPUT_MISC_TILES = "build/misc_sprite_tiles.bin"
OUTPUT_MISC_INDEX = "build/misc_sprite_index.bin"
TEMP_DIR = "build/sprite_frames_tmp"

# NES CHR-ROM layout
CHR_OFFSET = 0x8010  # 16-byte iNES header + 32KB PRG-ROM
TILE_BYTES = 16       # 16 bytes per NES tile (2bpp planar)

# Player: 26 frames x 8 tile IDs (2 cols x 4 rows)
PLAYER_FRAME_COUNT = 26
PLAYER_TILES_PER_FRAME = 8

# Enemy: 43 frames x 6 tile IDs (2 cols x 3 rows)
ENEMY_FRAME_COUNT = 43
ENEMY_TILES_PER_FRAME = 6

BLANK_TILE = 0xFC

# 4-color grayscale palette (matches extract_chr.py)
PALETTE = [
    (0, 0, 0),
    (85, 85, 85),
    (170, 170, 170),
    (255, 255, 255),
]


def load_chr_rom():
    """Load NES CHR-ROM data from ROM file."""
    with open(ROM_PATH, 'rb') as f:
        f.seek(CHR_OFFSET)
        return f.read(8192)


def decode_sprite_tile_8x8(chr_data, tile_index):
    """Decode a sprite tile (Pattern Table 0) into 8x8 pixel indices (0-3)."""
    offset = tile_index * TILE_BYTES  # Pattern Table 0 = tiles 0-255
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


def parse_graphics_table(src_path, label, count, tiles_per_frame):
    """Parse a graphics table from assembly source.

    Returns list of frames, where each frame is a list of tile IDs.
    Layout: column-major order (left col top-to-bottom, then right col).
    Player: 8 tiles = 2 cols x 4 rows: [TL, ML1, ML2, BL, TR, MR1, MR2, BR]
    Enemy:  6 tiles = 2 cols x 3 rows: [TL, ML, BL, TR, MR, BR]
    """
    with open(src_path, 'r') as f:
        lines = f.readlines()

    # Find the label
    label_line = None
    for i, line in enumerate(lines):
        if re.match(rf'^{label}\s*:', line):
            label_line = i
            break

    if label_line is None:
        print(f"Error: Could not find label '{label}' in {src_path}")
        sys.exit(1)

    frames = []
    line_idx = label_line + 1
    while len(frames) < count and line_idx < len(lines):
        line = lines[line_idx].strip()
        line_idx += 1

        if not line or line.startswith(';'):
            continue

        m = re.match(r'\.byte\s+(.+)', line)
        if not m:
            # Hit a new label or directive - stop
            if re.match(r'\w+:', line) or line.startswith('.'):
                break
            continue

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

        if len(vals) == tiles_per_frame:
            frames.append(vals)
        elif len(vals) > tiles_per_frame:
            # Multiple frames on one line (unlikely but handle)
            for i in range(0, len(vals), tiles_per_frame):
                chunk = vals[i:i+tiles_per_frame]
                if len(chunk) == tiles_per_frame:
                    frames.append(chunk)

    if len(frames) < count:
        print(f"Warning: Only found {len(frames)}/{count} frames for {label}")

    return frames


def hflip_tile(pixels):
    """Horizontally flip an 8x8 tile (list of rows of pixel values)."""
    return [row[::-1] for row in pixels]


def vflip_tile(pixels):
    """Vertically flip an 8x8 tile (list of rows of pixel values)."""
    return pixels[::-1]


def hvflip_tile(pixels):
    """Horizontally and vertically flip an 8x8 tile."""
    return [row[::-1] for row in pixels[::-1]]


# Player frame offsets (PlayerGfxOffset values) that get per-tile H-flip
# applied by ChkForPlayerAttrib in the NES game code.
# C_S_IGAtt: row 3 right tile gets HFLIP (crouch, standing, intermediate grow)
# KilledAtt: rows 2+3 right tiles get HFLIP (killed state)
PLAYER_FLIP_ROW3_RIGHT = {
    0x50,   # crouching
    0xB8,   # small standing (shared)
    0xC0,   # intermediate grow (shared)
    0xC8,   # big standing (shared)
}
PLAYER_FLIP_ROWS23_RIGHT = {
    0xB0,   # killed (small)
}

# Enemy frame mirroring applied by MirrorEnemyGfx / CheckToMirrorJSpring
# in the NES game code (post-DrawSpriteObject attribute overrides).
#
# MIRROR_RIGHT_HFLIP: all right-column tiles get HFLIP
#   Applied by MirrorEnemyGfx for bloober, piranha, podoboo, spiny (non-egg),
#   shells (koopa/buzzy, both orientations), defeated goomba
#
# MIRROR_RIGHT_HVFLIP: all right-column tiles get H+V flip (spiny egg)
#
# JUMPSPRING_MIRROR: rows 1-2 left get VFLIP, rows 1-2 right get H+V flip
#
# LAKITU_MIRROR: row 2 right gets HFLIP (lakitu frame 1)
# LAKITU_ALT_MIRROR: rows 1-2 right get HFLIP, rows 1-2 left normal (lakitu frame 2)
#
# RETAINER_MIRROR: row 2 right gets HFLIP (mushroom retainer)

# Enemy frame mirroring categories based on $ec (alternate enemy state)
# value when MirrorEnemyGfx is reached:
#
# Basic mirror ($ec=2 or 3): right column HFLIP only
# Note: spiny frames 6-7 are NOT mirrored (CheckForSpiny jumps past MirrorEnemyGfx)
ENEMY_MIRROR_BASIC = {
    10, 11,         # bloober
    15, 16,         # koopa shell upside-down
    21, 22,         # buzzy beetle shell upside-down
    32, 33,         # piranha plant
    34,             # podoboo
}

# Enhanced mirror ($ec=4): right col HFLIP, rows 1-2 left VFLIP, rows 1-2 right H+V
# This applies to right-side-up shells and defeated goomba
ENEMY_MIRROR_EC4 = {
    17, 18,         # koopa shell right-side-up
    19, 20,         # buzzy beetle shell right-side-up
    23,             # defeated goomba
}

# Spiny egg ($ec=5): right column H+V flip
ENEMY_MIRROR_RIGHT_HVFLIP = {
    8, 9,           # spiny egg
}

# Jumpspring: rows 1-2 left=VFLIP, rows 1-2 right=H+VFLIP, row 0 unchanged
ENEMY_JUMPSPRING = {
    40, 41, 42,     # jumpspring frames 1-3
}

# Lakitu: row 2 right gets HFLIP (feet mirror)
ENEMY_LAKITU = {24, 25}

# Princess: row 2 right gets HFLIP only
ENEMY_PRINCESS = {26}

# Mushroom retainer ($ec=3): all right-column HFLIP via MirrorEnemyGfx
ENEMY_RETAINER = {27}


def composite_player_frame(chr_data, tile_ids, frame_offset=None):
    """Composite a player frame (2 cols x 4 rows) at full NES resolution.

    Layout is ROW-MAJOR: tile_ids = [R0L, R0R, R1L, R1R, R2L, R2R, R3L, R3R]
    DrawPlayerLoop loads [x] as left, [x+1] as right per row.

    Returns (full_image, trimmed_image, trim_rows_top, height_px).
    trim_rows_top = number of blank 8px tile rows trimmed from top.
    """
    # Full frame: 16x32 (2 tiles wide, 4 tiles tall)
    full = make_palette_image(16, 32)

    # Row-major positions: pairs of (left, right) per row
    positions = [
        (0, 0),  (8, 0),    # Row 0: left, right
        (0, 8),  (8, 8),    # Row 1: left, right
        (0, 16), (8, 16),   # Row 2: left, right
        (0, 24), (8, 24),   # Row 3: left, right
    ]

    # Determine which tiles need per-tile H-flip (symmetry effect)
    flip_right = set()
    if frame_offset is not None:
        if frame_offset in PLAYER_FLIP_ROW3_RIGHT:
            flip_right.add(3)  # row 3 right tile
        if frame_offset in PLAYER_FLIP_ROWS23_RIGHT:
            flip_right.add(2)  # row 2 right tile
            flip_right.add(3)  # row 3 right tile

    for idx, (x_off, y_off) in enumerate(positions):
        tile_id = tile_ids[idx]
        if tile_id == BLANK_TILE:
            continue
        pixels = decode_sprite_tile_8x8(chr_data, tile_id)

        # Check if this is a right tile that needs H-flip
        row = idx // 2
        is_right = (idx % 2) == 1
        if is_right and row in flip_right:
            pixels = hflip_tile(pixels)

        for y in range(8):
            for x in range(8):
                full.putpixel((x_off + x, y_off + y), pixels[y][x])

    # Determine trim: count blank rows from top (row-major pairs)
    trim_rows = 0
    for row_idx in range(4):
        left_tile = tile_ids[row_idx * 2]
        right_tile = tile_ids[row_idx * 2 + 1]
        if left_tile == BLANK_TILE and right_tile == BLANK_TILE:
            trim_rows += 1
        else:
            break

    # Trim from top (in 8px tile rows)
    trim_px = trim_rows * 8
    remaining_h = 32 - trim_px

    if remaining_h <= 0:
        # All blank - return minimal image
        trimmed = make_palette_image(16, 8)
        return full, trimmed, 4, 8

    trimmed = full.crop((0, trim_px, 16, 32))
    return full, trimmed, trim_rows, remaining_h


def composite_enemy_frame(chr_data, tile_ids, frame_index=None):
    """Composite an enemy frame (2 cols x 3 rows) at full NES resolution.

    Layout is ROW-MAJOR: tile_ids = [R0L, R0R, R1L, R1R, R2L, R2R]
    Comment in disassembly: "top left, right, middle left, right, bottom left, right"

    Returns (full_image, trimmed_image, trim_rows_top, height_px).
    """
    full = make_palette_image(16, 24)

    # Row-major positions: pairs of (left, right) per row
    positions = [
        (0, 0),  (8, 0),    # Row 0: left, right
        (0, 8),  (8, 8),    # Row 1: left, right
        (0, 16), (8, 16),   # Row 2: left, right
    ]

    # Determine per-tile flip transforms based on frame index
    # Returns a function to apply to pixels, or None for no transform
    def get_tile_transform(idx):
        """Get pixel transform for tile at position idx (0-5)."""
        if frame_index is None:
            return None
        row = idx // 2
        is_right = (idx % 2) == 1

        if frame_index in ENEMY_MIRROR_BASIC:
            # Right column HFLIP only (all rows)
            if is_right:
                return hflip_tile
        elif frame_index in ENEMY_MIRROR_EC4:
            # $ec=4: right col HFLIP, rows 1-2 left VFLIP, rows 1-2 right H+V
            if row == 0:
                if is_right:
                    return hflip_tile
            else:  # rows 1-2
                if is_right:
                    return hvflip_tile
                else:
                    return vflip_tile
        elif frame_index in ENEMY_MIRROR_RIGHT_HVFLIP:
            # Spiny egg: right column H+V flip
            if is_right:
                return hvflip_tile
        elif frame_index in ENEMY_JUMPSPRING:
            # Rows 1-2: left=VFLIP, right=H+V; row 0 unchanged
            if row >= 1:
                if is_right:
                    return hvflip_tile
                else:
                    return vflip_tile
        elif frame_index in ENEMY_LAKITU:
            # Row 2 right: HFLIP (feet mirror)
            if row == 2 and is_right:
                return hflip_tile
        elif frame_index in ENEMY_PRINCESS:
            # Row 2 right: HFLIP only
            if row == 2 and is_right:
                return hflip_tile
        elif frame_index in ENEMY_RETAINER:
            # All right-column HFLIP
            if is_right:
                return hflip_tile
        return None

    for idx, (x_off, y_off) in enumerate(positions):
        tile_id = tile_ids[idx]
        if tile_id == BLANK_TILE:
            continue
        pixels = decode_sprite_tile_8x8(chr_data, tile_id)

        transform = get_tile_transform(idx)
        if transform is not None:
            pixels = transform(pixels)

        for y in range(8):
            for x in range(8):
                full.putpixel((x_off + x, y_off + y), pixels[y][x])

    # Determine trim from top (row-major pairs)
    trim_rows = 0
    for row_idx in range(3):
        left_tile = tile_ids[row_idx * 2]
        right_tile = tile_ids[row_idx * 2 + 1]
        if left_tile == BLANK_TILE and right_tile == BLANK_TILE:
            trim_rows += 1
        else:
            break

    trim_px = trim_rows * 8
    remaining_h = 24 - trim_px

    if remaining_h <= 0:
        trimmed = make_palette_image(16, 8)
        return full, trimmed, 3, 8

    trimmed = full.crop((0, trim_px, 16, 24))
    return full, trimmed, trim_rows, remaining_h


def downscale_frame(img, tile_h=4):
    """Downscale NES-resolution image to Lynx resolution (5/8 X, tile_h/8 Y)."""
    w, h = img.size
    lynx_w = w * 5 // 8
    lynx_h = h * tile_h // 8
    if lynx_w < 1:
        lynx_w = 1
    if lynx_h < 1:
        lynx_h = 1

    # Extract pixel array for area downsampling
    src_pixels = []
    for y in range(h):
        row = []
        for x in range(w):
            row.append(img.getpixel((x, y)))
        src_pixels.append(row)

    scaled = area_downsample(src_pixels, w, h, lynx_w, lynx_h)

    result = make_palette_image(lynx_w, lynx_h)
    for y in range(lynx_h):
        for x in range(lynx_w):
            result.putpixel((x, y), scaled[y][x])
    return result


def convert_to_packed_sprite(pcx_path, bin_path):
    """Convert PCX to packed Lynx sprite binary via sp65."""
    result = subprocess.run(
        [SP65, "--read", pcx_path,
         "--convert-to", "lynx-sprite,mode=packed,ax=0,ay=0,bpp=2",
         "--write", bin_path],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        # Try literal as fallback
        result = subprocess.run(
            [SP65, "--read", pcx_path,
             "--convert-to", "lynx-sprite,mode=literal,ax=0,ay=0,bpp=2",
             "--write", bin_path],
            capture_output=True, text=True
        )
    return result.returncode == 0


def convert_to_literal_sprite(pcx_path, bin_path):
    """Convert PCX to literal Lynx sprite binary via sp65."""
    result = subprocess.run(
        [SP65, "--read", pcx_path,
         "--convert-to", "lynx-sprite,mode=literal,ax=0,ay=0,bpp=2",
         "--write", bin_path],
        capture_output=True, text=True
    )
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description="Build pre-composited sprite frames")
    parser.add_argument('--tile-width', type=int, default=5, help='Tile width (default: 5)')
    parser.add_argument('--tile-height', type=int, default=4, help='Tile height (default: 4)')
    args = parser.parse_args()

    tile_w = args.tile_width
    tile_h = args.tile_height
    TILE_SPRITE_SIZE = tile_h * 3 + 1  # 13 for h=4, 16 for h=5

    os.makedirs(FRAME_DIR, exist_ok=True)
    os.makedirs(FRAME_UNSCALED_DIR, exist_ok=True)
    os.makedirs(TEMP_DIR, exist_ok=True)
    os.makedirs("build", exist_ok=True)

    print(f"Loading CHR-ROM from {ROM_PATH}...")
    chr_data = load_chr_rom()

    print(f"Parsing graphics tables from {SMB_SRC}...")
    player_frames = parse_graphics_table(SMB_SRC, "PlayerGraphicsTable",
                                          PLAYER_FRAME_COUNT, PLAYER_TILES_PER_FRAME)
    enemy_frames = parse_graphics_table(SMB_SRC, "EnemyGraphicsTable",
                                         ENEMY_FRAME_COUNT, ENEMY_TILES_PER_FRAME)
    print(f"  Player: {len(player_frames)} frames")
    print(f"  Enemy: {len(enemy_frames)} frames")

    # Track tile IDs used in enemy composite frames only.
    # Player tiles are NOT excluded from misc - players use tile-by-tile OAM.
    composite_tile_ids = set()

    # =========================================================================
    # Build composite sprite frames (enemies only - players use tile-by-tile OAM)
    # =========================================================================
    all_frame_data = []  # list of (literal_bytes, lynx_height_px, y_trim_lynx_px)

    print(f"Compositing enemy frames...")
    for i, tile_ids in enumerate(enemy_frames):
        for tid in tile_ids:
            if tid != BLANK_TILE:
                composite_tile_ids.add(tid)

        full, trimmed, trim_rows, height_px = composite_enemy_frame(chr_data, tile_ids, frame_index=i)
        scaled = downscale_frame(trimmed, tile_h=tile_h)

        pcx_path = os.path.join(FRAME_DIR, f"enemy_{i:02d}.pcx")
        scaled.save(pcx_path, format='PCX')
        unscaled_path = os.path.join(FRAME_UNSCALED_DIR, f"enemy_{i:02d}.pcx")
        trimmed.save(unscaled_path, format='PCX')

        bin_path = os.path.join(TEMP_DIR, f"enemy_{i:02d}.bin")
        if convert_to_literal_sprite(pcx_path, bin_path):
            with open(bin_path, 'rb') as f:
                data = f.read()

            lynx_h = scaled.size[1]
            y_trim_lynx = trim_rows * tile_h
            all_frame_data.append((data, lynx_h, y_trim_lynx))
        else:
            print(f"  FAILED: enemy_{i:02d}")
            all_frame_data.append((b'\x00', 1, 0))

    total_frames = len(all_frame_data)
    print(f"\nTotal composite frames: {total_frames} (enemy only, players use tile-by-tile)")

    # =========================================================================
    # Write sprite_frames.bin - concatenated packed sprite data
    # =========================================================================
    offsets = []
    current_offset = 0
    with open(OUTPUT_FRAMES, 'wb') as f:
        for data, lynx_h, y_trim in all_frame_data:
            offsets.append((current_offset, lynx_h, y_trim))
            f.write(data)
            current_offset += len(data)

    frames_size = current_offset
    print(f"Sprite frames blob: {OUTPUT_FRAMES} ({frames_size} bytes)")

    # =========================================================================
    # Write sprite_frame_index.bin - 70 entries x 4 bytes each
    # [offset_lo, offset_hi, height_px, y_trim_px]
    # =========================================================================
    with open(OUTPUT_FRAME_INDEX, 'wb') as f:
        for offset, lynx_h, y_trim in offsets:
            f.write(struct.pack('BBB B', offset & 0xFF, (offset >> 8) & 0xFF,
                                lynx_h, y_trim))
    index_size = total_frames * 4
    print(f"Frame index: {OUTPUT_FRAME_INDEX} ({index_size} bytes, {total_frames} entries)")

    # =========================================================================
    # Write enemy_frame_offset_lut.bin
    # Maps raw EnemyGraphicsTable offset (X register value) to dense enemy
    # frame index. Raw offsets are 0, 6, 12, 18, ... (i*6).
    # Dense enemy frame index = player_count + enemy_index.
    # $FF = unused offset.
    # =========================================================================
    enemy_lut = [0xFF] * 256
    for i in range(len(enemy_frames)):
        raw_offset = i * ENEMY_TILES_PER_FRAME
        if raw_offset < 256:
            enemy_lut[raw_offset] = i  # direct frame index (enemies only)
    with open(OUTPUT_ENEMY_LUT, 'wb') as f:
        f.write(bytes(enemy_lut))
    print(f"Enemy frame offset LUT: {OUTPUT_ENEMY_LUT} (256 bytes)")

    # =========================================================================
    # Build misc sprite tile subset
    # Find all sprite tiles (Pattern Table 0, indices 0-255) that are NOT
    # part of any composite frame
    # =========================================================================
    print(f"\nComposite uses {len(composite_tile_ids)} unique sprite tile IDs")

    # Find non-composite tile IDs actually used in the game
    # We include ALL tiles 0-255 that aren't in composites, since various
    # game objects (fireballs, coins, powerups, etc.) reference them via OAM
    misc_tile_ids = sorted(set(range(256)) - composite_tile_ids - {BLANK_TILE})
    print(f"Misc sprite tiles (non-composite): {len(misc_tile_ids)} tiles")

    # Convert each misc tile to literal Lynx sprite
    misc_dense_data = []
    misc_index = [0xFF] * 256

    misc_dir = os.path.join(FRAME_DIR, "misc")
    misc_unscaled_dir = os.path.join(FRAME_UNSCALED_DIR, "misc")
    os.makedirs(misc_dir, exist_ok=True)
    os.makedirs(misc_unscaled_dir, exist_ok=True)

    for tile_id in misc_tile_ids:
        pixels = decode_sprite_tile_8x8(chr_data, tile_id)

        # Create 8x8 indexed PCX
        img = make_palette_image(8, 8)
        for y in range(8):
            for x in range(8):
                img.putpixel((x, y), pixels[y][x])

        # Save unscaled verification PCX
        img.save(os.path.join(misc_unscaled_dir, f"tile_{tile_id:02X}.pcx"), format='PCX')

        # Area-based downsample to tile_w x tile_h
        src_pixels = []
        for y in range(8):
            row = []
            for x in range(8):
                row.append(img.getpixel((x, y)))
            src_pixels.append(row)

        scaled = area_downsample(src_pixels, 8, 8, tile_w, tile_h)

        img = make_palette_image(tile_w, tile_h)
        for y in range(tile_h):
            for x in range(tile_w):
                img.putpixel((x, y), scaled[y][x])

        # Save scaled verification PCX
        img.save(os.path.join(misc_dir, f"tile_{tile_id:02X}.pcx"), format='PCX')

        pcx_path = os.path.join(TEMP_DIR, f"misc_{tile_id:02X}.pcx")
        img.save(pcx_path, format='PCX')

        bin_path = os.path.join(TEMP_DIR, f"misc_{tile_id:02X}.bin")
        if convert_to_literal_sprite(pcx_path, bin_path):
            with open(bin_path, 'rb') as f:
                data = f.read()

            if len(data) != TILE_SPRITE_SIZE:
                data = data[:TILE_SPRITE_SIZE].ljust(TILE_SPRITE_SIZE, b'\x00')

            dense_idx = len(misc_dense_data)
            misc_dense_data.append(data)
            misc_index[tile_id] = dense_idx
        else:
            print(f"  FAILED misc tile ${tile_id:02X}")

    # Write misc tile blob
    with open(OUTPUT_MISC_TILES, 'wb') as f:
        for data in misc_dense_data:
            f.write(data)
    misc_blob_size = len(misc_dense_data) * TILE_SPRITE_SIZE

    # Write misc tile index
    with open(OUTPUT_MISC_INDEX, 'wb') as f:
        f.write(bytes(misc_index))

    misc_total = misc_blob_size + 256
    print(f"Misc tile blob: {OUTPUT_MISC_TILES} ({misc_blob_size} bytes, {len(misc_dense_data)} tiles)")
    print(f"Misc tile index: {OUTPUT_MISC_INDEX} (256 bytes)")

    # =========================================================================
    # Summary
    # =========================================================================
    total_new = frames_size + index_size + 256 + misc_total  # frames + frame_index + enemy_lut + misc
    old_size = 4096  # SpriteTileData (256 tiles x 16 bytes)
    print(f"\n--- Memory Budget ---")
    print(f"  Old SpriteTileData:  {old_size} bytes")
    print(f"  New composite data:  {frames_size} bytes (literal frames)")
    print(f"  New frame index:     {index_size} bytes ({total_frames} x 4)")
    print(f"  Enemy offset LUT:    256 bytes")
    print(f"  Misc tile blob:      {misc_blob_size} bytes ({len(misc_dense_data)} tiles)")
    print(f"  Misc tile index:     256 bytes")
    print(f"  Total new:           {total_new} bytes")
    print(f"  Delta:               {total_new - old_size:+d} bytes")

    # List composite tile IDs for reference
    print(f"\nComposite tile IDs ({len(composite_tile_ids)}): ", end="")
    print(", ".join(f"${t:02X}" for t in sorted(composite_tile_ids)))


if __name__ == "__main__":
    main()
