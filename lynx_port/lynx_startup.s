; =============================================================================
; LYNX_STARTUP.S - Lynx hardware init + bridge to SMB game code
; =============================================================================
; Initializes Lynx hardware, sets up TIM2 (VBlank) IRQ to drive the SMB
; game loop via NonMaskableInterrupt, then jumps to SMB's Start entry point.
; =============================================================================

.pc02
.feature c_comments
.feature org_per_seg

; =============================================================================
; EXPORTS / IMPORTS
; =============================================================================

.export __STARTUP__: absolute = 1       ; Prevents cc65 crt0.o from linking

.import Start                           ; SMB entry point
.import NonMaskableInterrupt            ; SMB NMI handler (game loop)
.import InitDoubleBuffer                ; Double buffer init
.import SwapBuffers                     ; Buffer swap
.import InitLynxAudio                   ; Audio hardware init
.import NesPaletteShadow                ; NES palette shadow (32 bytes in BSS)
.import PPU_STATUS                      ; NES PPU status shadow (BSS in smb_lynx.s)

; =============================================================================
; LYNX HARDWARE DEFINES
; =============================================================================

.include "lynx_hw.inc"
DISP_COLOR      = $08
DISP_FOURBIT    = $04
DMA_ENABLE      = $01

; =============================================================================
; STARTUP SEGMENT
; =============================================================================

.segment "STARTUP"

; =============================================================================
; Entry Point - Called by cc65 boot loader after it loads code to RAM
; =============================================================================

startup:
        sei                     ; Disable interrupts during init
        cld                     ; Clear decimal mode
        ldx     #$FF
        txs                     ; Initialize stack pointer

        ; Enable Mikey + Suzy I/O space for hardware initialization
        ; (Suzy registers at $FC00-$FCFF must be hardware during Suzy init below)
        lda     #MAPCTL_SUZY_ON
        sta     MAPCTL

        ; Disable all timer interrupts
        lda     #ENABLE_INT
        trb     TIM0CTLA
        trb     TIM1CTLA
        trb     TIM2CTLA
        trb     TIM3CTLA
        trb     TIM5CTLA
        trb     TIM6CTLA
        trb     TIM7CTLA

        ; Set ComLynx to open collector
        lda     #(PAREN | RESETERR | TXOPEN | PAREVEN)
        sta     SERCTL

        ; Clear pending interrupts
        lda     INTSET
        sta     INTRST

        ; Initialize display timers
        lda     #$9E            ; Horizontal timer backup
        sta     TIM0BKUP
        lda     #(ENABLE_RELOAD | ENABLE_COUNT)
        sta     TIM0CTLA
        lda     #$68            ; Vertical blank timer backup
        sta     TIM2BKUP
        lda     #(ENABLE_INT | ENABLE_RELOAD | ENABLE_COUNT | AUD_LINKING)
        sta     TIM2CTLA

        ; Set palette backup timing
        lda     #$29
        sta     PBKUP

        ; Initialize display buffer address (start showing FB0)
        lda     #<FRAMEBUFFER_0
        sta     DISPADRL
        lda     #>FRAMEBUFFER_0
        sta     DISPADRH

        ; Initialize Suzy video buffer address (prevents garbage if Suzy
        ; fires before first LynxDrawSprite sets this properly)
        lda     #<FRAMEBUFFER_0
        sta     VIDBASL
        lda     #>FRAMEBUFFER_0
        sta     VIDBASH

        ; Set display control: color, 4-bit, DMA enabled
        lda     #(DISP_COLOR | DISP_FOURBIT | DMA_ENABLE)
        sta     DISPCTL

        ; Initialize I/O
        lda     #(AUDIN_BIT | RESTLESS | CART_ADDR_DATA)
        sta     IODIR
        lda     #CART_ADDR_DATA
        sta     IODAT

        ; Initialize Suzy
        lda     #$01
        sta     SUZYBUSEN       ; Enable Suzy bus
        lda     #(NO_COLLIDE | CLR_UNSAFE)
        sta     SPRSYS
        lda     #$F3
        sta     SPRINIT

        ; Initialize sprite size offsets
        lda     #$7F
        sta     HSIZOFFL
        sta     VSIZOFFL
        lda     #$00
        sta     HSIZOFFH
        sta     VSIZOFFH
        sta     HOFFL
        sta     HOFFH
        sta     VOFFL
        sta     VOFFH

        ; Suzy hardware init complete - remap Suzy space to RAM
        ; LynxDrawSprite will toggle back to MAPCTL_SUZY_ON when it needs HW access
        lda     #MAPCTL_NORMAL
        sta     MAPCTL

        ; Pre-fill PPU_STATUS with VBlank + Sprite0 flags set
        ; so SMB's VBlank polling loops at Start pass immediately
        lda     #(NES_VBLANK_FLAG | NES_SPRITE0_FLAG)
        sta     PPU_STATUS

        ; Clear both framebuffers ($BC20-$FBFF) to avoid garbage on first frame.
        ; 63 pages ($3F × 256 = 16,128 bytes): from $BC20 covers to $FB1F.
        lda     #<FRAMEBUFFER_0
        sta     $00
        lda     #>FRAMEBUFFER_0
        sta     $01
        lda     #$00
        ldy     #$00
        ldx     #$3F            ; 63 pages = 16,128 bytes ($BC20-$FB1F)
@clr_fb:
        sta     ($00),y
        iny
        bne     @clr_fb
        inc     $01
        dex
        bne     @clr_fb
        ; Clear remaining tail of FB1 ($FB20-$FBFF, 224 bytes) that the
        ; page loop couldn't reach without hitting Suzy registers at $FC00.
        ldy     #$00
@clr_tail:
        sta     $FB20,y
        iny
        cpy     #$E0            ; 224 bytes ($FB20-$FBFF)
        bne     @clr_tail

        ; Initialize double buffer state then swap once so that:
        ;   - Display shows FB1 (fully cleared above, safe to show)
        ;   - DrawBufHi targets FB0 (first render clears+draws here)
        ; This prevents the user from seeing FB0 before it's fully rendered,
        ; since FB0 won't be displayed until after the first ClearFramebuffer
        ; + render + SwapBuffers cycle in EndlessLoop.
        jsr     InitDoubleBuffer
        jsr     SwapBuffers

        ; Initialize Lynx audio hardware (FEED, MSTEREO, silence all)
        jsr     InitLynxAudio

        ; Pre-populate NES palette shadow RAM with ground/overworld palette
        ; This is needed because the NES PPU auto-increment mechanism doesn't exist
        ; on Lynx, so VRAM buffer writes to PPU_DATA don't reach palette RAM.
        ; Values from GroundPaletteData in smb.asm:
        ;   BG Pal 0: $0f,$29,$1a,$0f  BG Pal 1: $0f,$36,$17,$0f
        ;   BG Pal 2: $0f,$30,$21,$0f  BG Pal 3: $0f,$27,$17,$0f
        ;   SPR Pal 0: $0f,$16,$27,$18 SPR Pal 1: $0f,$1a,$30,$27
        ;   SPR Pal 2: $0f,$16,$30,$27 SPR Pal 3: $0f,$0f,$36,$17
        ldx     #$00
@pal_init:
        lda     InitPaletteData,x
        sta     NesPaletteShadow,x
        inx
        cpx     #$20
        bne     @pal_init

        ; Write IRQ vector to RAM at $FFFE/$FFFF
        ; MAPCTL B3=1 (set after Suzy init, preserved through clear loop) ensures
        ; these writes reach RAM vector space, not Mikey ROM
        lda     #<irq_handler
        sta     $FFFE
        lda     #>irq_handler
        sta     $FFFF

        ; Jump to SMB Start (interrupts still disabled;
        ; SMB's code enables them with CLI before EndlessLoop)
        jmp     Start

; =============================================================================
; IRQ Handler - Routes Lynx TIM2 VBlank IRQ to SMB's NMI handler
; =============================================================================

irq_handler:
        pha                     ; Save A (clobbered by IRQ acknowledge below)
        lda     INTSET          ; Read pending interrupt flags
        sta     INTRST          ; Acknowledge all pending interrupts
        lda     #(NES_VBLANK_FLAG | NES_SPRITE0_FLAG)
        sta     PPU_STATUS      ; Refresh fake PPU_STATUS flags for next frame
        pla                     ; Restore A before entering NMI
        jmp     NonMaskableInterrupt  ; NMI saves/restores all regs; ends with RTI

; =============================================================================
; RODATA - Initial NES palette for title screen (ground/overworld)
; =============================================================================

.rodata

; NES PPU palette layout: 32 bytes at $3F00-$3F1F
; $3F00: BG color, $3F01-03: BG Pal 0, $3F04: mirror, $3F05-07: BG Pal 1
; $3F08: mirror, $3F09-0B: BG Pal 2, $3F0C: mirror, $3F0D-0F: BG Pal 3
; $3F10: mirror, $3F11-13: SPR Pal 0, $3F14: mirror, $3F15-17: SPR Pal 1
; $3F18: mirror, $3F19-1B: SPR Pal 2, $3F1C: mirror, $3F1D-1F: SPR Pal 3
InitPaletteData:
    .byte $0f, $29, $1a, $0f    ; BG color ($0F=black) + BG Pal 0
    .byte $0f, $36, $17, $0f    ; BG Pal 1
    .byte $0f, $30, $21, $0f    ; BG Pal 2 (mushroom uses this: black, white, blue, black)
    .byte $0f, $27, $17, $0f    ; BG Pal 3
    .byte $0f, $16, $27, $18    ; SPR Pal 0 (Mario colors)
    .byte $0f, $1a, $30, $27    ; SPR Pal 1
    .byte $0f, $16, $30, $27    ; SPR Pal 2
    .byte $0f, $0f, $36, $17    ; SPR Pal 3
