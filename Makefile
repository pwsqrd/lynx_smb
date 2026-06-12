# Super Mario Bros - Atari Lynx Port
# Build system for assembling, linking, and asset conversion.
#
# Requires the cc65 toolchain (ca65, ld65, sp65) on your PATH. Override any of
# the tool variables below if they live elsewhere, e.g.:
#     make CA65=/opt/cc65/bin/ca65 LD65=/opt/cc65/bin/ld65 SP65=/opt/cc65/bin/sp65
# lynx.lib ships with cc65 and is located automatically by ld65's library
# search path (set CC65_HOME if your install needs it).

CA65    ?= ca65
LD65    ?= ld65
SP65    ?= sp65
PYTHON  ?= python3
FELIX   ?= Felix          # Lynx emulator used by `make run`; override as needed

export SP65   # asset scripts read $SP65 from the environment

# --- Dependency preflight ---------------------------------------------------
# Runs while make parses this file, i.e. BEFORE any build recipe. A missing
# toolchain fails fast with clear guidance instead of a cryptic "ca65: No such
# file or directory" mid-build (which also races under `make -j`). Skipped for
# clean/distclean, which need no toolchain.

ifneq ($(strip $(filter-out clean distclean,$(if $(MAKECMDGOALS),$(MAKECMDGOALS),all))),)

_dep_missing :=

ifeq ($(shell command -v $(CA65) >/dev/null 2>&1 && echo y),)
  _dep_missing += ca65
endif
ifeq ($(shell command -v $(LD65) >/dev/null 2>&1 && echo y),)
  _dep_missing += ld65
endif
ifeq ($(shell command -v $(SP65) >/dev/null 2>&1 && echo y),)
  _dep_missing += sp65
endif
ifeq ($(shell command -v $(PYTHON) >/dev/null 2>&1 && echo y),)
  _dep_missing += python3
else
  ifeq ($(shell $(PYTHON) -c "import PIL" >/dev/null 2>&1 && echo y),)
    _dep_missing += python-Pillow
  endif
endif

ifneq ($(strip $(_dep_missing)),)
  $(info )
  $(info ============================================================)
  $(info  Cannot build - missing dependencies:$(_dep_missing))
  $(info ============================================================)
  $(info )
  $(info This port needs the cc65 toolchain (ca65, ld65, sp65) plus)
  $(info Python 3 with the Pillow imaging library.)
  $(info )
  $(info To build the toolchain manually (the commit this port is tested with):)
  $(info .  git clone https://github.com/cc65/cc65.git)
  $(info .  cd cc65 && git checkout c720c3c4854cf36befbb7d1b19fdb207f7549882)
  $(info .  make -j && sudo make install PREFIX=/usr/local)
  $(info )
  $(info Install the Python dependencies (just Pillow):)
  $(info .  pip install -r requirements.txt)
  $(info )
  $(info If cc65 is installed but not on your PATH, point make at it:)
  $(info .  make CA65=/path/to/ca65 LD65=/path/to/ld65 SP65=/path/to/sp65)
  $(info )
  $(error missing dependencies:$(_dep_missing))
endif

endif
# ----------------------------------------------------------------------------

# Tile mode: 5x5 (default, uniform scaling) or 5x4 (more vertical content)
TILE_MODE ?= 5x5

ifeq ($(TILE_MODE),5x5)
  TILE_W = 5
  TILE_H = 5
  TILE_ASM_DEFINE = -D TILE_5x5=1
  # The default build is just "smb"; the alternate 5x4 mode is suffixed so the
  # two outputs don't clobber each other.
  ROM_BASE = smb
else ifeq ($(TILE_MODE),5x4)
  TILE_W = 5
  TILE_H = 4
  TILE_ASM_DEFINE =
  ROM_BASE = smb_5x4
else
  $(error Unknown TILE_MODE=$(TILE_MODE). Use 5x4 or 5x5)
endif

# Vertical scroll mode (5x5 only): TWO_POS (default), THREE_POS, PROPORTIONAL,
# LOOK_AHEAD, PLATFORM_LOCK
VSCROLL_MODE ?=
ifneq ($(VSCROLL_MODE),)
  VSCROLL_ASM_DEFINE = -D VSCROLL_$(VSCROLL_MODE)=1
else
  VSCROLL_ASM_DEFINE =
endif

CA65FLAGS = --cpu 65C02 -g $(TILE_ASM_DEFINE) $(VSCROLL_ASM_DEFINE)
LDFLAGS   = -C lynx_port/lynx_port.cfg --dbgfile out/$(ROM_BASE).dbg

ROM      = out/$(ROM_BASE).lnx
OBJECTS  = build/lynx_startup.o build/smb_lynx.o build/lynx_sprites.o build/lynx_audio.o
LYNXLIB  ?= lynx.lib
LDCONFIG = lynx_port/lynx_port.cfg

BG_TILES       = build/bg_tiles.bin
SPR_TILES      = build/sprite_tiles.bin
TEXT_TILES     = build/text_tiles.bin
METATILE_TILES = build/metatile_tiles.bin
SPRITE_FRAMES  = build/sprite_frames.bin
LOGO_SPRITE    = build/logo_sprite.bin
NES_ROM        = rom/SuperMarioBros.nes
SMB_SRC        = lynx_port/smb_lynx.s

TILE_ARGS = --tile-width $(TILE_W) --tile-height $(TILE_H)

ALL_ASSETS = $(BG_TILES) $(SPR_TILES) $(TEXT_TILES) $(METATILE_TILES) $(SPRITE_FRAMES) $(LOGO_SPRITE)

.PHONY: all assets verify-rom clean distclean run

all: $(ROM) out/$(ROM_BASE).lab out/$(ROM_BASE).sym

# --- ROM verification (by checksum, not filename) ---
# Every asset step depends on this, so the build fails early with a clear
# message if the required ROM has not been supplied in rom/.

verify-rom:
	$(PYTHON) tools/verify_rom.py

# --- Tile mode stamp (forces rebuild when TILE_MODE changes) ---

build/.tile_mode: FORCE
	@mkdir -p build
	@echo "$(TILE_MODE)" | cmp -s - $@ || echo "$(TILE_MODE)" > $@

FORCE:

# --- Asset pipeline ---

assets: $(ALL_ASSETS)

build/.chr_done: tools/extract_chr.py tools/area_downsample.py build/.tile_mode | verify-rom
	@mkdir -p build
	$(PYTHON) tools/extract_chr.py $(TILE_ARGS)
	bash tools/convert_sprites.sh
	@touch $@

$(BG_TILES): build/.chr_done

$(SPR_TILES): build/.chr_done tools/patch_score_sprites.py build/.tile_mode
	$(PYTHON) tools/patch_score_sprites.py $(TILE_ARGS)

$(TEXT_TILES): tools/build_text_tiles.py tools/area_downsample.py | verify-rom
	@mkdir -p build
	$(PYTHON) tools/build_text_tiles.py

$(METATILE_TILES): $(SMB_SRC) tools/build_metatiles.py build/.tile_mode | verify-rom
	@mkdir -p build
	$(PYTHON) tools/build_metatiles.py $(TILE_ARGS)

$(SPRITE_FRAMES): $(SMB_SRC) tools/build_sprite_frames.py tools/area_downsample.py build/.tile_mode | verify-rom
	@mkdir -p build
	$(PYTHON) tools/build_sprite_frames.py $(TILE_ARGS)

$(LOGO_SPRITE): tools/build_logo_sprite.py tools/area_downsample.py build/.tile_mode | verify-rom
	@mkdir -p build
	$(PYTHON) tools/build_logo_sprite.py $(TILE_ARGS)

# --- Assembly ---

build/lynx_startup.o: lynx_port/lynx_startup.s build/.tile_mode
	@mkdir -p build
	$(CA65) $(CA65FLAGS) -o $@ $<

build/smb_lynx.o: lynx_port/smb_lynx.s build/.tile_mode
	@mkdir -p build
	$(CA65) $(CA65FLAGS) -o $@ $<

build/lynx_sprites.o: lynx_port/lynx_sprites.s $(ALL_ASSETS) build/.tile_mode
	@mkdir -p build
	$(CA65) $(CA65FLAGS) -o $@ $<

build/lynx_audio.o: lynx_port/lynx_audio.s build/.tile_mode
	@mkdir -p build
	$(CA65) $(CA65FLAGS) -o $@ $<

# --- Link ---

$(ROM): $(OBJECTS) $(LDCONFIG)
	@mkdir -p out
	$(LD65) $(LDFLAGS) -o $@ $(OBJECTS) $(LYNXLIB)

# --- Debug symbols ---

out/$(ROM_BASE).lab: out/$(ROM_BASE).dbg
	$(PYTHON) tools/dbg2lab.py $< $@

out/$(ROM_BASE).dbg: $(ROM)
	@# Generated as a side-effect of linking (--dbgfile flag)
	@test -f $@ || { echo "Error: $@ not generated by linker"; exit 1; }

out/$(ROM_BASE).sym: out/$(ROM_BASE).lab
	cp $< $@

# --- Utilities ---

run: all
	$(FELIX) --rom $(ROM)

clean:
	rm -f $(OBJECTS) $(ROM) out/$(ROM_BASE).dbg out/$(ROM_BASE).lab out/$(ROM_BASE).sym

distclean: clean
	rm -rf character_data/
	rm -f $(ALL_ASSETS) build/.chr_done build/.tile_mode build/text_tile_index.bin build/metatile_index.bin
	rm -f build/sprite_frame_index.bin build/enemy_frame_offset_lut.bin
	rm -f build/misc_sprite_tiles.bin build/misc_sprite_index.bin
