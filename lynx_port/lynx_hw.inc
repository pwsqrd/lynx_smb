; =============================================================================
; LYNX_HW.INC - Shared hardware constants for Lynx port
; =============================================================================
; Framebuffer addresses: auto-placed by linker after BSS (see lynx_port.cfg).
; Linker assertion enforces BSS stays below $BC20.
; FB0=$BC20, FB1=$DC20, each $1FE0 bytes (160×102 at 4bpp).
; =============================================================================

FRAMEBUFFER_0   = $BC20         ; Framebuffer 0 (linker auto-places FRAMEBUF0 here)
FRAMEBUFFER_1   = $DC20         ; Framebuffer 1 (linker auto-places FRAMEBUF1 here)

; Memory Map Control register ($FFF9) - always hardware, cannot be remapped
MAPCTL          = $FFF9

; MAPCTL values:
;   B3=1 (VECTOR_SPACE): $FFFA-$FFFF → RAM (6502 vectors)
;   B2=1 (ROM_SPACE):    $FE00-$FFF7 → RAM (512B HIGHRAM region)
;   B0=1 (SUZY_SPACE):   $FC00-$FCFF → RAM (reclaimed between renders)
;
; MAPCTL_NORMAL: default runtime state - Suzy stays hardware (joystick at $FCB0 readable)
; MAPCTL_SUZY_ON: same value; kept as alias for LynxDrawSprite toggle clarity
MAPCTL_NORMAL   = $0C   ; B3+B2: vectors+ROM → RAM, Suzy = hardware (always)
MAPCTL_SUZY_ON  = $0C   ; same as MAPCTL_NORMAL (Suzy always hardware)

; Mikey sprite-done / CPU sleep registers
SDONEACK        = $FD90 ; Sprite-done acknowledge (write to enable/clear wake signal)
CPUSLEEP        = $FD91 ; CPU sleep (write to halt CPU and release bus to Suzy)

; --- Suzy (Graphics) Registers ($FC00-$FCFF) ---
HOFFL           = $FC04
HOFFH           = $FC05
VOFFL           = $FC06
VOFFH           = $FC07
VIDBASL         = $FC08
VIDBASH         = $FC09
COLLBASL        = $FC0A
COLLBASH        = $FC0B
SCBNEXTL        = $FC10
SCBNEXTH        = $FC11
HSIZOFFL        = $FC28
HSIZOFFH        = $FC29
VSIZOFFL        = $FC2A
VSIZOFFH        = $FC2B
SPRINIT         = $FC83
SUZYBUSEN       = $FC90
SPRGO           = $FC91
SPRSYS          = $FC92
JOYSTICK        = $FCB0

; --- Mikey Timer Registers ($FD00-$FD1F) ---
TIM0BKUP        = $FD00
TIM0CTLA        = $FD01
TIM1CTLA        = $FD05
TIM2BKUP        = $FD08
TIM2CTLA        = $FD09
TIM3CTLA        = $FD0D
TIM5CTLA        = $FD15
TIM6CTLA        = $FD19
TIM7CTLA        = $FD1D

; --- Mikey Audio Registers ($FD20-$FD50) ---
AUD0VOL         = $FD20
AUD0FEED        = $FD21
AUD0BKUP        = $FD24
AUD0CTLA        = $FD25
AUD1VOL         = $FD28
AUD1FEED        = $FD29
AUD1BKUP        = $FD2C
AUD1CTLA        = $FD2D
AUD2VOL         = $FD30
AUD2FEED        = $FD31
AUD2BKUP        = $FD34
AUD2CTLA        = $FD35
AUD3VOL         = $FD38
AUD3FEED        = $FD39
AUD3BKUP        = $FD3C
AUD3CTLA        = $FD3D
MSTEREO         = $FD50

; --- Mikey System Registers ($FD80-$FDB0) ---
INTRST          = $FD80
INTSET          = $FD81
IODIR           = $FD8A
IODAT           = $FD8B
SERCTL          = $FD8C
DISPCTL         = $FD92
PBKUP           = $FD93
DISPADRL        = $FD94
DISPADRH        = $FD95
GCOLMAP         = $FDA0
RBCOLMAP        = $FDB0

; --- Sprite Control 0 (SPRCTL0) flags ---
BPP_1            = %00000000
BPP_2            = %01000000
BPP_3            = %10000000
BPP_4            = %11000000
HFLIP            = %00100000
VFLIP            = %00010000
TYPE_BACKGROUND  = %00000000
TYPE_BACKNONCOLL = %00000001
TYPE_BSHADOW     = %00000010
TYPE_BOUNDARY    = %00000011
TYPE_NORMAL      = %00000100
TYPE_NONCOLL     = %00000101

; --- Sprite Control 1 (SPRCTL1) flags ---
LITERAL          = %10000000
PACKED           = %00000000
REHV             = %00010000
REHVS            = %00100000
REHVST           = %00110000
REUSEPAL         = %00001000

; --- Sprite System (SPRSYS) write flags ---
NO_COLLIDE       = %00100000
CLR_UNSAFE       = %00000100

; --- SPRGO flags ---
SPRITE_GO        = %00000001

; --- Timer Control A flags ---
ENABLE_INT       = %10000000
RESET_DONE       = %01000000
ENABLE_RELOAD    = %00010000
ENABLE_COUNT     = %00001000
AUD_LINKING      = %00000111

; --- SERCTL write flags ---
PAREN            = %00010000
RESETERR         = %00001000
TXOPEN           = %00000100
PAREVEN          = %00000001

; --- IODIR/IODAT bit flags ---
AUDIN_BIT        = %00010000
RESTLESS         = %00001000
CART_ADDR_DATA   = %00000010

; --- NES PPU status flags (used in NES-to-Lynx bridge) ---
NES_VBLANK_FLAG  = $80
NES_SPRITE0_FLAG = $40

; --- Audio FEED tap values ---
FEED_SQUARE      = $01
FEED_NOISE_LONG  = $AE
FEED_NOISE_SHORT = $41
