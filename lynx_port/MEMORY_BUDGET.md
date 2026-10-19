# Lynx Port — Memory Budget

Last updated: 2026-10-19
Reflects: ld65 -m map of current objects (RODATA ends $BC11, MAIN limit $BE1F)

## Memory Regions Summary

| Region | Range | Total | Used | Free | Notes |
|--------|-------|-------|------|------|-------|
| Zero Page | $0000–$00FF | 256 B | SMB | — | SMB owns ZP at runtime (see lynx_port.cfg) |
| Stack | $0100–$01FF | 256 B | reserved | — | 6502 hardware stack |
| NES game vars | $0200–$07FF | 1536 B | ~1536 B | 0 B | SMB RAM, all in use |
| RECYCLEDATA | $0800–$08D2 | 211 B | 132 B | **79 B** | Dead startup code overlay; BSS only; no code |
| STARTUP | $0800–$08FB | 252 B | all | — | irq_handler inside it must stay live (above RECYCLEDATA) |
| CODE+RODATA | $08FC–$BC11 | — | all | — | Game code and tables (no BSS in MAIN) |
| MAIN slack | $BC12–$BE1F | 526 B | 0 B | **526 B** | Free for code/RODATA/BSS |
| FRAMEBUF0 | $BE20–$DE1F | 8192 B | 8192 B | 0 B | $1FE0 display + $20 gap ($DE00–$DE1F, CPU-visible RAM) |
| FRAMEBUF1 | $DE20–$FDFF | 8160 B | 8160 B | 0 B | Last $200 lies under Suzy/Mikey: Suzy + display DMA see RAM, CPU sees registers |
| Suzy HW | $FC00–$FCFF | 256 B | HW | — | CPU-side registers (RAM beneath holds FB1 tail) |
| Mikey HW | $FD00–$FDFF | 256 B | HW | — | CPU-side registers (RAM beneath holds FB1 tail) |
| HIGHDATA | $FE00–$FFF7 | 504 B | 500 B | **4 B** | ROM-remapped RAM via MAPCTL B2; BSS only |
| Vectors | $FFFA–$FFFF | 6 B | 6 B | 0 B | NMI/RESET/IRQ in RAM (MAPCTL B3) |

## Allocation Log

Track each allocation here so the totals above can be updated.

| Date | Region | Size | Variable/Purpose |
|------|--------|------|-----------------|
| (none yet) | — | — | — |

## Rules

- **RECYCLEDATA**: BSS variables only. No code. Never accessed during startup (before `jmp Start`).
- **HIGHDATA**: BSS variables only. No code. Mapped via MAPCTL B2=1 (always set in MAPCTL_NORMAL).
- **Zero page**: Prefer for pointers/loop counters — 65C02 ZP addressing saves cycles.
- **Update this file** whenever you add or remove variables in RECYCLEDATA, HIGHDATA, or ZP.
