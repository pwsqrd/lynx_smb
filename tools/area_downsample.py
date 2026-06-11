#!/usr/bin/env python3
"""Area-based threshold downsampling for NES tile conversion.

Replaces nearest-neighbor (Image.NEAREST) which skips source columns/rows
entirely, destroying thin strokes in text and fine detail in sprites.

Algorithm: each output pixel covers a fractional region of source pixels.
Every source pixel contributes proportionally to its area overlap. For each
non-zero color, total coverage is accumulated. If the dominant color's
coverage exceeds the threshold, that color is output; otherwise 0.

For 8->5 mapping, each output pixel covers 1.6 source pixels. A single-pixel
stroke covers up to 1.0/1.6 = 62.5% of its output pixel. Threshold of 0.3
preserves all single-pixel strokes while rejecting noise.

Edge-aware mode (opt-in via edge_threshold parameter):
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Used only for background metatiles (terrain, castle, pipes) -- NOT for
character sprites, text, coins, or other small detailed tiles.

Problem: NES background tiles have thin structural lines (castle brick mortar,
mountain slope outlines, pipe edges) that are just 1px wide. When downsampling
16x16 metatiles to 10x8 for the Lynx (2:1 Y ratio), a 1px horizontal line
lands exactly on a row boundary and gets split 50/50 between two output pixels.
Neither pixel gets enough coverage to pass the normal 0.3 threshold, so the
line vanishes entirely. The castle turns from a detailed brick wall into a
flat stone slab.

Three-layer solution:

1. Edge classification: source pixels adjacent (4-connected) to a different
   color are tagged as "edge pixels". When >50% of a color's weight in an
   output pixel comes from edge source pixels, a lower threshold (0.12) is
   used instead of the normal 0.3. This preserves edges that have at least
   ~12% coverage -- enough to catch a 1px line at worst-case straddling.

2. Minority-color tiebreaker: even with the lower threshold, the 2:1 Y ratio
   creates exact 50/50 ties between the mortar line (e.g. color-3) and the
   stone fill (color-2). Python's max() picks arbitrarily on ties, and the
   fill color wins by insertion order. Fix: count total pixels of each color
   across the entire source tile. When two colors tie locally (within 5%),
   the globally rarer color wins -- it's the accent/detail (mortar lines)
   that carries structural information. The fill color is already well-
   represented by all the surrounding output pixels.

3. Straddled edge restoration: a second pass catches edges that fell below
   even the 0.12 threshold. For any background (0) output pixel, if an edge
   color had >=8% coverage AND an adjacent output pixel already has that
   color, restore it. The adjacency requirement prevents isolated noise.
"""


def _classify_edges(pixels, src_w, src_h):
    """Mark source pixels adjacent (4-connected) to a different color as edges.

    Returns a 2D list [row][col] of booleans (True = edge pixel).
    """
    edges = [[False] * src_w for _ in range(src_h)]
    for y in range(src_h):
        for x in range(src_w):
            c = pixels[y][x]
            # Check 4 neighbors
            if (x > 0 and pixels[y][x - 1] != c) or \
               (x < src_w - 1 and pixels[y][x + 1] != c) or \
               (y > 0 and pixels[y - 1][x] != c) or \
               (y < src_h - 1 and pixels[y + 1][x] != c):
                edges[y][x] = True
    return edges


def _restore_lost_edges(result, dst_w, dst_h, weights, pixels, edges,
                        total_area, restore_threshold=0.08):
    """Second pass: restore edge colors that straddled output pixel boundaries.

    For output pixels that are 0 (background), check if any edge color had
    coverage >= restore_threshold AND an adjacent output pixel has that same
    color. If so, restore it. This catches straddled edges that even the lower
    edge threshold misses.
    """
    for oy in range(dst_h):
        for ox in range(dst_w):
            if result[oy][ox] != 0:
                continue

            # Gather edge-color coverage for this output pixel
            edge_coverage = {}
            for sx, sy, w in weights[oy][ox]:
                c = pixels[sy][sx]
                if c != 0 and edges[sy][sx]:
                    edge_coverage[c] = edge_coverage.get(c, 0.0) + w

            if not edge_coverage:
                continue

            # Check neighbors for matching colors
            neighbors = set()
            if ox > 0:
                neighbors.add(result[oy][ox - 1])
            if ox < dst_w - 1:
                neighbors.add(result[oy][ox + 1])
            if oy > 0:
                neighbors.add(result[oy - 1][ox])
            if oy < dst_h - 1:
                neighbors.add(result[oy + 1][ox])
            neighbors.discard(0)

            if not neighbors:
                continue

            # Find best edge color that also appears in a neighbor
            best_color = None
            best_cov = 0.0
            for c, cov in edge_coverage.items():
                frac = cov / total_area
                if frac >= restore_threshold and c in neighbors and frac > best_cov:
                    best_color = c
                    best_cov = frac

            if best_color is not None:
                result[oy][ox] = best_color


def precompute_weights(src_w, src_h, dst_w, dst_h):
    """Build overlap weight table for area-based downsampling.

    Returns list of (ox, oy) -> [(sx, sy, weight), ...] mappings.
    Each output pixel (ox, oy) maps to source pixels with fractional overlap.
    """
    scale_x = src_w / dst_w
    scale_y = src_h / dst_h

    weights = []
    for oy in range(dst_h):
        row = []
        # Source Y region for this output pixel
        sy0 = oy * scale_y
        sy1 = (oy + 1) * scale_y
        for ox in range(dst_w):
            # Source X region for this output pixel
            sx0 = ox * scale_x
            sx1 = (ox + 1) * scale_x

            pixel_weights = []
            # Iterate over all source pixels that overlap this region
            for sy in range(int(sy0), min(int(sy1) + 1, src_h)):
                # Y overlap fraction
                y_lo = max(sy, sy0)
                y_hi = min(sy + 1, sy1)
                if y_hi <= y_lo:
                    continue
                wy = y_hi - y_lo

                for sx in range(int(sx0), min(int(sx1) + 1, src_w)):
                    # X overlap fraction
                    x_lo = max(sx, sx0)
                    x_hi = min(sx + 1, sx1)
                    if x_hi <= x_lo:
                        continue
                    wx = x_hi - x_lo

                    pixel_weights.append((sx, sy, wx * wy))

            row.append(pixel_weights)
        weights.append(row)
    return weights


# Pre-computed weight tables for common sizes
_weight_cache = {}


def _get_weights(src_w, src_h, dst_w, dst_h):
    """Get or compute cached weight table."""
    key = (src_w, src_h, dst_w, dst_h)
    if key not in _weight_cache:
        _weight_cache[key] = precompute_weights(src_w, src_h, dst_w, dst_h)
    return _weight_cache[key]


def area_downsample(pixels, src_w, src_h, dst_w, dst_h, threshold=0.3,
                    edge_threshold=None):
    """Area-based threshold downsampling for indexed-color pixel data.

    Args:
        pixels: 2D list [row][col] of color indices (0-3 for 2bpp)
        src_w, src_h: source dimensions
        dst_w, dst_h: destination dimensions
        threshold: minimum coverage fraction for a color to appear (0.0-1.0)
        edge_threshold: if set, lower threshold used when >50% of a color's
            weight comes from edge-adjacent source pixels. None disables
            edge-aware mode (default).

    Returns:
        2D list [row][col] of output color indices
    """
    weights = _get_weights(src_w, src_h, dst_w, dst_h)
    total_area = (src_w / dst_w) * (src_h / dst_h)
    use_edges = edge_threshold is not None
    edges = _classify_edges(pixels, src_w, src_h) if use_edges else None

    # Global pixel census for minority-color tiebreaker
    global_count = {}
    if use_edges:
        for y in range(src_h):
            for x in range(src_w):
                c = pixels[y][x]
                if c != 0:
                    global_count[c] = global_count.get(c, 0) + 1

    result = []
    for oy in range(dst_h):
        row = []
        for ox in range(dst_w):
            # Accumulate coverage per color
            coverage = {}       # color -> total weight
            edge_weight = {}    # color -> weight from edge source pixels

            for sx, sy, w in weights[oy][ox]:
                c = pixels[sy][sx]
                if c != 0:  # skip background
                    coverage[c] = coverage.get(c, 0.0) + w
                    if use_edges and edges[sy][sx]:
                        edge_weight[c] = edge_weight.get(c, 0.0) + w

            if coverage:
                # Find dominant non-zero color
                best_color = max(coverage, key=coverage.get)
                best_coverage = coverage[best_color] / total_area

                effective_threshold = threshold
                if use_edges:
                    # Use lower edge_threshold when >50% of this color's
                    # weight comes from edge source pixels
                    ew = edge_weight.get(best_color, 0.0)
                    edge_frac = ew / coverage[best_color] if coverage[best_color] > 0 else 0
                    if edge_frac > 0.5:
                        effective_threshold = edge_threshold

                    # Minority-color tiebreaker: when two edge colors have
                    # nearly equal coverage, prefer the globally rarer one
                    # (it's the accent/detail, e.g. mortar lines in bricks).
                    if len(coverage) > 1:
                        sorted_colors = sorted(coverage.keys(),
                                               key=lambda c: coverage[c],
                                               reverse=True)
                        runner_up = sorted_colors[1]
                        diff = (coverage[best_color] - coverage[runner_up]) / total_area
                        if diff < 0.05:
                            gc_best = global_count.get(best_color, 0)
                            gc_runner = global_count.get(runner_up, 0)
                            if gc_runner < gc_best and coverage[runner_up] / total_area >= effective_threshold:
                                best_color = runner_up
                                best_coverage = coverage[runner_up] / total_area

                if best_coverage >= effective_threshold:
                    row.append(best_color)
                else:
                    row.append(0)
            else:
                row.append(0)
        result.append(row)

    if use_edges:
        # Second pass: restore straddled edges missed by even the lower threshold
        _restore_lost_edges(result, dst_w, dst_h, weights, pixels, edges, total_area)

    return result


# ----------------------------------------------------------------
# Outline-aware downsample (for castle turret crenellations)
# ----------------------------------------------------------------

def _outline_priority_downsample(pixels, src_w, src_h, dst_w, dst_h,
                                  outline_index=1, threshold=0.3):
    """Phase 1: Area downsample where outline pixels (outline_index) always win.

    If ANY source pixel in an output pixel's region is the outline color,
    that output pixel gets the outline color. For non-outline pixels, standard
    area downsample applies.

    Also tracks the source centroid of contributing outline pixels per output
    pixel (weighted by area overlap) for Phase 2 tiebreaking.

    Returns:
        (result, centroids) where:
        - result: 2D list of output color indices
        - centroids: 2D list of (cx, cy) source centroids for outline pixels,
          or None for non-outline output pixels
    """
    weights = _get_weights(src_w, src_h, dst_w, dst_h)
    total_area = (src_w / dst_w) * (src_h / dst_h)

    result = []
    centroids = []
    for oy in range(dst_h):
        row = []
        centroid_row = []
        for ox in range(dst_w):
            outline_weight = 0.0
            outline_cx = 0.0
            outline_cy = 0.0
            coverage = {}

            for sx, sy, w in weights[oy][ox]:
                c = pixels[sy][sx]
                if c != 0:
                    coverage[c] = coverage.get(c, 0.0) + w
                if c == outline_index:
                    outline_weight += w
                    # Centroid = center of source pixel
                    outline_cx += (sx + 0.5) * w
                    outline_cy += (sy + 0.5) * w

            if outline_weight > 0:
                row.append(outline_index)
                centroid_row.append((outline_cx / outline_weight,
                                     outline_cy / outline_weight))
            elif coverage:
                best_color = max(coverage, key=coverage.get)
                if coverage[best_color] / total_area >= threshold:
                    row.append(best_color)
                else:
                    row.append(0)
                centroid_row.append(None)
            else:
                row.append(0)
                centroid_row.append(None)
        result.append(row)
        centroids.append(centroid_row)
    return result, centroids


def _replacement_color(pixels, src_w, src_h, dst_w, dst_h, ox, oy,
                        outline_index=1):
    """Get dominant non-outline color from source region for an output pixel."""
    weights = _get_weights(src_w, src_h, dst_w, dst_h)
    coverage = {}
    for sx, sy, w in weights[oy][ox]:
        c = pixels[sy][sx]
        if c != 0 and c != outline_index:
            coverage[c] = coverage.get(c, 0.0) + w
    if coverage:
        return max(coverage, key=coverage.get)
    return 0


def _remove_interior_fill(result, dst_w, dst_h, pixels, src_w, src_h,
                           outline_index=1):
    """Phase 2a: Remove interior outline pixels.

    Iteratively remove index-1 pixels where all 4-connected neighbors are also
    index 1 (interior fill of solid merlon blocks). Replace with dominant
    non-outline color from source region. Repeat until stable.
    """
    changed = True
    while changed:
        changed = False
        for oy in range(dst_h):
            for ox in range(dst_w):
                if result[oy][ox] != outline_index:
                    continue
                # Check all 4-connected neighbors
                neighbors_all_outline = True
                for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                    ny, nx = oy + dy, ox + dx
                    if 0 <= ny < dst_h and 0 <= nx < dst_w:
                        if result[ny][nx] != outline_index:
                            neighbors_all_outline = False
                            break
                    else:
                        # Edge of image counts as non-outline
                        neighbors_all_outline = False
                        break
                if neighbors_all_outline:
                    result[oy][ox] = _replacement_color(
                        pixels, src_w, src_h, dst_w, dst_h, ox, oy,
                        outline_index)
                    changed = True


def _is_simple_point(result, dst_w, dst_h, ox, oy, outline_index=1):
    """Check if removing an outline pixel preserves 8-connectivity.

    Uses the crossing number test on 8-neighbors. A pixel is simple (safe to
    remove) if the crossing number of the outline pixels in its 8-neighborhood
    is exactly 1 (meaning there's exactly one connected component of outline
    neighbors).
    """
    # Get 8-neighbors in clockwise order: N, NE, E, SE, S, SW, W, NW
    neighbors = []
    for dy, dx in [(-1, 0), (-1, 1), (0, 1), (1, 1),
                   (1, 0), (1, -1), (0, -1), (-1, -1)]:
        ny, nx = oy + dy, ox + dx
        if 0 <= ny < dst_h and 0 <= nx < dst_w:
            neighbors.append(1 if result[ny][nx] == outline_index else 0)
        else:
            neighbors.append(0)

    # Count transitions from 0→1 in the circular neighbor sequence
    crossings = 0
    n = len(neighbors)
    for i in range(n):
        if neighbors[i] == 0 and neighbors[(i + 1) % n] == 1:
            crossings += 1

    return crossings == 1


def _thin_outline_pairs(result, centroids, dst_w, dst_h, pixels, src_w, src_h,
                         outline_index=1):
    """Phase 2b: Thin adjacent pairs of outline pixels to 1px.

    For each pair of adjacent outline pixels (horizontal or vertical):
    1. Compare which output pixel center is closer to the source outline centroid
    2. The farther pixel is the removal candidate
    3. Verify removal won't break 8-connectivity (crossing number test)
    4. If safe, replace with dominant non-outline color

    Process weakest-claim pixels first (largest centroid distance).
    """
    scale_x = src_w / dst_w
    scale_y = src_h / dst_h

    # Build list of removal candidates: (distance, oy, ox)
    candidates = []
    visited_pairs = set()

    for oy in range(dst_h):
        for ox in range(dst_w):
            if result[oy][ox] != outline_index:
                continue
            # Check right and down neighbors for pairs
            for dy, dx in [(0, 1), (1, 0)]:
                ny, nx = oy + dy, ox + dx
                if 0 <= ny < dst_h and 0 <= nx < dst_w:
                    if result[ny][nx] != outline_index:
                        continue
                    pair_key = (min(oy, ny), min(ox, nx), max(oy, ny), max(ox, nx))
                    if pair_key in visited_pairs:
                        continue
                    visited_pairs.add(pair_key)

                    # Get centroids
                    c1 = centroids[oy][ox]
                    c2 = centroids[ny][nx]
                    if c1 is None and c2 is None:
                        continue

                    # Output pixel centers in source coordinates
                    center1_x = (ox + 0.5) * scale_x
                    center1_y = (oy + 0.5) * scale_y
                    center2_x = (nx + 0.5) * scale_x
                    center2_y = (ny + 0.5) * scale_y

                    # Average centroid of the pair's outline source pixels
                    if c1 is not None and c2 is not None:
                        avg_cx = (c1[0] + c2[0]) / 2
                        avg_cy = (c1[1] + c2[1]) / 2
                    elif c1 is not None:
                        avg_cx, avg_cy = c1
                    else:
                        avg_cx, avg_cy = c2

                    # Distance from each output pixel center to centroid
                    d1 = (center1_x - avg_cx) ** 2 + (center1_y - avg_cy) ** 2
                    d2 = (center2_x - avg_cx) ** 2 + (center2_y - avg_cy) ** 2

                    # The farther pixel is the removal candidate
                    if d1 > d2:
                        candidates.append((d1, oy, ox))
                    else:
                        candidates.append((d2, ny, nx))

    # Sort by distance descending (remove weakest claims first)
    candidates.sort(reverse=True)

    for _dist, cy, cx in candidates:
        if result[cy][cx] != outline_index:
            continue  # already removed by an earlier candidate
        if _is_simple_point(result, dst_w, dst_h, cx, cy, outline_index):
            result[cy][cx] = _replacement_color(
                pixels, src_w, src_h, dst_w, dst_h, cx, cy, outline_index)


def outline_aware_downsample(pixels, src_w, src_h, dst_w, dst_h,
                              outline_index=1, threshold=0.3):
    """Two-phase outline-aware downsample for tiles with thin outline strokes.

    Designed for castle turret metatiles (0x45, 0x49) where index-1 pixels form
    1px-wide crenellation outlines that straddle output pixel boundaries during
    16→10 horizontal downscaling.

    Phase 1: Outline-priority area downsample — any output pixel overlapping
    an outline source pixel gets the outline color. Tracks source centroids.

    Phase 2a: Interior fill removal — iteratively erode outline pixels
    surrounded on all 4 sides by other outline pixels (solid merlon interiors).

    Phase 2b: Pair thinning — for adjacent pairs of outline pixels, remove the
    one whose output center is farther from the source outline centroid,
    preserving 8-connectivity.

    Args:
        pixels: 2D list [row][col] of color indices
        src_w, src_h: source dimensions
        dst_w, dst_h: destination dimensions
        outline_index: color index used for outlines (default 1)
        threshold: coverage threshold for non-outline colors

    Returns:
        2D list [row][col] of output color indices
    """
    # Phase 1
    result, centroids = _outline_priority_downsample(
        pixels, src_w, src_h, dst_w, dst_h, outline_index, threshold)

    # Phase 2a: remove interior fill
    _remove_interior_fill(result, dst_w, dst_h, pixels, src_w, src_h,
                           outline_index)

    # Phase 2b: thin pairs
    _thin_outline_pairs(result, centroids, dst_w, dst_h, pixels, src_w, src_h,
                         outline_index)

    return result


# ----------------------------------------------------------------
# Skeleton projection downsample (for castle turret tops, 5x5 mode)
# ----------------------------------------------------------------

def skeleton_projection_downsample(pixels, src_w, src_h, dst_w, dst_h,
                                    outline_index=1, threshold=0.3):
    """Skeleton projection downsample for tiles with thin outline strokes.

    Projects outline pixel coordinates from source to output space, bridges
    connectivity gaps, then overlays onto an area-downsampled background.

    Designed for castle turret top metatiles (0x45, 0x49) in 5x5 mode where
    the outline_aware algorithm loses top corners at 16->10 horizontal scale.

    Algorithm:
      1. Extract outline coordinates from source
      2. Project each to output space: out = floor((src + 0.5) * dst / src_dim)
      3. Bridge gaps between adjacent source outline pixels that map to
         non-adjacent output pixels (Bresenham-style interpolation)
      4. Build fill source replacing outline pixels with dominant neighbor color
      5. Area downsample the fill source for background colors
      6. Overlay projected outline pixels on top

    Args:
        pixels: 2D list [row][col] of color indices
        src_w, src_h: source dimensions
        dst_w, dst_h: destination dimensions
        outline_index: color index used for outlines (default 1)
        threshold: coverage threshold for background area downsample

    Returns:
        2D list [row][col] of output color indices
    """
    # Step 1: Extract outline coordinates
    outline_coords = set()
    for y in range(src_h):
        for x in range(src_w):
            if pixels[y][x] == outline_index:
                outline_coords.add((x, y))

    # Step 2: Project each outline pixel to output space
    def project(sx, sy):
        ox = int((sx + 0.5) * dst_w / src_w)
        oy = int((sy + 0.5) * dst_h / src_h)
        return (min(ox, dst_w - 1), min(oy, dst_h - 1))

    projected = set()
    for sx, sy in outline_coords:
        projected.add(project(sx, sy))

    # Step 3: Bridge connectivity gaps between adjacent source outline pixels
    for sx, sy in outline_coords:
        for dx, dy in [(1, 0), (0, 1), (1, 1), (-1, 1)]:
            nx, ny = sx + dx, sy + dy
            if (nx, ny) in outline_coords:
                ox1, oy1 = project(sx, sy)
                ox2, oy2 = project(nx, ny)
                # If projected points are non-adjacent, interpolate
                gap_x = abs(ox2 - ox1)
                gap_y = abs(oy2 - oy1)
                if gap_x > 1 or gap_y > 1:
                    steps = max(gap_x, gap_y)
                    for s in range(1, steps):
                        ix = ox1 + round((ox2 - ox1) * s / steps)
                        iy = oy1 + round((oy2 - oy1) * s / steps)
                        projected.add((ix, iy))

    # Step 4: Build fill source (replace outline pixels with dominant neighbor)
    fill_pixels = [row[:] for row in pixels]
    for sx, sy in outline_coords:
        neighbor_colors = {}
        for ddx, ddy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            nnx, nny = sx + ddx, sy + ddy
            if 0 <= nnx < src_w and 0 <= nny < src_h:
                c = pixels[nny][nnx]
                if c != outline_index:
                    neighbor_colors[c] = neighbor_colors.get(c, 0) + 1
        if neighbor_colors:
            non_bg = {c: n for c, n in neighbor_colors.items() if c != 0}
            if non_bg:
                fill_pixels[sy][sx] = max(non_bg, key=non_bg.get)
            else:
                fill_pixels[sy][sx] = max(neighbor_colors, key=neighbor_colors.get)
        else:
            fill_pixels[sy][sx] = 0

    # Step 5: Area downsample the fill source for background colors
    result = area_downsample(fill_pixels, src_w, src_h, dst_w, dst_h,
                             threshold=threshold, edge_threshold=None)

    # Step 6: Overlay projected outline pixels
    for ox, oy in projected:
        result[oy][ox] = outline_index

    return result
