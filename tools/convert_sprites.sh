#!/bin/bash
# Convert all PCX tiles to Lynx sprite format using sp65
# Output: character_data/sprites/tile_NNN.bin (packed lynx-sprite data)

SP65="${SP65:-sp65}"
INDIR="character_data"
OUTDIR="character_data/sprites"

mkdir -p "$OUTDIR"

count=0
for pcx in "$INDIR"/tile_*.pcx; do
    base=$(basename "$pcx" .pcx)
    "$SP65" --read "$pcx" \
            --convert-to lynx-sprite,mode=literal,ax=0,ay=0,bpp=2 \
            --write "$OUTDIR/${base}.bin" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "FAILED: $pcx"
    else
        count=$((count + 1))
    fi
done

echo "Converted $count tiles to $OUTDIR/"

# Concatenate BG tiles (Pattern Table 1, tiles 256-511) into single blob
echo "Concatenating BG tiles (256-511) into build/bg_tiles.bin..."
mkdir -p build
> build/bg_tiles.bin
for i in $(seq 256 511); do
    printf -v name "tile_%03d.bin" "$i"
    cat "$OUTDIR/$name" >> build/bg_tiles.bin
done
echo "BG tile blob: $(wc -c < build/bg_tiles.bin) bytes"

# Concatenate sprite tiles (Pattern Table 0, tiles 0-255) into single blob
echo "Concatenating sprite tiles (0-255) into build/sprite_tiles.bin..."
> build/sprite_tiles.bin
for i in $(seq 0 255); do
    printf -v name "tile_%03d.bin" "$i"
    cat "$OUTDIR/$name" >> build/sprite_tiles.bin
done
echo "Sprite tile blob: $(wc -c < build/sprite_tiles.bin) bytes"
