# Lynx Port — Memory Budget

Last updated: 2026-02-19
Reflects: build/smb_lynx.map (BSS ends $BC1F, startup segment $0800-$08E2)

## Memory Regions Summary

| Region | Range | Total | Used | Free | Notes |
|--------|-------|-------|------|------|-------|
| Zero Page | $0000–$00FF | 256 B | 21 B | **235 B** | $0015–$00FF free; fastest RAM |
| Stack | $0100–$01FF | 256 B | reserved | — | 6502 hardware stack |
| NES game vars | $0200–$07FF | 1536 B | ~1536 B | 0 B | SMB RAM, all in use |
| RECYCLEDATA | $0800–$08D2 | 211 B | 0 B | **211 B** | Dead startup code overlay; BSS only; no code |
| irq_handler | $08D3–$08E2 | 16 B | 16 B | 0 B | Persistent VBlank handler; must not be overwritten |
| CODE+RODATA | $08E3–$B9F1 | — | all | 0 B | Game code and tables |
| BSS | $B9F2–$BC1F | 558 B | 558 B | 0 B | Game BSS; zero slack |
| FRAMEBUF0 | $BC20–$DC1F | 8192 B | 8192 B | 0 B | Display buffer; not general RAM |
| FRAMEBUF1 | $DC20–$FBFF | 8160 B | 8160 B | 0 B | Display buffer; not general RAM |
| Suzy HW | $FC00–$FCFF | 256 B | HW | — | Hardware registers; cannot remap |
| Mikey HW | $FD00–$FD9F | 160 B | HW | — | Hardware registers |
| HIGHDATA | $FE00–$FFF7 | 504 B | 12 B | **492 B** | ROM-remapped RAM via MAPCTL B2; BSS only |
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
