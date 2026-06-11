; =============================================================================
; LYNX_AUDIO.S - NES-to-Lynx audio translation layer
; =============================================================================
; Reads BSS shadow registers (SND_REGISTER[16], SND_MASTERCTRL_REG) written
; by SMB's sound engine, and drives Lynx Mikey audio channels AUD0-AUD3.
;
; Channel mapping:
;   NES Square 1  → Lynx AUD0 ($FD20)  FEED=$01 (square wave)
;   NES Square 2  → Lynx AUD1 ($FD28)  FEED=$01 (square wave)
;   NES Triangle  → Lynx AUD2 ($FD30)  FEED=$01 (square wave, fixed vol)
;   NES Noise     → Lynx AUD3 ($FD38)  FEED=$AE/$41 (long/short noise)
;
; FreqRegLookupTbl in smb_lynx.s already contains Lynx (CTLA, BKUP) pairs.
; SND_REGISTER+2/+3 hold BKUP/CTLA for each channel after Dump_Freq_Regs.
; =============================================================================

.pc02
.feature c_comments

; =============================================================================
; EXPORTS / IMPORTS
; =============================================================================

.export SyncLynxAudio
.export InitLynxAudio

.import SND_REGISTER
.import SND_MASTERCTRL_REG

; =============================================================================
; Lynx Hardware Registers + Shared Constants
; =============================================================================

.include "lynx_hw.inc"

; NES SND_REGISTER offsets for each channel:
;   Square 1: +0 (vol), +1 (sweep), +2 (BKUP), +3 (CTLA)
;   Square 2: +4 (vol), +5 (sweep), +6 (BKUP), +7 (CTLA)
;   Triangle: +8 (control), +10 (BKUP), +11 (CTLA)
;   Noise:    +12 (vol), +14 (period/mode)

; =============================================================================
; BSS
; =============================================================================

.segment "HIGHDATA"

SweepDiv:       .res 8          ; Sweep divider counter per channel (indexed by X: 0=sq1, 4=sq2)
EnvVolume:      .res 8          ; Envelope decay level (0-15), indexed by X (0=sq1, 4=sq2)
EnvDivider:     .res 8          ; Envelope divider counter, indexed by X
PrevCtrlReg:    .res 5          ; Previous control reg value for retrigger detection (X=0,4)

; =============================================================================
; CODE
; =============================================================================

.segment "CODE"

; -----------------------------------------------------------------------------
; InitLynxAudio - Initialize Lynx audio hardware
; Called once from lynx_startup.s before game starts.
; Clobbers: A
; -----------------------------------------------------------------------------

InitLynxAudio:
        ; Set FEED for square wave channels
        lda     #FEED_SQUARE
        sta     AUD0FEED        ; AUD0: square wave
        sta     AUD1FEED        ; AUD1: square wave
        sta     AUD2FEED        ; AUD2: square wave (triangle approx)
        ; Noise defaults to long noise
        lda     #FEED_NOISE_LONG
        sta     AUD3FEED        ; AUD3: long noise

        ; Enable all channels on both stereo sides
        ; MSTEREO uses inverted logic: 1=muted, 0=enabled
        stz     MSTEREO

        ; Silence all channels
        stz     AUD0VOL
        stz     AUD1VOL
        stz     AUD2VOL
        stz     AUD3VOL
        rts

; -----------------------------------------------------------------------------
; SyncLynxAudio - Copy BSS shadow state to Lynx audio hardware
; Called once per frame after SoundEngine in the NMI handler.
; Reads SND_REGISTER[0..15] and SND_MASTERCTRL_REG.
; Clobbers: A, X, Y
; -----------------------------------------------------------------------------

SyncLynxAudio:
        ; Check if sound is globally disabled
        lda     SND_MASTERCTRL_REG
        beq     @silence

        ; --- Square 1 → AUD0 ---
        ldx     #$00            ; SND_REGISTER offset for Square 1
        ldy     #$20            ; AUD register offset ($FD20)
        jsr     SyncSquareCh

        ; --- Square 2 → AUD1 ---
        ldx     #$04            ; SND_REGISTER offset for Square 2
        ldy     #$28            ; AUD register offset ($FD28)
        jsr     SyncSquareCh

        ; --- Triangle → AUD2 ---
        stz     AUD2VOL         ; default: silent
        lda     SND_REGISTER+8  ; SND_TRIANGLE_REG (linear counter)
        beq     @tri_freq       ; already zero → stays silent
        bmi     @tri_on         ; bit 7 set ($FF) → halted, don't decrement
        sec
        sbc     #4              ; NES linear counter clocks at 240Hz (4× per frame)
        bcs     @tri_store
        lda     #0              ; clamp to zero on underflow
@tri_store:
        sta     SND_REGISTER+8
        beq     @tri_freq       ; just expired → remain silent this frame
@tri_on:
        lda     #$40            ; fixed volume when triangle active
        sta     AUD2VOL
@tri_freq:
        lda     SND_REGISTER+10 ; BKUP from Dump_Freq_Regs
        sta     AUD2BKUP
        lda     SND_REGISTER+11 ; CTLA from Dump_Freq_Regs
        inc                     ; drop one octave: NES triangle divides by 32 vs 16
        sta     AUD2CTLA

        ; --- Noise → AUD3 ---
        lda     SND_REGISTER+12 ; SND_NOISE_REG (vol/envelope)
        and     #$0F            ; extract 4-bit volume
        asl
        asl
        asl                     ; ×8 → Lynx 8-bit volume (0-120)
        sta     AUD3VOL

        ; Noise period: SND_REGISTER+14 bits 3-0 = index, bit 7 = mode
        lda     SND_REGISTER+14
        tax                     ; save for mode check
        and     #$0F            ; period index 0-15
        asl                     ; ×2 for table offset
        tay
        lda     NoisePeriodTable+1,y
        sta     AUD3BKUP
        lda     NoisePeriodTable,y
        sta     AUD3CTLA
        txa                     ; restore mode byte
        bmi     @short_noise    ; bit 7 set = short noise
        lda     #FEED_NOISE_LONG  ; long noise LFSR
        bra     @set_feed
@short_noise:
        lda     #FEED_NOISE_SHORT ; short noise LFSR
@set_feed:
        sta     AUD3FEED
        rts

@silence:
        stz     AUD0VOL
        stz     AUD1VOL
        stz     AUD2VOL
        stz     AUD3VOL
        rts

; -----------------------------------------------------------------------------
; SyncSquareCh - Sync one square wave channel
; Input: X = SND_REGISTER offset (0 or 4)
;        Y = AUD register offset from $FD00 ($20 or $28)
; Clobbers: A
; -----------------------------------------------------------------------------

SyncSquareCh:
        lda     SND_REGISTER,x  ; NES vol/duty/envelope register
        beq     @silence        ; ctrl=0 → channel silenced
        bit     #$10            ; bit 4: constant volume flag
        bne     @const_vol      ; bit 4 set → use raw bits 0-3 (music + const-vol SFX)
        ; --- Envelope mode (bit 4 clear): SFX like coin, jump ---
        ; SMB music never reaches here — LoadEnvelopeData overwrites ctrl every
        ; frame with values that have bit 4 set ($90, $94, $95...).
        cmp     PrevCtrlReg,x   ; ctrl changed? (new SFX trigger)
        beq     @decay          ; unchanged → continue envelope decay
        ; New envelope trigger: restart at max volume
        sta     PrevCtrlReg,x
        and     #$0F            ; period P
        sta     EnvDivider,x    ; load divider
        lda     #15
        sta     EnvVolume,x     ; start at max
        bra     @env_out
@decay:
        ; Clock 4 quarter-frame ticks (NES APU clocks envelope at 240Hz)
        phy                     ; save AUD register offset
        ldy     #4              ; 4 clocks per frame
@clock: lda     EnvDivider,x
        bne     @env_tick
        ; Divider hit 0 — fire: reload and decrement volume
        lda     SND_REGISTER,x
        and     #$0F            ; period P
        sta     EnvDivider,x    ; reload
        lda     EnvVolume,x
        beq     @env_next       ; already 0 → clamp
        dec     EnvVolume,x
        bra     @env_next
@env_tick:
        dec     EnvDivider,x
@env_next:
        dey
        bne     @clock
        ply                     ; restore AUD offset
@env_out:
        lda     EnvVolume,x     ; use envelope volume
        bra     @set_vol
@silence:
        stz     PrevCtrlReg,x   ; ensure next sound triggers restart
        stz     EnvVolume,x     ; clear stale state
        bra     @set_vol        ; A=0
@const_vol:
        sta     PrevCtrlReg,x   ; track for envelope retrigger detection
        and     #$0F            ; raw 4-bit volume
@set_vol:
        asl
        asl
        asl                     ; ×8 → Lynx 8-bit volume (0-120)
        sta     $FD00,y         ; AUD VOL (offset +0)
        ; --- Software sweep emulation ---
        ; NES sweep: bit7=enable, bits6-4=period P, bit3=negate, bits2-0=shift S
        ; Divider clocks every (P+1) frames; delta = BKUP >> S
        lda     SND_REGISTER+1,x ; sweep register ($4001/$4005)
        bpl     @load_freq      ; bit 7 clear → sweep disabled
        ; Clock the sweep divider
        lda     SweepDiv,x
        bne     @dec_div        ; divider not yet expired
        ; Divider expired — reload and apply sweep
        lda     SND_REGISTER+1,x
        lsr
        lsr
        lsr
        lsr
        and     #$07            ; period P
        sta     SweepDiv,x      ; reload counter (will count P more frames)
        ; Compute delta = BKUP >> shift_count
        lda     SND_REGISTER+1,x
        and     #$07            ; shift count S
        beq     @load_freq      ; S=0 → no pitch change
        phy                     ; save AUD register offset
        tay                     ; Y = shift count
        lda     SND_REGISTER+2,x ; current BKUP
@shlp:  lsr
        dey
        bne     @shlp           ; A = BKUP >> S = delta
        ply                     ; restore AUD offset
        ; Apply direction
        pha                     ; save delta
        lda     SND_REGISTER+1,x
        and     #$08            ; negate bit
        cmp     #$01            ; C=1 if negate ($08≥$01), C=0 if add ($00<$01)
        pla                     ; restore delta (PLA preserves carry)
        bcc     @add            ; C=0 → add mode (pitch down)
        eor     #$FF
        inc                     ; two's complement negate (pitch up)
@add:   clc
        adc     SND_REGISTER+2,x ; BKUP ± delta
        sta     SND_REGISTER+2,x
        bra     @load_freq
@dec_div:
        dec     SweepDiv,x      ; count down divider
@load_freq:
        lda     SND_REGISTER+2,x ; BKUP (possibly sweep-modified)
        sta     $FD04,y         ; AUD BKUP (offset +4)
        lda     SND_REGISTER+3,x ; CTLA
        sta     $FD05,y         ; AUD CTLA (offset +5)
        rts

; =============================================================================
; RODATA
; =============================================================================

.rodata

; NoisePeriodTable - Lynx (CTLA, BKUP) pairs for 16 NES noise periods
; Maps NES noise period index (0-15) to Lynx timer settings.
; NES noise rate = 1,789,773 / period; Lynx rate = clock / (BKUP+1)
NoisePeriodTable:
      .byte $18, $01, $18, $04, $18, $08, $18, $11
      .byte $18, $23, $18, $35, $18, $47, $18, $58
      .byte $18, $70, $18, $8d, $18, $d3, $19, $8d
      .byte $19, $d4, $1a, $8d, $1b, $8d, $1c, $8d
