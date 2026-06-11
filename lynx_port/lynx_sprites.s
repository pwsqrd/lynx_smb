.include "cheat.inc"

; =============================================================================
; LYNX_SPRITES.S - Sprite rendering via Suzy engine + NES palette translation
; =============================================================================
; Provides:
;   - Dynamic palette allocation (all 8 NES palettes → 16 Lynx slots)
;   - SyncLynxPalette: deduplicates NES colors, builds pen mapping tables
;   - FindOrAllocSlot: stable color→slot assignment with dedup
;   - ScaleCoord: NES→Lynx coordinate scaling (floor(n*5/8))
;   - LynxDrawTile: render one 5x5 BG tile by index
;   - LynxDrawTextLine: render a horizontal row of tiles
;   - LynxDrawTitleText: render all title screen text strings
;   - LynxDrawMushroomIcon: renders mushroom icon sprite via Suzy engine
;   - LynxRenderSprites: render OAM sprites with per-sprite palette
;   - LynxRedrawBG: render background metatiles with per-metatile palette
;
; Palette system overview:
;   The NES has 8 palettes (4 BG + 4 sprite), each with 3 unique colors plus
;   a shared BG color = up to 25 entries. The Lynx has 16 hardware palette
;   slots. SyncLynxPalette deduplicates the 24 unique NES color entries into
;   ≤16 Lynx slots (SMB typically uses 10-13 unique colors). Slot assignments
;   are persistent across frames to prevent the displayed frame from showing
;   wrong colors when the hardware palette is updated (since the palette is
;   global and shared between display and render buffers). Overflow from stale
;   slots triggers a one-time full rebuild.
;
;   DynPenPal0[0-7] and DynPenPal1[0-7] provide packed pen→slot mappings for
;   each NES palette (BG 0-3 at indices 0-3, SPR 0-3 at indices 4-7). All
;   rendering code reads these tables instead of using hardcoded slot numbers.
; =============================================================================

.pc02
.feature c_comments

; =============================================================================
; EXPORTS / IMPORTS
; =============================================================================

.export SyncLynxPalette
.export ApplyHardwarePalette
.export ClearFramebuffer
.export SetupTileSCB
.export ShadowPPUHi, ShadowPPULo
.export LynxRenderSprites
.export LynxRedrawBG, FrameReady, RenderBlinkToggle
.export Render_Buffer_1, Render_Buffer_2
.export SwapBuffers, InitDoubleBuffer, DrawBufHi
.export SprPriorityPass
.export PaletteDirtyFlag
.export NesPaletteShadow
.export LynxRenderIntermediate
.export LynxRenderGameOver
.export LynxRenderVictory
.export VictoryMsgMax
.export LynxTimeUpFlag
.export LynxRenderHUD
.export LynxDrawTitleElements
.export TitleZoomFrame
.export SetScrollHOFF, ResetHOFF, CurrentHOFF
.ifdef TILE_5x5
.export UpdateVerticalScroll, CurrentYOffset
.endif
.import NumberOfPlayers
.import ScreenRoutineTask, WorldNumber, LevelNumber, NumberofLives, DisableIntermediate
.import MarioThanksMessage, LuigiThanksMessage
.import MushroomRetainerSaved, PrincessSaved1, PrincessSaved2
.import WorldSelectMessage1, WorldSelectMessage2
.import Mirror_PPU_CTRL_REG1, InjuryTimer, Player_SprDataOffset
.import ScreenLeft_PageLoc, ScreenLeft_X_Pos
.import OperMode, OperMode_Task
.import DisplayDigits, GameTimerDisplay
.import CoinTally, CurrentPlayer
.import AltEntranceControl
.import Sprite_Data
.ifdef TILE_5x5
.importzp Player_Y_Position, Player_Y_HighPos, Player_Y_Speed
.endif

; =============================================================================
; LYNX HARDWARE REGISTER DEFINES
; =============================================================================

.include "lynx_hw.inc"

.import PPU_DATA
GameModeValue         = 1
GameOverModeValue     = 3
GameEngineSubroutine  = $0e
AreaType              = $074e

; NES tile grid → pixel conversion
.ifdef TILE_5x5
NES_TILE_W      = 5
NES_TILE_H      = 5
LYNX_Y_OFFSET   = 34
CAMERA_Y_MIN    = 14            ; highest camera (two tiles above ground default)
CAMERA_Y_MID    = 24            ; mid camera (for three-position mode)
CAMERA_Y_MAX    = 34            ; lowest camera (ground row 11 at screen_y 92)
DWELL_FRAMES    = 8             ; platform-lock dwell threshold (~133ms at 60fps)
TILE_SIZE       = 16            ; literal 2bpp 5x5 = 16 bytes per tile
.else
NES_TILE_W      = 5
NES_TILE_H      = 4
LYNX_Y_OFFSET   = 6
TILE_SIZE       = 13            ; literal 2bpp 5x4 = 13 bytes per tile
.endif
.define NES_COL_PX(col) ((col) * NES_TILE_W)
.define NES_ROW_PX(row) ((row) * NES_TILE_H - LYNX_Y_OFFSET)

; Interstitial screen: Mario sprite row (must match "x N" text row)
INTERSTITIAL_MARIO_ROW = 11
INTERSTITIAL_MARIO_Y_PX = INTERSTITIAL_MARIO_ROW * NES_TILE_H - LYNX_Y_OFFSET
.ifdef TILE_5x5
INTERSTITIAL_NES_Y = ((INTERSTITIAL_MARIO_Y_PX + CAMERA_Y_MAX) * 8 + 4) / 5 - 1
.else
INTERSTITIAL_NES_Y = (INTERSTITIAL_MARIO_Y_PX + LYNX_Y_OFFSET) * 2 - 1
.endif
.exportzp INTERSTITIAL_NES_Y

; =============================================================================
; RODATA SEGMENT - Lookup tables and sprite data
; =============================================================================

.rodata

; Single-pixel literal sprite (4bpp): 1 scanline + end marker
ClearSpriteData:
    .byte $03, $00, $00         ; line 0: offset=3, 2 bytes pixel data (4 pixels pen 0)
    .byte $00                   ; end of sprite


; -----------------------------------------------------------------------------
; NES master palette -> Lynx green channel (64 entries)
; Index = NES color value ($00-$3F)
; Value = Lynx green register value (bits 3-0 = green, bits 7-4 = 0)
; Source: standard NES 2C02 palette
; -----------------------------------------------------------------------------
NEStoLynxGreen:
    .byte $07,$00,$00,$02,$00,$00,$01,$01,$03,$07,$06,$05,$04,$00,$00,$00  ; $00-$0F
    .byte $0B,$07,$05,$04,$00,$00,$03,$05,$07,$0B,$0A,$0A,$08,$00,$00,$00  ; $10-$1F
    .byte $0F,$0B,$08,$07,$07,$05,$07,$0A,$0B,$0F,$0D,$0F,$0E,$07,$00,$00  ; $20-$2F
    .byte $0F,$0E,$0B,$0B,$0B,$0A,$0D,$0E,$0D,$0F,$0F,$0F,$0F,$0D,$00,$00  ; $30-$3F

; -----------------------------------------------------------------------------
; NES master palette -> Lynx blue/red channel (64 entries)
; Index = NES color value ($00-$3F)
; Value = Lynx blue/red register (bits 7-4 = blue, bits 3-0 = red)
; -----------------------------------------------------------------------------
NEStoLynxBlueRed:
    .byte $77,$F0,$B0,$B4,$89,$2A,$0A,$08,$05,$00,$00,$00,$50,$00,$00,$00  ; $00-$0F
    .byte $BB,$F0,$F0,$F6,$CD,$5E,$0F,$1E,$0A,$00,$00,$40,$80,$00,$00,$00  ; $10-$1F
    .byte $FF,$F3,$F6,$F9,$FF,$9F,$5F,$4F,$0F,$1B,$55,$95,$D0,$77,$00,$00  ; $20-$2F
    .byte $FF,$FA,$FB,$FD,$FF,$CF,$BF,$AF,$7F,$7D,$BB,$DB,$F0,$FF,$00,$00  ; $30-$3F

; -----------------------------------------------------------------------------
; Offset into NesPaletteShadow for first color of each NES palette
; Each palette has 4 bytes (shared BG + 3 unique), spaced 4 apart
; BG palettes at $00,$04,$08,$0C; SPR palettes at $10,$14,$18,$1C
; +1 skips the shared BG color (slot 0 handles it separately)
; -----------------------------------------------------------------------------
PalBaseTable:
    .byte $01, $05, $09, $0D   ; BG palettes 0-3
    .byte $11, $15, $19, $1D   ; SPR palettes 0-3

; Sparse text tile lookup (replaces 256-byte TextTileIndex table)
; Tiles $00-$29 use identity mapping; these 3 tiles need explicit lookup.
; Order must match dense indices 42-44.
TextTileSparse:
    .byte $2B, $2E, $AF
TextTileSparse_End:

; -----------------------------------------------------------------------------
; Text Tile Data - dense blob of text/HUD tiles (literal 1bpp 5x5)
; Each tile is exactly 11 bytes. Indexed via TextTileSparse + identity map.
; Built by tools/build_text_tiles.py
; -----------------------------------------------------------------------------
TextTileData:
    .incbin "build/text_tiles.bin"

; -----------------------------------------------------------------------------
; 2bpp Text Tiles - mushroom ($CE) and copyright ($CF) need multi-color
; Each tile is 16 bytes (literal 2bpp 5x5, text tiles stay 5x5). Order: $CE, $CF.
; -----------------------------------------------------------------------------
TextTile2bpp:
    .incbin "build/text_tiles_2bpp.bin"

; -----------------------------------------------------------------------------
; Clock icon - 2bpp literal 5x5, white face (pen 1) + black hands (pen 3)
; 3 o'clock: minute hand at 12, hour hand at 3
;   .1O1.   O = pen 3 (minute hand, 12 o'clock)
;   ##O##
;   ##OOO   O = pen 3 (hour hand, 3 o'clock)
;   #####
;   .###.
; -----------------------------------------------------------------------------
ClockTile2bpp:
    .byte $03, $1D, $00         ; row 0: .131.
    .byte $03, $5D, $40         ; row 1: 11311
    .byte $03, $5F, $C0         ; row 2: 11333
    .byte $03, $55, $40         ; row 3: 11111
    .byte $03, $15, $00         ; row 4: .111.
    .byte $00                   ; terminator

; -----------------------------------------------------------------------------
; Logo Sprite Data - pre-composited title logo (packed 2bpp 110x44)
; 22x11 NES tiles composited at 8x8 then downscaled to Lynx resolution.
; Built by tools/build_logo_sprite.py
; -----------------------------------------------------------------------------
LogoSpriteData:
    .incbin "build/logo_sprite.bin"

HUDLabelMario:
    .byte $16,$0A,$1B,$12,$18   ; "MARIO"
HUDLabelMario_End:

HUDLabelTime:
    .byte $1D,$12,$16,$0E       ; "TIME"
HUDLabelTime_End:

; -----------------------------------------------------------------------------
; Sprite Tile Data - All 256 sprite tiles (Pattern Table 0) as literal 2bpp
; Each tile is exactly 13 bytes (literal 2bpp 5x4)
; 256 tiles x 13 bytes = 3,328 bytes
; Tile index N maps to offset N * 13
; -----------------------------------------------------------------------------
SpriteTileData:
    .incbin "build/sprite_tiles.bin"

; -----------------------------------------------------------------------------
; Metatile Index Table - maps metatile byte (0-255) to dense index
; $FF = undefined/blank (skip rendering)
; Built by tools/build_metatiles.py
; -----------------------------------------------------------------------------
.ifdef TILE_5x5
METATILE_SIZE = 41              ; literal 2bpp 10x10
.else
METATILE_SIZE = 33              ; literal 2bpp 10x8
.endif
MetatileIndex:
    .incbin "build/metatile_index.bin"

; -----------------------------------------------------------------------------
; Metatile Tile Data - dense blob of defined metatile sprites (literal 2bpp 10x8)
; Each metatile is exactly 33 bytes (sp65 literal 2bpp 10x8)
; Indexed via MetatileIndex table: MetatileTileData + dense_index * 33
; Built by tools/build_metatiles.py
; -----------------------------------------------------------------------------
MetatileTileData:
    .incbin "build/metatile_tiles.bin"

; ScaleTable removed — replaced by ScaleCoord subroutine in CODE segment

; -----------------------------------------------------------------------------
; FlipTable - NES attribute flip bits -> Lynx SPRCTL0 value
; Index = (NES attributes >> 6) & 3
; Value = SPRCTL0: 2bpp (bits 7-6 = %01), type 4 normal (bits 2-0), +flip bits
; Type 4 makes pen 0 transparent (critical for sprite overlays)
; -----------------------------------------------------------------------------
FlipTable:
    .byte (BPP_2 | TYPE_NORMAL)            ; 0: no flip
    .byte (BPP_2 | HFLIP | TYPE_NORMAL)    ; 1: HFLIP
    .byte (BPP_2 | VFLIP | TYPE_NORMAL)    ; 2: VFLIP
    .byte (BPP_2 | HFLIP | VFLIP | TYPE_NORMAL) ; 3: H+V FLIP

; -----------------------------------------------------------------------------
; Title screen text strings (NES BG tile indices)
; $24 = space tile (will be skipped)
; Tile indices reference Pattern Table 1 (BG tiles in our blob)
; -----------------------------------------------------------------------------
CopyrightTxt:
    .byte $CF,$01,$09,$08,$05,$24,$17,$12,$17,$1D,$0E,$17,$0D,$18
CopyrightTxt_End:

MenuText1P:
    .byte $01,$24,$19,$15,$0A,$22,$0E,$1B,$24,$10,$0A,$16,$0E
MenuText1P_End:

MenuText2P:
    .byte $02,$24,$19,$15,$0A,$22,$0E,$1B,$24,$10,$0A,$16,$0E
MenuText2P_End:

;TopTxt:
;    .byte $1D,$18,$19,$28
;TopTxt_End:

IntermediateWorldText:
    .byte $20,$18,$1B,$15,$0D   ; "WORLD"
IntermediateWorldText_End:

GameOverText:
    .byte $10,$0A,$16,$0E,$24,$18,$1F,$0E,$1B   ; "GAME OVER"
GameOverText_End:

TimeUpText:
    .byte $1D,$12,$16,$0E,$24,$1E,$19            ; "TIME UP"
TimeUpText_End:

; Victory text data reuses NES message labels from smb_lynx.s
; Each NES message has a 3-byte VRAM header; tile data starts at label+3
; Lengths from NES message header byte (3rd byte of header)
VICTORY_THANKS_LEN    = 16    ; "THANK YOU MARIO!/LUIGI!" ($10)
VICTORY_RET1_LEN      = 22    ; "BUT OUR PRINCESS IS IN" ($16)
VICTORY_RET2_OFS      = 28    ; Offset to "ANOTHER CASTLE!" within MushroomRetainerSaved
VICTORY_RET2_LEN      = 15    ; "ANOTHER CASTLE!" ($0F)
VICTORY_PRIN1_LEN     = 19    ; "YOUR QUEST IS OVER." ($13)
VICTORY_PRIN2_LEN     = 27    ; "WE PRESENT YOU A NEW QUEST." ($1B)
VICTORY_WSEL1_LEN     = 13    ; "PUSH BUTTON B" ($0D)
VICTORY_WSEL2_LEN     = 17    ; "TO SELECT A WORLD" ($11)


; Table for title text drawing: ptr_lo, ptr_hi, base_x, y, len (5 bytes each)
TitleTextTable:
.ifdef TILE_5x5
    .byte <CopyrightTxt, >CopyrightTxt, NES_COL_PX(13), NES_ROW_PX(18), (CopyrightTxt_End - CopyrightTxt)
    .byte <MenuText1P, >MenuText1P, NES_COL_PX(11), NES_ROW_PX(20), (MenuText1P_End - MenuText1P)
    .byte <MenuText2P, >MenuText2P, NES_COL_PX(11), NES_ROW_PX(22), (MenuText2P_End - MenuText2P)
.else
    .byte <CopyrightTxt, >CopyrightTxt, NES_COL_PX(13), NES_ROW_PX(14), (CopyrightTxt_End - CopyrightTxt)
    .byte <MenuText1P, >MenuText1P, NES_COL_PX(11), NES_ROW_PX(18), (MenuText1P_End - MenuText1P)
    .byte <MenuText2P, >MenuText2P, NES_COL_PX(11), NES_ROW_PX(20), (MenuText2P_End - MenuText2P)
.endif
    ;.byte <TopTxt, >TopTxt, NES_COL_PX(12), NES_ROW_PX(25), (TopTxt_End - TopTxt)
TITLE_TEXT_COUNT = 3
TITLE_TEXT_ENTRY = 5

; =============================================================================
; RECYCLEDATA SEGMENT - Overlays dead startup code ($0800-$08D2, 211 bytes)
; =============================================================================
; After boot, lynx_startup.s code at $0800 is dead. We reuse that memory for
; render-time BSS variables. This frees space in the MAIN BSS region which
; was overflowing past the framebuffer boundary at $BC20.

.segment "RECYCLEDATA"

; Sprite Control Block in RAM (for Suzy engine)
; Format: SPRCTL0, SPRCTL1, SPRCOLL, SCBNEXT(2), SPRDATA(2),
;         HPOS(2), VPOS(2), HSIZE(2), VSIZE(2), PALETTE(8)
SCB_SPRCTL0:    .res 1
SCB_SPRCTL1:    .res 1
SCB_SPRCOLL:    .res 1
SCB_NEXT_L:     .res 1
SCB_NEXT_H:     .res 1
SCB_DATA_L:     .res 1
SCB_DATA_H:     .res 1
SCB_HPOS_L:     .res 1
SCB_HPOS_H:     .res 1
SCB_VPOS_L:     .res 1
SCB_VPOS_H:     .res 1
SCB_HSIZE_L:    .res 1
SCB_HSIZE_H:    .res 1
SCB_VSIZE_L:    .res 1
SCB_VSIZE_H:    .res 1
SCB_PALETTE:    .res 8

; Text drawing state
TextXPos:       .res 1          ; Current X pixel position
TextYPos:       .res 1          ; Current Y pixel position
TextLen:        .res 1          ; Remaining characters to draw

; Double buffer state
DrawBufHi:      .res 1          ; High byte of draw buffer ($BC=FB0, $DC=FB1)

; VRAM write state
ShadowPPUHi:    .res 1          ; PPU address high byte shadow
ShadowPPULo:    .res 1          ; PPU address low byte shadow
PaletteDirtyFlag: .res 1       ; Set to 1 when $3F00+ shadow palette updated

; Sprite rendering state (used by LynxRenderSprites)
SprPriorityPass: .res 1         ; $00 = front sprites, $20 = behind-BG sprites

; Dynamic palette allocation state
DynSlotColor:   .res 16         ; NES color stored in each Lynx slot
DynSlotCount:   .res 1          ; Number of slots allocated (1-16)
DynPenPal0:     .res 8          ; Pen palette byte 0 for NES palettes 0-7
DynPenPal1:     .res 8          ; Pen palette byte 1 for NES palettes 0-7
PenSlot1:       .res 1          ; Scratch: pen 1 slot during build
PenSlot2:       .res 1          ; Scratch: pen 2 slot during build
PenSlot3:       .res 1          ; Scratch: pen 3 slot during build

; NES palette shadow RAM (32 bytes, replaces $3F00+ which overlaps code)
NesPaletteShadow: .res 32

; Sprite rendering state (used by LynxRenderSprites)
OAMIndex:       .res 1          ; Current OAM offset (0, 4, 8, ..., 252)

; =============================================================================
; BSS SEGMENT - (empty; all render vars moved to RECYCLEDATA/HIGHDATA)
; =============================================================================

.bss

; =============================================================================
; HIGHDATA SEGMENT - High RAM ($FE00-$FFF7, always RAM via MAPCTL B2)
; =============================================================================
; Variables moved here to keep BSS below $BC20 (framebuffer start).
; Add future variables here rather than in BSS to avoid overflow.

.segment "HIGHDATA"

; Frame synchronization
FrameReady:     .res 1          ; Set by NMI when game logic done, cleared by main loop
RenderBlinkToggle: .res 1      ; Toggles each rendered frame for injury blink

; Title screen scroll state
TitleScrollLo:  .res 1          ; Scroll offset low byte (Lynx pixels)
TitleScrollHi:  .res 1          ; Scroll offset high byte
TextXPosHi:     .res 1          ; High byte for 16-bit text X (scroll support)
TitleZoomFrame: .res 1          ; 0=waiting, 1-32=zooming, 33+=done
LynxTimeUpFlag: .res 1          ; Set when "TIME UP" should render on interstitial
VictoryMsgMax:  .res 1          ; Highest VRAM_Buffer_AddrCtrl seen during victory messages

; Tile/text pointers (moved from zeropage; ZP is reserved for SMB)
TilePtr:        .res 2          ; Pointer to tile sprite data (arithmetic only, no indirect)
TextPtr:        .res 2          ; Pointer to text string data (copied to ZP $02/$03 for indirect)

; BG redraw state (used by LynxRedrawBG)
BGBufIdx:       .res 1          ; Block buffer column index (0-31)
BGCol:          .res 1          ; Current metatile column counter (0-15)
BGRow:          .res 1          ; Current metatile row counter (5-12)
BGXPos:         .res 1          ; Current X pixel position
BGXPosHi:       .res 1          ; Current X pixel position (high byte, sign extension)
BGYPos:         .res 1          ; Current Y pixel position
BGMetaByte:     .res 1          ; Current metatile byte from block buffer
BGScrollXOff:   .res 1          ; Sub-metatile X scroll offset (Lynx pixels)
CurrentHOFF:    .res 1          ; Current HOFF value for this frame (0-9)
.ifdef TILE_5x5
CurrentYOffset: .res 1          ; Dynamic vertical offset (replaces static LYNX_Y_OFFSET)
TargetYOffset:  .res 1          ; Target Y offset (computed from player position)
.ifndef VSCROLL_THREE_POS
.ifndef VSCROLL_TWO_POS
VScrollDwell:   .res 1          ; Frame counter for platform-lock dwell detection
.endif
.endif
.endif
BGBufPtrL:      .res 1          ; Render buffer column pointer (low) - safe copy
BGBufPtrH:      .res 1          ; Render buffer column pointer (high) - safe copy
MetaAddrLo:     .res 1          ; Metatile sprite data address (low)
MetaAddrHi:     .res 1          ; Metatile sprite data address (high)
RowYPos:        .res 13         ; Precomputed Y pixel position for rows 0-12
RowVisible:     .res 13         ; Precomputed visibility flag for rows 0-12 (1=visible)

; Render buffers - parallel to Block_Buffer_1/2, unfiltered metatile data
; Same 13×16 layout as block buffers (rows spaced $10 apart)
; In HIGHDATA to keep BSS below $BC20 (framebuffer start)
Render_Buffer_1: .res 208       ; 13 rows × 16 cols (columns 0-15)
Render_Buffer_2: .res 208       ; 13 rows × 16 cols (columns 16-31)

; =============================================================================
; FRAMEBUF0 / FRAMEBUF1 SEGMENTS - Auto-placed by linker immediately after BSS
; =============================================================================
; Linker assertion (lynx_port.cfg) fires at build time if BSS overflows past $BC1F.
; With 12 bytes of overflow moved to HIGHDATA, BSS ends at $BC1F and:
;   FRAMEBUF0 → $BC20 (= FRAMEBUFFER_0 in lynx_hw.inc)
;   FRAMEBUF1 → $DC20 (= FRAMEBUFFER_1 in lynx_hw.inc)
; If either address shifts, the build will error and you must move vars to HIGHDATA.

.segment "FRAMEBUF0"
.export Framebuffer0
Framebuffer0:   .res $1FE0      ; 8,160 bytes (160×102 at 4bpp) — framebuffer 0
                .res $0020      ; 32-byte gap: keeps FB1 at same low byte ($20)

.segment "FRAMEBUF1"
.export Framebuffer1
Framebuffer1:   .res $1FE0      ; 8,160 bytes (160×102 at 4bpp) — framebuffer 1

; Build-time layout checks: if BSS overflows past $BC1F these will fail at link.
; Fix: move new BSS variables to .segment "HIGHDATA" instead of .bss.
.assert Framebuffer0 = FRAMEBUFFER_0, error, "FB0 not at $BC20 - check linker config FB0MEM start address"
.assert Framebuffer1 = FRAMEBUFFER_1, error, "FB1 not at $DC20 - check linker config FB1MEM start address"

; =============================================================================
; CODE SEGMENT
; =============================================================================

.code


; =============================================================================
; SyncLynxPalette - Dynamic NES→Lynx palette allocation
; =============================================================================
; Deduplicates all 24 NES palette color entries (8 palettes × 3 colors) into
; ≤16 Lynx hardware slots via FindOrAllocSlot. Slot 0 is always the shared
; BG color (NesPaletteShadow byte 0). Each unique NES color gets one Lynx
; slot; duplicates across palettes share the same slot.
;
; Produces two output tables consumed by all rendering code:
;   DynPenPal0[0-7]: packed pen palette byte 0 (pen0=slot0, pen1=slotN)
;   DynPenPal1[0-7]: packed pen palette byte 1 ((pen2<<4) | pen3)
;   Index 0-3 = BG palettes, 4-7 = sprite palettes
;
; Slot assignments are persistent across frames (DynSlotCount is not reset).
; This prevents the currently-displayed frame from showing wrong colors when
; the hardware palette registers change, since existing slot→RGB mappings
; never move. Only genuinely new NES colors allocate new slots.
;
; When the BG color changes (level transition detected), DynSlotCount resets
; to 1, flushing all stale slots from the previous area. This ensures clean
; allocation for the new palette. As a safety net, if all 16 slots are
; exhausted, FindOrAllocSlot's overflow handler also resets and rebuilds.
;
; Clobbers: A, X, Y
; =============================================================================

SyncLynxPalette:
    ; Slot 0 = universal BG color (NesPaletteShadow byte 0)
    ; Detect BG color change (level transition) and flush stale slots
    lda NesPaletteShadow
    cmp DynSlotColor            ; compare with current slot 0
    beq @bg_unchanged
    ; BG color changed — flush all stale slots for a clean rebuild.
    ; This happens on area transitions (e.g. overworld→underground) where
    ; old colors waste slots and prevent correct allocation of new colors.
    ldx #1
    stx DynSlotCount
@bg_unchanged:
    ; Update slot 0 NES color (hardware write deferred to ApplyHardwarePalette)
    sta DynSlotColor

    ; Initialize slot count on first call only (BSS zeros to 0)
    lda DynSlotCount
    bne @slots_ready
    lda #1
    sta DynSlotCount
@slots_ready:

    ; Process 8 palettes (X = 0-7)
    ldx #0
@pal_loop:
    ldy PalBaseTable,x          ; Y = shadow offset of color 1

    ; Pen 1
    lda NesPaletteShadow,y
    jsr FindOrAllocSlot
    sta PenSlot1
    iny

    ; Pen 2
    lda NesPaletteShadow,y
    jsr FindOrAllocSlot
    sta PenSlot2
    iny

    ; Pen 3
    lda NesPaletteShadow,y
    jsr FindOrAllocSlot
    sta PenSlot3

    ; Pack DynPenPal0: pen0=slot0 (upper nibble 0), pen1=slot N (lower nibble)
    lda PenSlot1
    sta DynPenPal0,x

    ; Pack DynPenPal1: (pen2 << 4) | pen3
    lda PenSlot2
    asl
    asl
    asl
    asl
    ora PenSlot3
    sta DynPenPal1,x

    inx
    cpx #8
    bne @pal_loop

    rts

; =============================================================================
; FindOrAllocSlot - Find existing Lynx slot for NES color, or allocate new one
; =============================================================================
; Input: A = NES color index (0-63)
; Output: A = Lynx slot number (0-15)
; Preserves: X, Y
; =============================================================================

FindOrAllocSlot:
    phx                         ; save palette loop counter
    phy                         ; save caller's Y (palette offset)
    ldx #0
@search:
    cpx DynSlotCount
    beq @alloc                  ; not found, allocate new slot
    cmp DynSlotColor,x
    beq @found
    inx
    bra @search
@found:
    txa                         ; A = existing slot number
    ply                         ; restore caller's Y
    plx                         ; restore palette loop X
    rts
@alloc:
    cpx #16
    bcs @overflow               ; all 16 slots used, fallback
    sta DynSlotColor,x          ; record NES color in this slot
    txa                         ; A = new slot number
    inx
    stx DynSlotCount            ; bump slot count
    ply                         ; restore caller's Y
    plx                         ; restore palette loop X
    rts
@overflow:
    ; All 16 slots exhausted (e.g. during level transition).
    ; Return slot 0 (BG color) as safe fallback; reset count so next frame rebuilds.
    lda #1                      ; reset slot count for next frame's rebuild
    sta DynSlotCount
    lda #0                      ; return slot 0 = BG color (safe fallback)
    ply                         ; restore caller's Y
    plx                         ; restore palette loop X
    rts                         ; return normally (no stack hack)

; =============================================================================
; ApplyHardwarePalette - Write deferred palette slots to Lynx hardware
; =============================================================================
; Writes all allocated DynSlotColor[] entries to GCOLMAP/RBCOLMAP registers.
; Called immediately before SwapBuffers so the hardware palette update and
; buffer flip happen back-to-back, preventing the old front buffer from being
; displayed with mismatched palette colors.
;
; Clobbers: A, X, Y
; =============================================================================

ApplyHardwarePalette:
    ldx #0
@loop:
    cpx DynSlotCount
    beq @done
    ldy DynSlotColor,x
    lda NEStoLynxGreen,y
    sta GCOLMAP,x
    lda NEStoLynxBlueRed,y
    sta RBCOLMAP,x
    inx
    bra @loop
@done:
    rts

; =============================================================================
; ScaleCoord - Convert NES coordinate to Lynx: floor(A * 5 / 8)
; =============================================================================
; Input: A = NES coordinate (0-255)
; Output: A = Lynx coordinate (0-159)
; Preserves: X, Y
; Clobbers: $00, $01 (caller must save if needed)
; =============================================================================

ScaleCoord:
    sta $00                     ; save n
    stz $01                     ; clear high byte
    asl                         ; n*2
    rol $01
    asl                         ; n*4
    rol $01
    clc
    adc $00                     ; n*4 + n = n*5 (low byte)
    bcc :+
    inc $01
:
    lsr $01
    ror                         ; /2
    lsr $01
    ror                         ; /4
    lsr $01
    ror                         ; /8
    rts

; =============================================================================
; LynxDrawSprite - Render sprite via Suzy engine
; =============================================================================
; Expects SCB_SPRCTL0 through SCB_PALETTE to be filled in.
; Sets VIDBAS to FRAMEBUFFER, points SCBNEXT at our SCB, fires Suzy,
; and waits for completion.
; Clobbers: A
; =============================================================================

LynxDrawSprite:
    ; Note: MAPCTL_SUZY_ON == MAPCTL_NORMAL == $0C, so no toggle needed.

    ; Point Suzy at our SCB
    lda #<SCB_SPRCTL0
    sta SCBNEXTL
    lda #>SCB_SPRCTL0
    sta SCBNEXTH

    ; Enable Suzy bus and start sprite engine
    lda #$01
    sta SUZYBUSEN
    sta SPRGO
    stz SDONEACK                ; Acknowledge any previous sprite-done

    ; Wait for sprite engine to finish
    ; Felix requires CPUSLEEP to yield bus to Suzy, and interrupts
    ; must be enabled for the CPU to wake from CPUSLEEP.
    ; NMI handler saves/restores all registers, so nested IRQs are safe.
    cli                         ; Enable interrupts so CPU can wake from sleep
@wait:
    stz CPUSLEEP                ; Yield bus to Suzy (CPU halts until wake signal)
    lda SPRSYS                  ; CPU wakes here; check status
    lsr                         ; Bit 0 (SPRITEWORKING) → carry
    bcs @wait                   ; Still busy → sleep again
    sei                         ; Restore interrupt mask
    stz SDONEACK                ; Acknowledge sprite-done
    rts

; =============================================================================
; SetupTileSCB - Configure SCB fields common to all BG tile draws
; =============================================================================
; Sets SPRCTL0/1, SPRCOLL, NEXT, HSIZE/VSIZE, pen palette for BG Pal 0.
; Call once before drawing multiple tiles that share the same settings.
; Clobbers: A
; =============================================================================

SetupTileSCB:
    ; SPRCTL0: 1bpp (%00 in bits 7-6), background type 0
    stz SCB_SPRCTL0

    ; SPRCTL1: literal, reload HSIZE/VSIZE
    lda #(LITERAL | REHV)
    sta SCB_SPRCTL1

    ; SPRCOLL: no collision
    stz SCB_SPRCOLL

    ; SCBNEXT: $0000 = last sprite in chain
    stz SCB_NEXT_L
    stz SCB_NEXT_H

    ; HSIZE/VSIZE: 1:1 scale = $0100 (8.8 fixed point)
    ; Sprites are natively 5x4 pixels (pre-scaled in asset pipeline)
    stz SCB_HSIZE_L
    lda #$01
    sta SCB_HSIZE_H
    stz SCB_VSIZE_L
    sta SCB_VSIZE_H

    ; Pen palette from dynamic allocation (BG Palette 0)
    lda DynPenPal0+0
    sta SCB_PALETTE
    lda DynPenPal1+0
    sta SCB_PALETTE+1
    stz SCB_PALETTE+2
    stz SCB_PALETTE+3
    stz SCB_PALETTE+4
    stz SCB_PALETTE+5
    stz SCB_PALETTE+6
    stz SCB_PALETTE+7
    stz TextXPosHi              ; default high byte for text X (no scroll)
    rts

; =============================================================================
; LynxDrawTile - Draw one 5x5 BG tile at (TextXPos, TextYPos)
; =============================================================================
; Input: A = BG tile index (0-255)
; Skips tile $24 (space character)
; Calculates sprite data address as TextTileData + dense_index * 11
; Clobbers: A, X
; =============================================================================

LynxDrawTile:
    cmp #$24                    ; Is this a space tile?
    beq @skip_early             ; Yes, skip rendering

    ; Check for 2bpp tiles (mushroom $CE, copyright $CF)
    cmp #$CE
    beq @jump_2bpp
    cmp #$CF
    bne @not_2bpp
@jump_2bpp:
    jmp @tile_2bpp
@not_2bpp:

    ; Compute dense index inline (replaces 256-byte TextTileIndex table)
    ; Tiles $00-$29: dense index = tile index (identity)
    cmp #$2A
    bcc @have_index             ; A < $2A: use as-is
    ; Sparse tiles: search small table
    ldx #(TextTileSparse_End - TextTileSparse - 1)
@sparse_loop:
    cmp TextTileSparse,x
    beq @sparse_found
    dex
    bpl @sparse_loop
@skip_early:
    rts                         ; Unknown tile or space
@sparse_found:
    txa
    clc
    adc #42                     ; Sparse entries start at dense index 42
@have_index:

    ; Calculate TextTileData + dense_index * 11
    ; idx*11 = (idx*4 + idx) * 2 + idx = idx*10 + idx
    tax                         ; X = idx (preserve original)
    stz TilePtr+1
    asl                         ; A = idx*2
    rol TilePtr+1
    asl                         ; A = idx*4
    rol TilePtr+1
    clc
    stx TilePtr                 ; TilePtr = idx (temp)
    adc TilePtr                 ; A = lo(idx*4 + idx) = lo(idx*5)
    bcc :+
    inc TilePtr+1
:   asl                         ; A = lo(idx*10)
    rol TilePtr+1
    clc
    adc TilePtr                 ; A = lo(idx*10 + idx) = lo(idx*11)
    sta TilePtr
    bcc :+
    inc TilePtr+1
:   ; Add TextTileData base address
    lda TilePtr
    clc
    adc #<TextTileData
    sta SCB_DATA_L
    lda TilePtr+1
    adc #>TextTileData
    sta SCB_DATA_H

    ; Set position from TextXPos/TextYPos
    lda TextXPos
    sta SCB_HPOS_L
    lda TextXPosHi
    sta SCB_HPOS_H
    lda TextYPos
    sta SCB_VPOS_L
    stz SCB_VPOS_H

    ; Render the sprite
    jmp LynxDrawSprite

    ; --- 2bpp tile path for mushroom ($CE) / copyright ($CF) ---
@tile_2bpp:
    sec
    sbc #$CE                    ; A = 0 for $CE, 1 for $CF
    asl                         ; A = 0 or 16 (tile offset * 16)
    asl
    asl
    asl
    clc
    adc #<TextTile2bpp
    sta SCB_DATA_L
    lda #>TextTile2bpp
    adc #0                      ; propagate carry from low byte add
    sta SCB_DATA_H
    lda #(BPP_2 | TYPE_BACKGROUND)  ; SPRCTL0: 2bpp, type 0
    sta SCB_SPRCTL0
    lda #(LITERAL | REHV)       ; SPRCTL1: literal, reload HSIZE/VSIZE
    sta SCB_SPRCTL1
    ; Position
    lda TextXPos
    sta SCB_HPOS_L
    lda TextXPosHi
    sta SCB_HPOS_H
    lda TextYPos
    sta SCB_VPOS_L
    stz SCB_VPOS_H
    jsr LynxDrawSprite
    ; Restore 1bpp mode
    stz SCB_SPRCTL0             ; SPRCTL0: 1bpp, type 0

@skip:
    rts

; =============================================================================
; LynxDrawTextLine - Draw a horizontal string of BG tiles
; =============================================================================
; Input: TextPtr = pointer to tile index array
;        TextXPos = starting X pixel position
;        TextYPos = Y pixel position
;        TextLen = number of characters
; Draws each tile 5 pixels apart (scaled for Lynx 160-wide screen)
; Clobbers: A, X, Y
; =============================================================================

LynxDrawTextLine:
    ; Save ZP $02/$03 and load TextPtr for indirect addressing
    lda $02
    pha
    lda $03
    pha
    lda TextPtr
    sta $02
    lda TextPtr+1
    sta $03
    ldy #0                      ; String index
@loop:
    lda ($02),y                 ; Load tile index via ZP indirect
    phy                         ; Save loop index (65C02)
    jsr LynxDrawTile            ; Draw this tile (may enable IRQs via CPUSLEEP)
    ply                         ; Restore loop index
    ; Reload $02/$03 from safe BSS (NMI may have trashed them during CPUSLEEP)
    lda TextPtr
    sta $02
    lda TextPtr+1
    sta $03
    lda TextXPos
    clc
    adc #NES_TILE_W             ; Advance X by one tile width
    sta TextXPos
    bcc :+
    inc TextXPosHi              ; carry propagation for 16-bit X
:
    iny
    cpy TextLen
    bne @loop
    ; Restore ZP $02/$03
    pla
    sta $03
    pla
    sta $02
    rts

; =============================================================================
; ClearFramebuffer - Clear screen using a 4bpp Suzy sprite stretched to 160x102
; =============================================================================
; Draws a single-pixel 4bpp normal sprite scaled to fill the display.
; Pixel value is pen 0 mapped to palette slot 0 (black).
; Clobbers: A
; =============================================================================

ClearFramebuffer:
    ; SPRCTL0: 4bpp, background type (all pens drawn)
    lda #(BPP_4 | TYPE_BACKGROUND)
    sta SCB_SPRCTL0
    ; SPRCTL1: literal, reload HSIZE/VSIZE
    lda #(LITERAL | REHV)
    sta SCB_SPRCTL1
    stz SCB_SPRCOLL
    stz SCB_NEXT_L
    stz SCB_NEXT_H

    ; Point to single-pixel sprite data (4bpp, pen 0)
    lda #<ClearSpriteData
    sta SCB_DATA_L
    lda #>ClearSpriteData
    sta SCB_DATA_H

    ; Position at (0, 0)
    stz SCB_HPOS_L
    stz SCB_HPOS_H
    stz SCB_VPOS_L
    stz SCB_VPOS_H

    ; Stretch to 160x102 (8.8 fixed point: high byte = pixel size)
    stz SCB_HSIZE_L
    lda #160
    sta SCB_HSIZE_H
    stz SCB_VSIZE_L
    lda #102
    sta SCB_VSIZE_H

    ; All pens → palette slot 0
    stz SCB_PALETTE
    stz SCB_PALETTE+1
    stz SCB_PALETTE+2
    stz SCB_PALETTE+3
    stz SCB_PALETTE+4
    stz SCB_PALETTE+5
    stz SCB_PALETTE+6
    stz SCB_PALETTE+7

    jmp LynxDrawSprite

; =============================================================================
; InitDoubleBuffer - Set up double-buffered framebuffer state
; =============================================================================
; Call once at startup. Starts drawing to FB1 while displaying FB0.
; Clobbers: A
; =============================================================================

InitDoubleBuffer:
.ifdef TILE_5x5
    lda #CAMERA_Y_MAX
    sta CurrentYOffset
    sta TargetYOffset
.endif
    lda #>FRAMEBUFFER_1         ; Start drawing to FB1
    sta DrawBufHi
    stz COLLBASL
    stz COLLBASH
    lda #<FRAMEBUFFER_0
    sta VIDBASL
    lda DrawBufHi
    sta VIDBASH
    rts

; =============================================================================
; SwapBuffers - Flip display to show rendered frame, toggle draw target
; =============================================================================
; Displays what we just rendered (DrawBufHi), then toggles DrawBufHi
; to point at the other buffer for the next frame's rendering.
; Clobbers: A
; =============================================================================

SwapBuffers:

    lda TitleZoomFrame          ; HACK: Skip any drawing until the title screen is ready and visible.
    beq @skip_vsync              
    lda #<FRAMEBUFFER_0         ; Low byte = $20 (from lynx_hw.inc)
    sta DISPADRL
    lda DrawBufHi
    sta DISPADRH
    eor #(>FRAMEBUFFER_0 ^ >FRAMEBUFFER_1)
    sta DrawBufHi
    ; Update Suzy draw target
    lda DrawBufHi
    sta VIDBASH
@skip_vsync:
    rts

MUSHROOM_TILE   = $CE           ; NES tile index for mushroom

; =============================================================================
; LynxDrawTitleElements - Draw title screen logo, text, and mushroom each frame
; =============================================================================
; Called from EndlessLoop when OperMode=0 and ScreenRoutineTask>=12.
; Computes scroll offset from ScreenLeft_X_Pos/ScreenLeft_PageLoc, then draws
; all title elements with scroll-adjusted X positions. This ensures elements
; persist across ClearFramebuffer calls and scroll during demo mode.
;
; Clobbers: A, X, Y, $00, $01
; =============================================================================

LynxDrawTitleElements:
    ; Save ZP $00/$01 (ScaleCoord uses them)
    lda $00
    pha
    lda $01
    pha

    ; --- Compute scroll offset in Lynx pixels ---
    ; TitleScrollLo/Hi = ScaleCoord(ScreenLeft_X_Pos) + PageLoc * 160
    lda ScreenLeft_X_Pos
    jsr ScaleCoord              ; A = scaled X (0-159)
    sta TitleScrollLo
    stz TitleScrollHi

    ; Add PageLoc * 160 (each NES page = 256 NES px → 160 Lynx px)
    lda ScreenLeft_PageLoc
    beq @scroll_done            ; page 0: no page offset
    tax                         ; X = page count
@page_loop:
    lda TitleScrollLo
    clc
    adc #160
    sta TitleScrollLo
    bcc :+
    inc TitleScrollHi
:
    dex
    bne @page_loop
@scroll_done:

    ; Early exit if scroll >= 136 (all title elements off-screen left)
    ; Logo starts at X=25, rightmost text ends around X=135
    lda TitleScrollHi
    bne @early_exit             ; scroll >= 256, definitely off-screen
    lda TitleScrollLo
    cmp #136
    bcc @draw_elements
@early_exit:
    jmp @exit
@draw_elements:

    ; --- Draw logo ---
    ; Reuse SetupTileSCB for common SCB fields, then override for packed 2bpp logo
    jsr SetupTileSCB
    lda #(BPP_2 | TYPE_BACKGROUND)  ; SPRCTL0: 2bpp, type 0 (logo is 2bpp packed)
    sta SCB_SPRCTL0
    lda #(PACKED | REHV)        ; SPRCTL1: packed (not literal), reload HSIZE/VSIZE
    sta SCB_SPRCTL1
    ; Pen palette: BG Palette 1 (logo palette)
    lda DynPenPal0+1
    sta SCB_PALETTE
    lda DynPenPal1+1
    sta SCB_PALETTE+1
    ; Logo sprite data
    lda #<LogoSpriteData
    sta SCB_DATA_L
    lda #>LogoSpriteData
    sta SCB_DATA_H

    ; Logo X (action point is at center, so position = center of logo on screen)
    lda #80                     ; 25 + 110/2 = 80
    sec
    sbc TitleScrollLo
    sta SCB_HPOS_L
    lda #0
    sbc TitleScrollHi
    sta SCB_HPOS_H

.ifdef TILE_5x5
    lda #27                     ; Logo Y (center = 0 + 55/2 = 27)
.else
    lda #26                     ; Logo Y (center = 0 + 44/2 + 4 = 26)
.endif
    sta SCB_VPOS_L
    stz SCB_VPOS_H

    ; --- Zoom animation ---
    lda TitleZoomFrame
    cmp #33
    bcs @zoom_done              ; done, default 1:1 scale is fine

    inc TitleZoomFrame
    ; Scale = frame * 8 → maps 1-32 to $0008-$0100 (8.8 fixed point)
    asl
    asl
    asl
    bcs @zoom_full              ; frame 32: carry means exactly $0100
    sta SCB_HSIZE_L             ; low byte = fractional scale
    stz SCB_HSIZE_H
    sta SCB_VSIZE_L
    stz SCB_VSIZE_H
    jsr LynxDrawSprite
    jmp @exit                   ; skip text/mushroom during zoom
@zoom_full:
    stz SCB_HSIZE_L
    lda #1
    sta SCB_HSIZE_H
    stz SCB_VSIZE_L
    lda #1
    sta SCB_VSIZE_H
@zoom_done:
    jsr LynxDrawSprite

    ; --- Draw title text (table-driven) ---
    jsr SetupTileSCB            ; configure SCB for text tiles (resets TextXPosHi=0)
    ldx #0
@text_loop:
    phx
    lda TitleTextTable,x        ; ptr low
    sta TextPtr
    lda TitleTextTable+1,x      ; ptr high
    sta TextPtr+1
    lda TitleTextTable+2,x      ; base X
    jsr ApplyTitleScrollX
    lda TitleTextTable+3,x      ; Y position
    sta TextYPos
    lda TitleTextTable+4,x      ; string length
    sta TextLen
    jsr LynxDrawTextLine
    plx
    txa
    clc
    adc #TITLE_TEXT_ENTRY
    tax
    cpx #(TITLE_TEXT_COUNT * TITLE_TEXT_ENTRY)
    bne @text_loop

    ; --- Draw mushroom icon ---
    ; Set pen palette to BG Palette 2
    lda DynPenPal0+2
    sta SCB_PALETTE
    lda DynPenPal1+2
    sta SCB_PALETTE+1
    ; Mushroom X = col 9 * 5 = 45, adjusted for scroll
    lda #NES_COL_PX(9)          ; base X = 45
    jsr ApplyTitleScrollX
.ifdef TILE_5x5
    lda #NES_ROW_PX(20)         ; 1P Y position
    ldx NumberOfPlayers
    beq @mush_draw
    lda #NES_ROW_PX(22)         ; 2P Y position
.else
    lda #NES_ROW_PX(18)         ; 1P Y position
    ldx NumberOfPlayers
    beq @mush_draw
    lda #NES_ROW_PX(20)         ; 2P Y position
.endif
@mush_draw:
    sta TextYPos
    lda #MUSHROOM_TILE
    jsr LynxDrawTile
    ; Restore pen palette to BG Palette 0
    lda DynPenPal0+0
    sta SCB_PALETTE
    lda DynPenPal1+0
    sta SCB_PALETTE+1

@exit:
    ; Restore ZP $00/$01
    pla
    sta $01
    pla
    sta $00
    rts

; =============================================================================
; ApplyTitleScrollX - Compute scroll-adjusted X for title element
; =============================================================================
; Input: A = base X position (unsigned)
; Output: TextXPos = A - TitleScrollLo, TextXPosHi = sign extension
; Clobbers: A
; =============================================================================

ApplyTitleScrollX:
    sec
    sbc TitleScrollLo
    sta TextXPos
    lda #0
    sbc TitleScrollHi
    sta TextXPosHi
    rts

; =============================================================================
; LynxRenderIntermediate - Draw "WORLD X-Y" and lives count on interstitial
; =============================================================================
; Reads game state directly (WorldNumber, LevelNumber, NumberofLives) to render
; the interstitial lives screen. Only active during ScreenRoutineTask 6-7
; (after DisplayIntermediate, before AreaParserTaskControl).
;
; Layout (NES grid → Lynx pixels):
;   Row 10, Col 11-15: "WORLD"       → Y=12, X=55
;   Row 10, Col 17:    world digit   → Y=12, X=85
;   Row 10, Col 18:    "-"           → Y=12, X=90
;   Row 10, Col 19:    level digit   → Y=12, X=95
;   Row 14, Col 15:    "×" (cross)   → Y=32, X=75
;   Row 14, Col 18:    lives digit   → Y=32, X=90
;
; Clobbers: A, X, Y
; =============================================================================

LynxRenderIntermediate:
    lda ScreenRoutineTask
    cmp #$06
    bcc @early_out              ; task < 6: not yet at interstitial
    cmp #$08
    bcs @early_out              ; task >= 8: past interstitial
    lda AltEntranceControl
    bne @early_out              ; pipe/vine entry: skip interstitial (matches NES logic)
    lda DisableIntermediate
    bne @early_out              ; NES logic flagged intermediate as skipped (e.g. pipe intro)
    bra @render
@early_out:
    rts
@render:
    jsr SetupTileSCB

    ; --- "WORLD" at row 10, col 11 ---
    lda #<IntermediateWorldText
    sta TextPtr
    lda #>IntermediateWorldText
    sta TextPtr+1
    lda #NES_COL_PX(11)         ; X = 55
    sta TextXPos
    lda #NES_ROW_PX(10)         ; Y = 12
    sta TextYPos
    lda #(IntermediateWorldText_End - IntermediateWorldText)
    sta TextLen
    jsr LynxDrawTextLine

    ; --- World number digit at row 10, col 17 ---
    lda #NES_COL_PX(17)         ; X = 85
    sta TextXPos
    lda #NES_ROW_PX(10)         ; Y = 12
    sta TextYPos
    lda WorldNumber
    clc
    adc #1                      ; world number is 0-based, tile $01 = "1"
    jsr LynxDrawTile

    ; --- "-" at row 10, col 18 ---
    lda #NES_COL_PX(18)         ; X = 90
    sta TextXPos
    lda #$28                    ; tile $28 = "-"
    jsr LynxDrawTile

    ; --- Level number digit at row 10, col 19 ---
    lda #NES_COL_PX(19)         ; X = 95
    sta TextXPos
    lda LevelNumber
    clc
    adc #1                      ; level number is 0-based
    jsr LynxDrawTile

    ; --- "×" (cross) at row 14, col 15 ---
    lda #NES_COL_PX(15)         ; X = 75
    sta TextXPos
    lda #NES_ROW_PX(14)         ; Y = 32
    sta TextYPos
    lda #$29                    ; tile $29 = "×"
    jsr LynxDrawTile

    ; --- Lives count at row 14, col 18 ---
    lda #NES_COL_PX(18)         ; X = 90
    sta TextXPos
    lda NumberofLives
    clc
    adc #1                      ; lives stored as count-1
    jsr LynxDrawTile

    ; --- "TIME UP" at row 16, col 12 (only if timer expired) ---
    lda LynxTimeUpFlag
    beq @done
    lda #<TimeUpText
    sta TextPtr
    lda #>TimeUpText
    sta TextPtr+1
    lda #NES_COL_PX(12)         ; X = 60
    sta TextXPos
    lda #NES_ROW_PX(16)         ; Y = 48
    sta TextYPos
    lda #(TimeUpText_End - TimeUpText)
    sta TextLen
    jsr LynxDrawTextLine

@done:
    rts

; =============================================================================
; LynxRenderGameOver - Draw "GAME OVER" text on black screen
; =============================================================================
; Called from main loop when OperMode == GameOverModeValue.
; Framebuffer is already cleared (black). Only renders after OperMode_Task >= 2
; (RunGameOver phase, after screen setup completes).
;
; Clobbers: A, X, Y
; =============================================================================

LynxRenderGameOver:
    lda OperMode_Task
    cmp #$02
    bcc @go_done
    jsr SetupTileSCB
    lda #<GameOverText
    sta TextPtr
    lda #>GameOverText
    sta TextPtr+1
    lda #NES_COL_PX(11)         ; X = 55
    sta TextXPos
    lda #NES_ROW_PX(16)         ; Y = 48
    sta TextYPos
    lda #(GameOverText_End - GameOverText)
    sta TextLen
    jsr LynxDrawTextLine
@go_done:
    rts

; =============================================================================
; LynxRenderVictory - Draw victory messages over castle background
; =============================================================================
; Called from main loop when OperMode == VictoryModeValue (2).
; Uses VictoryMsgMax shadow variable to track which messages have appeared.
; Re-renders all visible messages every frame (framebuffer is cleared each frame).
;
; Message progression (via VRAM_Buffer_AddrCtrl values):
;   $0C/$0D = "THANK YOU MARIO!/LUIGI!"
;   $0E    = "BUT OUR PRINCESS IS IN" / "ANOTHER CASTLE!" (worlds 1-7)
;   $0F    = "YOUR QUEST IS OVER." (world 8)
;   $10    = "WE PRESENT YOU A NEW QUEST." (world 8)
;   $11    = "PUSH BUTTON B" (world 8)
;   $12    = "TO SELECT A WORLD" (world 8)
;
; Clobbers: A, X, Y
; =============================================================================

LynxRenderVictory:
    lda OperMode_Task
    cmp #$03
    bcs @vic_render
    rts
@vic_render:
    lda VictoryMsgMax
    cmp #$0C
    bcs @has_msgs
    rts                             ; no messages yet
@has_msgs:
    jsr SetupTileSCB

    ; --- "THANK YOU MARIO!" or "THANK YOU LUIGI!" ---
    ; NES messages have 3-byte VRAM header; tile data starts at label+3
    lda CurrentPlayer
    bne @luigi
    lda #<(MarioThanksMessage+3)
    sta TextPtr
    lda #>(MarioThanksMessage+3)
    sta TextPtr+1
    bra @draw_thanks
@luigi:
    lda #<(LuigiThanksMessage+3)
    sta TextPtr
    lda #>(LuigiThanksMessage+3)
    sta TextPtr+1
@draw_thanks:
    lda #VICTORY_THANKS_LEN
    sta TextLen
    lda #40                         ; X = col 8 * 5
    sta TextXPos
.ifdef TILE_5x5
    lda #18                         ; Y = row 10 * 5 - 32
.else
    lda #28                         ; Y = row 10 * 4 - 6
.endif
    sta TextYPos
    jsr LynxDrawTextLine

    ; --- Check for retainer message (worlds 1-7) or princess messages (world 8) ---
    lda VictoryMsgMax
    cmp #$0E
    bcs @check_world
    rts                             ; only "THANK YOU" so far

@check_world:
    lda WorldNumber
    cmp #$07                        ; World8 = 7
    beq @world8_msgs

    ; --- Worlds 1-7: "BUT OUR PRINCESS IS IN" + "ANOTHER CASTLE!" ---
    jsr VicDrawRetainer
    rts                             ; worlds 1-7 done

@world8_msgs:
    ; --- World 8: sequential princess messages ---
    jmp VicDrawWorld8Msgs

; --- Helper: draw retainer messages (worlds 1-7) ---
; MushroomRetainerSaved layout: [3-byte hdr][22 bytes line1][3-byte hdr][15 bytes line2][$00]
VicDrawRetainer:
    lda #<(MushroomRetainerSaved+3)
    sta TextPtr
    lda #>(MushroomRetainerSaved+3)
    sta TextPtr+1
    lda #25                         ; X = col 5 * 5
    sta TextXPos
.ifdef TILE_5x5
    lda #38                         ; Y = row 14 * 5 - 32
.else
    lda #44                         ; Y = row 14 * 4 - 6
.endif
    sta TextYPos
    lda #VICTORY_RET1_LEN
    sta TextLen
    jsr LynxDrawTextLine

    lda #<(MushroomRetainerSaved+VICTORY_RET2_OFS)
    sta TextPtr
    lda #>(MushroomRetainerSaved+VICTORY_RET2_OFS)
    sta TextPtr+1
    lda #25                         ; X = col 5 * 5
    sta TextXPos
.ifdef TILE_5x5
    lda #48                         ; Y = row 16 * 5 - 32
.else
    lda #52                         ; Y = row 16 * 4 - 6
.endif
    sta TextYPos
    lda #VICTORY_RET2_LEN
    sta TextLen
    jmp LynxDrawTextLine

; --- Helper: draw world 8 victory messages progressively ---
VicDrawWorld8Msgs:
    ; --- "YOUR QUEST IS OVER." ---
    lda VictoryMsgMax
    cmp #$0F
    bcs @w8_princess1
    rts
@w8_princess1:
    lda #<(PrincessSaved1+3)
    sta TextPtr
    lda #>(PrincessSaved1+3)
    sta TextPtr+1
    lda #35                         ; X = col 7 * 5
    sta TextXPos
.ifdef TILE_5x5
    lda #33                         ; Y = row 13 * 5 - 32
.else
    lda #40                         ; Y = row 13 * 4 - 6
.endif
    sta TextYPos
    lda #VICTORY_PRIN1_LEN
    sta TextLen
    jsr LynxDrawTextLine

    ; --- "WE PRESENT YOU A NEW QUEST." ---
    lda VictoryMsgMax
    cmp #$10
    bcs @w8_princess2
    rts
@w8_princess2:
    lda #<(PrincessSaved2+3)
    sta TextPtr
    lda #>(PrincessSaved2+3)
    sta TextPtr+1
    lda #15                         ; X = col 3 * 5
    sta TextXPos
.ifdef TILE_5x5
    lda #43                         ; Y = row 15 * 5 - 32
.else
    lda #48                         ; Y = row 15 * 4 - 6
.endif
    sta TextYPos
    lda #VICTORY_PRIN2_LEN
    sta TextLen
    jsr LynxDrawTextLine

    ; --- "PUSH BUTTON B" ---
    lda VictoryMsgMax
    cmp #$11
    bcs @w8_sel1
    rts
@w8_sel1:
    lda #<(WorldSelectMessage1+3)
    sta TextPtr
    lda #>(WorldSelectMessage1+3)
    sta TextPtr+1
    lda #50                         ; X = col 10 * 5
    sta TextXPos
.ifdef TILE_5x5
    lda #58                         ; Y = row 18 * 5 - 32
.else
    lda #60                         ; Y = row 18 * 4 - 6
.endif
    sta TextYPos
    lda #VICTORY_WSEL1_LEN
    sta TextLen
    jsr LynxDrawTextLine

    ; --- "TO SELECT A WORLD" ---
    lda VictoryMsgMax
    cmp #$12
    bcs @w8_sel2
    rts
@w8_sel2:
    lda #<(WorldSelectMessage2+3)
    sta TextPtr
    lda #>(WorldSelectMessage2+3)
    sta TextPtr+1
    lda #40                         ; X = col 8 * 5
    sta TextXPos
.ifdef TILE_5x5
    lda #68                         ; Y = row 20 * 5 - 32
.else
    lda #68                         ; Y = row 20 * 4 - 6
.endif
    sta TextYPos
    lda #VICTORY_WSEL2_LEN
    sta TextLen
    jmp LynxDrawTextLine

; =============================================================================
; LynxRenderHUD - Draw score, coins, world-level, and timer during gameplay
; =============================================================================
; Reads game variables directly and renders as text tiles at Y=0.
; Only active when OperMode == GameModeValue and OperMode_Task >= 3
; (active gameplay, not during interstitial or setup screens).
;
; Layout (single row at Y=0, top of Lynx screen):
;   Score  (X=5):   6 BCD digits from DisplayDigits
;   Coins  (X=45):  "C" + 2 digits from CoinTally
;   World  (X=80):  WorldNumber+1, "-", LevelNumber+1
;   Timer  (X=115): 3 BCD digits from GameTimerDisplay
;
; Clobbers: A, X, Y
; =============================================================================

HUD_VALUE_Y     = 1             ; Values row at top
HUD_PLAYER_X    = 5
HUD_SCORE_X     = 34
HUD_COINS_X     = 74
HUD_WORLD_X     = 106
HUD_TIMER_X     = 135

LynxRenderHUD:
    ;rts                         ; HUD disabled (TODO: re-enable when ready)
    ; Guard: only during active gameplay
    lda OperMode
    cmp #GameModeValue
    beq @mode_ok
    rts
@mode_ok:
    lda OperMode_Task
    cmp #$03
    bcs @task_ok
    rts
@task_ok:

    jsr SetupTileSCB
    lda #(BPP_1 | TYPE_NORMAL)  ; 1bpp, type 4 (pen 0 = transparent)
    sta SCB_SPRCTL0

    ; === Values row (score, coins, world-level, timer) ===
    lda #HUD_VALUE_Y
    sta TextYPos

    ;" MARIO" (or "LUIGI") label above score
    lda #<HUDLabelMario
    sta TextPtr
    lda #>HUDLabelMario
    sta TextPtr+1
    lda #HUD_PLAYER_X
    sta TextXPos
    lda #(HUDLabelMario_End - HUDLabelMario)
    sta TextLen
    jsr LynxDrawTextLine

    ; --- Score: 6 BCD digits from DisplayDigits ---
    lda #HUD_SCORE_X
    sta TextXPos
    lda CurrentPlayer
    beq @p1_score
    ldx #$0C                    ; P2 start offset
    bra @score_loop
@p1_score:
    ldx #$06                    ; P1 start offset
@score_loop:
    lda DisplayDigits,x
    phx
    jsr DrawTileAdvX
    plx
    inx
    txa
    ldy CurrentPlayer
    bne @p2_end
    cmp #$0C
    bne @score_loop
    bra @score_done
@p2_end:
    cmp #$12
    bne @score_loop
@score_done:

    ; --- Coins: coin_icon + "x" + 2 digits from CoinTally ---
    lda #HUD_COINS_X
    sta TextXPos
    ; Switch to BG palette 3 for flashing coin
    lda DynPenPal0+3
    sta SCB_PALETTE
    lda DynPenPal1+3
    sta SCB_PALETTE+1
    lda #$2E                    ; tile: coin icon
    jsr DrawTileAdvX
    ; Restore to BG palette 0
    lda DynPenPal0+0
    sta SCB_PALETTE
    lda DynPenPal1+0
    sta SCB_PALETTE+1
    lda #$29                    ; tile: multiply "x"
    jsr DrawTileAdvX
    lda CoinTally
    ldx #0
@div10:
    cmp #10
    bcc @div10_done
    sbc #10
    inx
    bra @div10
@div10_done:
    pha
    txa
    jsr DrawTileAdvX
    pla
    jsr LynxDrawTile

    ; --- World-Level: digit, "-", digit ---
    lda #HUD_WORLD_X
    sta TextXPos
    lda WorldNumber
    clc
    adc #1
    jsr DrawTileAdvX
    lda #$28                    ; "-"
    jsr DrawTileAdvX
    lda LevelNumber
    clc
    adc #1
    jsr LynxDrawTile

    ; --- Timer: clock icon (2bpp) + 3 BCD digits from GameTimerDisplay ---
    lda #HUD_TIMER_X
    sta TextXPos
    ; Draw 2bpp clock icon: white face (pen 1) + black hands (pen 3)
    ; Use BG palette 2 which has NES $30 (white) as pen 1
    lda DynPenPal0+2
    sta SCB_PALETTE
    lda DynPenPal1+2
    sta SCB_PALETTE+1
    lda #(BPP_2 | TYPE_NORMAL)  ; SPRCTL0: 2bpp, type 4 (pen 0 transparent)
    sta SCB_SPRCTL0
    lda #<ClockTile2bpp
    sta SCB_DATA_L
    lda #>ClockTile2bpp
    sta SCB_DATA_H
    lda TextXPos
    sta SCB_HPOS_L
    stz SCB_HPOS_H
    lda TextYPos
    sta SCB_VPOS_L
    stz SCB_VPOS_H
    jsr LynxDrawSprite
    ; Restore 1bpp mode + BG palette 0 for timer digits
    lda #(BPP_1 | TYPE_NORMAL)  ; 1bpp, type 4
    sta SCB_SPRCTL0
    lda DynPenPal0+0
    sta SCB_PALETTE
    lda DynPenPal1+0
    sta SCB_PALETTE+1
    lda TextXPos
    clc
    adc #(NES_TILE_W + 2)       ; +2px gap after clock icon
    sta TextXPos
    lda GameTimerDisplay
    jsr DrawTileAdvX
    lda GameTimerDisplay+1
    jsr DrawTileAdvX
    lda GameTimerDisplay+2
    jsr LynxDrawTile

@hud_done:
    rts

; Helper: draw tile in A then advance TextXPos by NES_TILE_W
DrawTileAdvX:
    jsr LynxDrawTile
    lda TextXPos
    clc
    adc #NES_TILE_W
    sta TextXPos
    rts

; =============================================================================
; LynxRenderSprites - Scan NES OAM and render visible sprites via Suzy
; =============================================================================
; Reads OAM buffer at $0200-$02FF (64 entries × 4 bytes each).
; For each visible sprite: scales coordinates, looks up tile data from
; SpriteTileData, sets flip bits, and draws via LynxDrawSprite.
;
; OAM entry format: [Y, TileIndex, Attributes, X]
;   Y >= $EF = offscreen (not rendered)
;   Attributes: bit 6 = HFLIP, bit 7 = VFLIP, bits 0-1 = sprite palette
;
; Uses DynPenPal0/1 tables for per-sprite palette from attribute bits 0-1.
; Clobbers: A, X, Y
; =============================================================================

OAM_BASE        = Sprite_Data
SPR_Y_CUTOFF    = $EF           ; NES Y values >= this are offscreen

LynxRenderSprites:
    ; Save ZP $00/$01 (VRAM buffer pointer may live there)
    lda $00
    pha
    lda $01
    pha

    ; Configure SCB for sprite rendering
    ; SPRCTL1: literal, reload HSIZE/VSIZE
    lda #(LITERAL | REHV)
    sta SCB_SPRCTL1
    ; No collision
    stz SCB_SPRCOLL
    ; Last sprite in chain
    stz SCB_NEXT_L
    stz SCB_NEXT_H
    ; 1:1 scale
    stz SCB_HSIZE_L
    stz SCB_VSIZE_L
    lda #$01
    sta SCB_HSIZE_H
    sta SCB_VSIZE_H

    ; Clear unused pen palette bytes (pen palette 0/1 set per-sprite below)
    stz SCB_PALETTE+2
    stz SCB_PALETTE+3
    stz SCB_PALETTE+4
    stz SCB_PALETTE+5
    stz SCB_PALETTE+6
    stz SCB_PALETTE+7

    ; Loop through 64 OAM entries
    stz OAMIndex

@oam_loop:
    ldx OAMIndex

    ; HACK: Checking for oAMIndex >= 4 to skip player sprites during injury flash (see below)
    ; Injury flash: skip player sprites every 2 frames if InjuryTimer active
    ; Has to be done in this code as smb code is out of sync with rendering.
    lda InjuryTimer
    beq @no_injury_flash
    lda RenderBlinkToggle
    and #%00000010
    beq @no_injury_flash
    cpx #4                      ; player OAM starts at index 4
    bcc @no_injury_flash
    cpx #36                     ; player uses 8 sprites = 32 bytes
    bcc @skip_player
@no_injury_flash:

    ; Read Y position (byte 0)
    lda OAM_BASE,x
    cmp #SPR_Y_CUTOFF           ; offscreen?
    bcc :+
@skip_player:
    jmp @next_sprite
:

    ; Check sprite priority against current pass
    pha                         ; save Y position
    lda OAM_BASE+2,x           ; read attributes
    and #$20                    ; isolate bit 5 (priority)
    cmp SprPriorityPass         ; match current pass?
    beq @priority_ok
    pla                         ; discard saved Y
    jmp @next_sprite
@priority_ok:
    pla                         ; restore Y position

.ifdef TILE_5x5
    ; Scale Y: lynx_y = ScaleCoord(nes_y + 1) - CurrentYOffset
    ; NES OAM Y is scanline - 1, so add 1 for true position
    clc
    adc #1
    jsr ScaleCoord              ; floor(n*5/8)
    sec
    sbc CurrentYOffset
    ; Check if on-screen (0-101) or partially visible from top (negative Y)
    cmp #102
    bcc :+                  ; Y 0-101: fully on-screen
    cmp #247                ; Y 247-255 = -9 to -1: partially on-screen (max 5px tile + 4px flip adj)
    bcs :+                  ; Suzy clips the off-screen portion
    jmp @next_sprite        ; Y 102-246: fully off-screen
.else
    ; Scale Y: lynx_y = floor((nes_y + 1) / 2) - LYNX_Y_OFFSET
    ; NES OAM Y is scanline - 1, so add 1 for true position
    ; Y scale is 4/8 = 1/2, so just shift right
    clc
    adc #1
    lsr                         ; floor(n/2) = n*4/8
    sec
    sbc #LYNX_Y_OFFSET
    ; Check if on-screen (0-101) or partially visible from top (negative Y)
    cmp #102
    bcc :+                  ; Y 0-101: fully on-screen
    cmp #248                ; Y 248-255 = -8 to -1: partially on-screen (max 4px tile + 3px flip adj)
    bcs :+                  ; Suzy clips the off-screen portion
    jmp @next_sprite        ; Y 102-247: fully off-screen
.endif
:
    sta SCB_VPOS_L
    stz SCB_VPOS_H
    bmi :+                  ; N=1 from cmp #102 path (Y 0-101): no sign extension
                            ; N=0 from cmp #247 path (Y 247-255): fall through to extend
                            ; (sta/stz don't affect flags on 65C02)
    lda #$FF
    sta SCB_VPOS_H          ; VPOS = negative 16-bit value for Suzy clipping
:

    ; Read X position (byte 3), convert to world coords (screen + HOFF)
    lda OAM_BASE+3,x
    jsr ScaleCoord
    clc
    adc CurrentHOFF             ; screen-relative → world coords (max 159+9=168, fits 8 bits)
    sta SCB_HPOS_L
    stz SCB_HPOS_H

.ifdef TILE_5x5
    ; Read tile index (byte 1), compute SpriteTileData + tile * 16
    lda OAM_BASE+1,x
    ; A * 16 -> TilePtr (16-bit)
    stz TilePtr+1               ; clear high byte
    asl
    rol TilePtr+1
    asl
    rol TilePtr+1
    asl
    rol TilePtr+1
    asl
    rol TilePtr+1
    sta TilePtr                  ; low byte of tile * 16
    ; Add SpriteTileData base
    clc
    adc #<SpriteTileData
    sta SCB_DATA_L
    lda TilePtr+1
    adc #>SpriteTileData
    sta SCB_DATA_H
.else
    ; Read tile index (byte 1), compute SpriteTileData + tile * 13
    ; N*13 = N + N*4 + N*8  (16-bit, N = 0-255, max = 3315)
    ; X = OAM index (preserved), $00 = temp hi byte for shifts
    lda OAM_BASE+1,x            ; A = N (tile index)

    ; Start with TilePtr = N
    sta TilePtr
    stz TilePtr+1

    ; Compute N*4 (16-bit) via shift chain: A:$00
    stz $00
    asl                          ; N*2
    rol $00
    asl                          ; N*4
    rol $00                      ; $00:A = N*4

    ; Add N*4 to TilePtr
    clc
    adc TilePtr
    sta TilePtr
    lda $00
    adc TilePtr+1
    sta TilePtr+1               ; TilePtr = N + N*4 = N*5

    ; Compute N*8 (16-bit): take N*4 from $00:A and shift once more
    ; But we already consumed N*4... reload N and shift 3 times
    lda OAM_BASE+1,x            ; A = N again
    stz $00
    asl                          ; N*2
    rol $00
    asl                          ; N*4
    rol $00
    asl                          ; N*8
    rol $00                      ; $00:A = N*8

    ; Add N*8 to TilePtr
    clc
    adc TilePtr
    sta TilePtr
    lda $00
    adc TilePtr+1
    sta TilePtr+1               ; TilePtr = N + N*4 + N*8 = N*13
    ; Add SpriteTileData base
    lda TilePtr
    clc
    adc #<SpriteTileData
    sta SCB_DATA_L
    lda TilePtr+1
    adc #>SpriteTileData
    sta SCB_DATA_H
.endif

    ; Read attributes (byte 2), extract flip bits
    lda OAM_BASE+2,x
    ; Shift bits 7-6 into bits 1-0 for FlipTable index
    rol                         ; bit 7 -> carry
    rol                         ; carry -> bit 0, bit 6 -> carry
    rol                         ; carry -> bit 0 (now V in bit 1, H in bit 0)
    and #$03
    tay
    lda FlipTable,y
    sta SCB_SPRCTL0

    ; Adjust position for flip (Lynx flips around origin, NES flips in-place)
    ; With origin at (0,0), flipped sprites shift by tile width/height
    tya
    lsr                         ; bit 0 (HFLIP) -> carry
    bcc @no_hadj
    lda SCB_HPOS_L
    clc
    adc #(NES_TILE_W - 1)      ; +4 to compensate for reversed draw direction
    sta SCB_HPOS_L
@no_hadj:
    tya
    and #$02                    ; bit 1 (VFLIP)
    beq @no_vadj
    lda SCB_VPOS_L
    clc
    adc #(NES_TILE_H - 1)      ; +3 to compensate
    sta SCB_VPOS_L
@no_vadj:

    ; Extract sprite palette from attributes (bits 1-0) and apply
    lda OAM_BASE+2,x           ; re-read attribute byte
    and #$03                    ; palette 0-3
    clc
    adc #4                      ; offset to SPR palettes (indices 4-7)
    tay
    lda DynPenPal0,y
    sta SCB_PALETTE
    lda DynPenPal1,y
    sta SCB_PALETTE+1

    ; Render this sprite
    jsr LynxDrawSprite

@next_sprite:
    lda OAMIndex
    clc
    adc #4
    sta OAMIndex
    beq :+
    jmp @oam_loop               ; loops 0,4,8,...,252 then wraps to 0 and exits
:

    ; Restore SCB_SPRCTL0 to BG mode for subsequent tile draws
    lda #(BPP_2 | TYPE_BACKGROUND)
    sta SCB_SPRCTL0

    ; Restore ZP $00/$01
    pla
    sta $01
    pla
    sta $00
    rts

.ifdef TILE_5x5
; UpdateVerticalScroll - Vertical camera for 5x5 mode
; Selectable technique via VSCROLL_xxx define (default: two-position snap).
; Camera holds during pipes, entrance, and death (GameEngineSubroutine guards).
; Lerp: move CurrentYOffset toward TargetYOffset by ±2 per frame.
UpdateVerticalScroll:
    ; Only scroll during gameplay (OperMode=1, task>=3)
    lda OperMode
    cmp #GameModeValue
    bne @use_default
    lda OperMode_Task
    cmp #$03
    bcc @use_default

    ; Water levels: no vertical scrolling
    lda AreaType
    beq @use_default

    ; Skip camera updates during automated sequences (hold current position)
    lda GameEngineSubroutine
    cmp #$02                    ; SideExitPipeEntry
    beq @lerp
    cmp #$03                    ; VerticalPipeEntry
    beq @lerp
    cmp #$06                    ; PlayerLoseLife
    beq @lerp
    cmp #$07                    ; PlayerEntrance
    beq @use_default            ; → snap to ground-level camera on new area
    cmp #$0B                    ; PlayerDeath
    beq @lerp

    ; --- Target selection: chosen at assemble time via VSCROLL_xxx define ---

.ifdef VSCROLL_THREE_POS
    ; Three-position snap: ground (34), mid (24), top (14)
    ; Dead zones prevent oscillation. Velocity gate only on upward camera
    ; to avoid false triggers during jumps. Downward camera follows freely.
    lda Player_Y_HighPos
    beq @want_min               ; above screen → top camera
    cmp #$02
    bcs @lerp                   ; below screen → hold

    lda Player_Y_Position
    cmp #128
    bcs @want_max               ; Y >= 128 → ground
    cmp #104
    bcs @lerp                   ; Y 104-127 → dead zone
    cmp #80
    bcs @want_mid               ; Y 80-103 → mid
    cmp #64
    bcs @lerp                   ; Y 64-79 → dead zone
    bra @want_min               ; Y < 64 → top

@want_mid:
    lda #CAMERA_Y_MID
    sta TargetYOffset
    bra @lerp

@want_max:
    lda #CAMERA_Y_MAX
    sta TargetYOffset
    bra @lerp

@want_min:
    lda Player_Y_Speed
    beq @target_min
    bmi @target_min             ; stationary or moving up → allow
    bra @lerp                   ; moving down → suppress (brief jump)
@target_min:
    lda #CAMERA_Y_MIN
    sta TargetYOffset

.elseif .defined(VSCROLL_TWO_POS)
    ; Two-position snap (CAMERA_Y_MIN / CAMERA_Y_MAX)
    ; Dead zone at NES Y 96-111, velocity gating, lerp
    lda Player_Y_HighPos
    beq @want_min               ; above screen (high byte = 0) → wants camera up
    cmp #$02
    bcs @lerp                   ; below screen (high byte >= 2) → hold current camera

    lda Player_Y_Position       ; reload low byte for threshold checks
    cmp #96
    bcc @want_min               ; Y < 96 (above midpoint) → wants camera up
    cmp #112
    bcs @want_max               ; Y >= 112 (below midpoint) → wants camera down
    bra @lerp                   ; Y 96-111 → dead zone, hold current target

@want_max:
    lda Player_Y_Speed
    bmi @lerp                   ; moving up → suppress downward camera
    lda #CAMERA_Y_MAX
    sta TargetYOffset
    bra @lerp

@want_min:
    lda Player_Y_Speed
    beq @target_min             ; stationary → allow
    bmi @target_min             ; moving up → allow
    bra @lerp                   ; moving down → suppress upward camera
@target_min:
    lda #CAMERA_Y_MIN
    sta TargetYOffset

.else
    ; Default: Platform lock - camera reluctant to move up (requires dwell),
    ; but follows down freely. Three positions: ground/mid/top.
    lda Player_Y_HighPos
    beq @pl_check_up            ; above screen → check upward dwell
    cmp #$02
    bcs @lerp                   ; below screen → hold

    lda Player_Y_Position
    cmp #128
    bcs @pl_want_max            ; Y >= 128 → ground (immediate)
    cmp #96
    bcs @pl_want_mid            ; Y 96-127 → mid (immediate if downward, dwell if upward)
    ; Y < 96 → wants top camera (dwell required)

@pl_check_up:
    ; Upward camera: require player stationary for DWELL_FRAMES
    lda Player_Y_Speed
    bne @pl_clear_dwell         ; moving → not landed, clear counter
    inc VScrollDwell
    lda VScrollDwell
    cmp #DWELL_FRAMES
    bcc @lerp                   ; not enough frames → hold
    lda #CAMERA_Y_MIN
    sta TargetYOffset
    bra @lerp

@pl_want_mid:
    ; Mid camera: immediate if coming from above (downward), dwell if from below (upward)
    lda TargetYOffset
    cmp #CAMERA_Y_MID
    beq @pl_clear_dwell         ; already targeting mid → just clear dwell
    bcc @pl_check_mid_dwell     ; current target < MID (camera is higher) → going down, immediate
    ; current target > MID (camera is lower) → going up, need dwell
    lda Player_Y_Speed
    bne @pl_clear_dwell
    inc VScrollDwell
    lda VScrollDwell
    cmp #DWELL_FRAMES
    bcc @lerp
@pl_check_mid_dwell:
    lda #CAMERA_Y_MID
    sta TargetYOffset
    bra @pl_clear_dwell

@pl_want_max:
    ; Downward to ground: always immediate
    lda #CAMERA_Y_MAX
    sta TargetYOffset

@pl_clear_dwell:
    stz VScrollDwell
.endif
    bra @lerp

@use_default:
    lda #CAMERA_Y_MAX           ; Fixed ground-level framing for all non-gameplay
    sta TargetYOffset
    sta CurrentYOffset
    rts

@lerp:
    lda CurrentYOffset
    cmp TargetYOffset
    beq @done                   ; already at target
    bcc @move_up
    ; current > target -> decrease
    sec
    sbc #2
    cmp TargetYOffset
    bcs :+
    lda TargetYOffset           ; don't overshoot
:   sta CurrentYOffset
    rts
@move_up:
    clc
    adc #2
    cmp TargetYOffset
    bcc :+
    beq :+
    lda TargetYOffset           ; don't overshoot
:   sta CurrentYOffset
@done:
    rts
.endif

; SetScrollHOFF - Compute scroll offset from ScreenLeft_X_Pos and write to Suzy HOFF register.
; Formula: HOFF = (ScreenLeft_X_Pos & $0F) * 5 / 8  (range 0-9 Lynx pixels)
; Suzy offsets all sprite world coordinates by this amount, replacing per-tile subtraction.
; Clobbers: A
SetScrollHOFF:
    lda ScreenLeft_X_Pos
    and #$0F                    ; sub-metatile position (0-15 NES pixels)
    sta CurrentHOFF             ; temp
    asl
    asl                         ; * 4
    clc
    adc CurrentHOFF             ; * 5
    lsr
    lsr
    lsr                         ; / 8 → range 0-9
    sta CurrentHOFF
    ; Write to Suzy hardware
    sta HOFFL
    stz HOFFH
    rts

; ResetHOFF - Set HOFF=0 for screen-fixed elements (HUD, title text).
; Clobbers: A
ResetHOFF:
    stz CurrentHOFF
    stz HOFFL
    stz HOFFH
    rts

; Render the background from render buffers as pre-composited metatile sprites.
; Reads ScreenLeft_X_Pos/PageLoc to determine which columns are visible and
; applies sub-metatile scroll offset. Draws metatile rows 5-12 (the playfield
; below the status bar) as single 10x10 sprites from MetatileTileData.
; Render buffers mirror the block buffers but contain unfiltered metatile data
; (including scenery like clouds, hills, bushes that the block buffer filters out).
LynxRedrawBG:
    ; Save ZP $06/$07 (used as indirect pointer for render buffer)
    lda $06
    pha
    lda $07
    pha

    ; Configure SCB for metatile rendering
    lda #(BPP_2 | TYPE_BACKGROUND)  ; 2bpp, type 0 (background/opaque)
    sta SCB_SPRCTL0
    lda #(LITERAL | REHV)       ; literal, reload HSIZE/VSIZE
    sta SCB_SPRCTL1
    stz SCB_SPRCOLL             ; no collision
    stz SCB_NEXT_L              ; last sprite in chain
    stz SCB_NEXT_H
    stz SCB_HSIZE_L             ; 1:1 scale ($0100 = 8.8 fixed point)
    stz SCB_VSIZE_L
    lda #$01
    sta SCB_HSIZE_H
    sta SCB_VSIZE_H
    ; Clear unused palette bytes
    stz SCB_PALETTE+2
    stz SCB_PALETTE+3
    stz SCB_PALETTE+4
    stz SCB_PALETTE+5
    stz SCB_PALETTE+6
    stz SCB_PALETTE+7

    ; Calculate starting buffer column index
    ; buf_col = (ScreenLeft_PageLoc * 16 + (ScreenLeft_X_Pos >> 4)) & $1F
    lda ScreenLeft_PageLoc
    asl
    asl
    asl
    asl                         ; * 16 (high nybble = page bits)
    sta BGBufIdx
    lda ScreenLeft_X_Pos
    lsr
    lsr
    lsr
    lsr                         ; / 16 (low nybble = column within page)
    ora BGBufIdx                ; combine
    and #$1F                    ; wrap to 32 columns
    sta BGBufIdx

    ; Sub-metatile scroll offset is now handled by Suzy HOFF register
    ; (set by SetScrollHOFF before this function is called)

    ; --- Precompute row Y positions and visibility flags ---
    ldx #0                          ; row counter
@precomp_row:
.ifdef TILE_5x5
    ; Y = (row + 2) * 10 - CurrentYOffset
    txa
    clc
    adc #2
    asl                             ; * 2
    sta BGYPos
    asl                             ; * 4
    asl                             ; * 8
    clc
    adc BGYPos                      ; * 10
    sec
    sbc CurrentYOffset
    sta RowYPos,x
    ; Visible if Y < 102 or Y >= 246
    cmp #102
    bcc @row_vis
    cmp #246
    bcs @row_vis
.else
    ; Y = (row + 2) * 8 - LYNX_Y_OFFSET
    txa
    clc
    adc #2
    asl
    asl
    asl                             ; * 8
    sec
    sbc #LYNX_Y_OFFSET
    sta RowYPos,x
    ; Visible if Y < 102 or Y >= 248
    cmp #102
    bcc @row_vis
    cmp #248
    bcs @row_vis
.endif
    stz RowVisible,x
    bra @row_next
@row_vis:
    lda #1
    sta RowVisible,x
@row_next:
    inx
    cpx #13
    bne @precomp_row

    ; --- Column loop: 17 metatile columns (16 + 1 partial at right edge) ---
    stz BGCol

@col_loop:
    ; Calculate X pixel position: BGCol * 10 (world coords; HOFF handles scroll)
    lda BGCol
    asl                         ; * 2
    sta BGXPos
    asl                         ; * 4
    asl                         ; * 8
    clc
    adc BGXPos                  ; * 10
    sta BGXPos

    ; Compute render buffer base address for this column
    ; Columns 0-15 → Render_Buffer_1+col, 16-31 → Render_Buffer_2+(col&$0F)
    lda BGBufIdx
    cmp #$10
    bcc @rbuf1
    ; Render Buffer 2 (columns 16-31)
    and #$0F
    clc
    adc #<Render_Buffer_2
    sta BGBufPtrL
    sta $06
    lda #>Render_Buffer_2
    adc #0
    sta BGBufPtrH
    sta $07
    bra @rbuf_set
@rbuf1:
    ; Render Buffer 1 (columns 0-15)
    clc
    adc #<Render_Buffer_1
    sta BGBufPtrL
    sta $06
    lda #>Render_Buffer_1
    adc #0
    sta BGBufPtrH
    sta $07
@rbuf_set:

    ; --- Row loop: metatile rows 2-12 (visible rows on Lynx) ---
    stz BGRow

@row_loop:
    ; Check precomputed visibility — skip entire row if off-screen
    ldx BGRow
    lda RowVisible,x
    bne @row_ok
    jmp @next_row
@row_ok:

    ; Reload ZP pointer from safe HIGHDATA copy (NMI may have trashed $06/$07)
    lda BGBufPtrL
    sta $06
    lda BGBufPtrH
    sta $07
    ; Read metatile byte from render buffer
    ; Layout: rows spaced $10 apart, same as block buffer
    lda BGRow
    asl
    asl
    asl
    asl                         ; row * 16
    tay
    lda ($06),y                 ; read metatile byte from render buffer

    ; Skip if zero (sky/blank) — but on water levels, fill with water metatile
    bne @not_blank
    lda AreaType
    bne @skip_blank           ; non-water: skip as before
    lda #$87                  ; water: substitute water metatile
    bra @not_blank
@skip_blank:
    jmp @next_row
@not_blank:
    sta BGMetaByte

    ; Use precomputed Y position (visibility already checked at row_loop entry)
    ldx BGRow
    lda RowYPos,x
    sta BGYPos

    ; Look up dense index from metatile index table
    ldx BGMetaByte
    lda MetatileIndex,x         ; dense index ($FF = undefined)
    cmp #$FF
    bne @has_metatile
    jmp @next_row               ; skip undefined metatiles
@has_metatile:
    tax                         ; X = dense index (0-100)

    ; Extract palette from original metatile byte (bits 7-6 → 0-3)
    lda BGMetaByte
    and #$C0
    asl
    rol
    rol
    tay                         ; Y = palette index (0-3)

    ; Set pen palette for this metatile's palette
    lda DynPenPal0,y
    sta SCB_PALETTE
    lda DynPenPal1,y
    sta SCB_PALETTE+1

.ifdef TILE_5x5
    ; Compute MetatileTileData + X * 41 (X = dense index, max 100)
    ; N*41 = (N*5) * 8 + N; all shifts done 16-bit to avoid overflow
    stx MetaAddrLo                  ; MetaAddrLo:Hi = N (16-bit)
    stz MetaAddrHi
    ; N*4 (16-bit shift)
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*2
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*4
    ; + N = N*5
    txa
    clc
    adc MetaAddrLo
    sta MetaAddrLo
    bcc :+
    inc MetaAddrHi
:
    ; (N*5) * 8 = N*40
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*10
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*20
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*40
    ; + N = N*41
    txa
    clc
    adc MetaAddrLo
    sta MetaAddrLo
    bcc :+
    inc MetaAddrHi
:
.else
    ; Compute MetatileTileData + X * 33 (X = dense index)
    ; N*33 = N*32 + N
    stx MetaAddrLo
    stz MetaAddrHi
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*2
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*4
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*8
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*16
    asl MetaAddrLo
    rol MetaAddrHi                  ; N*32
    txa
    clc
    adc MetaAddrLo
    sta MetaAddrLo
    bcc :+
    inc MetaAddrHi
:
.endif
    ; Add MetatileTileData base address
    lda MetaAddrLo
    clc
    adc #<MetatileTileData
    sta SCB_DATA_L
    lda MetaAddrHi
    adc #>MetatileTileData
    sta SCB_DATA_H

    ; Set position
    lda BGXPos
    sta SCB_HPOS_L
    stz SCB_HPOS_H                  ; BGXPosHi is always 0 in world coords
    lda BGYPos
    sta SCB_VPOS_L
    stz SCB_VPOS_H
.ifdef TILE_5x5
    cmp #246                    ; sign-extend if negative (>= 246 unsigned)
.else
    cmp #248                    ; sign-extend if negative (>= 248 unsigned)
.endif
    bcc :+
    lda #$FF
    sta SCB_VPOS_H
:

    ; Render the metatile sprite
    jsr LynxDrawSprite

@next_row:
    inc BGRow
    lda BGRow
    cmp #13                     ; rows 5-12 (8 metatile rows)
    beq @rows_done
    jmp @row_loop
@rows_done:

    ; Advance to next buffer column (wrapping at 32)
    lda BGBufIdx
    clc
    adc #1
    and #$1F
    sta BGBufIdx

    inc BGCol
    lda BGCol
    cmp #17                     ; 17 columns (extra for partial scroll)
    beq @cols_done
    jmp @col_loop
@cols_done:

    ; Restore ZP $06/$07
    pla
    sta $07
    pla
    sta $06
    rts
