# Persisting the fix

The runtime fix this repository documents (clock pins applied by hand)
lives in RAM and dies on reboot. This doc makes the 400 MHz configuration
survive reboots, three independent ways — pick one (or stack them).

| Layer | Mechanism | Needs kernel rebuild? | Covers |
|---|---|---|---|
| 1 (recommended) | DTS patch [`0001-*.patch`](0001-arm64-dts-rockchip-pin-RK3328-rkvdec-RGA-clocks-at-the-mpp-advanced-rate.patch) | DTB only | boot-time, self-maintaining, upstreamable |
| 2 | boot pin: [`vpu-clocks.initd`](scripts/vpu-clocks.initd) / [`.service`](scripts/vpu-clocks.service) | no | boot-time |
| 3 | watchdog: [`vpu-clock-watchdog.sh`](scripts/vpu-clock-watchdog.sh) + units | no | runtime, re-asserts on drift |

All three target the same end state: decoder + RGA clocks at 400 MHz on
CPLL.

## Why the fix is needed at all (summary)

The rk3328.dtsi CRU node boots the decoder interface clocks at
100 MHz (`ACLK_RKVDEC_PRE`, `SCLK_VDEC_CABAC`, `SCLK_VDEC_CORE`) and the
RGA at 100 MHz. The BSP mpp driver *declares* the right rates
(`rockchip,normal-rates` 300 MHz, `rockchip,advanced-rates` 400 MHz in
the rkvdec node) but its auto-frequency path never fires on RK3328 —
`/proc/mpp_service/rkvdec/{aclk,clk_core,clk_cabac}` report
`real_rate_hz` of **0**, idle and under full load. So decode runs at
33.8 fps instead of 70.2. Full investigation + measurements:
[blog.md](blog.md).

## Layer 1 — DTS patch (recommended)

The patch adds consumer-node `assigned-clocks`/`assigned-clock-rates`
to the `rkvdec` and `rga` nodes at 400 MHz. Consumer-node assignment
runs at device probe — *after* the CRU has raised CPLL to 1.2 GHz — so
400 MHz = CPLL/3 resolves exactly and CCF selects the CPLL parent
(assignments on the dtsi CRU node itself happen before CPLL is raised,
which is why they stay low). Assigning `SCLK_RGA` also forces the CPLL
mux for the RGA core clock, whose reset default is GPLL
(491.52/3 = 163.84 MHz — and RGA is clock-bound: dec→RGA 31.4 →
40.8 fps when forced to 400).

Apply + rebuild just the dtbs (`make ARCH=arm64 dtbs`) + deploy the dtb
the way your image does. No other kernel artifacts change.

**Verify after boot:**

```sh
grep -E "vdec|rga" /sys/kernel/debug/clk/clk_summary    # 400 MHz entries
# decode bench: expect ~70 fps on 4K HEVC, not 34
```

Rollback: revert the hunk (or boot your fallback kernel/label).

## Layer 2 — boot pin (no rebuild)

```sh
gcc -O2 -o /usr/local/bin/cru scripts/cru.c
# systemd images (Armbian etc.):
install -m644 scripts/vpu-clocks.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now vpu-clocks
# OpenRC images:
install -m755 scripts/vpu-clocks.initd /etc/init.d/vpu-clocks
rc-update add vpu-clocks default && rc-service vpu-clocks start
```

What it writes — CRU register math (commented in the units too):
`CLKSEL_CON(n) = 0xFF440000 + 0x100 + 4n`; hiword [31:16] of every write
is the per-bit write-enable mask (writes without it are silently
ignored); each field is div[4:0] (`rate = parent/(div+1)`) + mux[7:6]
(0 = CPLL @ 1200 MHz live). The pins: `CON(48)=0xFFFF0202`,
`CON(49)=0x00FF0202`, `CON(36)=0xFFFF0202` — decoder aclk/cabac/core and
RGA core/aclk → div 2 + mux CPLL = 400 MHz. Plus
`mpp_service load_interval=1000` so `/proc/mpp_service/load` reports
sane numbers.

Rollback: disable the unit (`systemctl disable --now` /
`rc-update del`).

## Layer 3 — repin watchdog (optional belt-and-braces)

[`vpu-clock-watchdog.sh`](scripts/vpu-clock-watchdog.sh) re-asserts the
three registers whenever their low halfword drifts (5 s default). The
venc driver re-applies its own clock defaults at every session start,
and a future mpp driver change could do the same to the decoder — this
keeps the pin live without a reboot. Install the companion
`.service`/`.initd` the same way as layer 2.

Note: the watchdog always writes the full masked value (0xFFFF mask),
regardless of what state a driver left the register in.

## What is deliberately not pinned

- **venc (`CON(51)`)** — the encoder driver self-manages (resume →
  300 MHz, idle → 50 MHz reduce) via working CCF writes, and 400 MHz
  measured no encode gain (27.15 vs 27.32 fps — noise).
- **The mpp auto-freq bug itself** — the real upstream fix is a driver
  patch making `rkvdec2_set_freq()` fire on RK3328. Until someone finds
  it, the DTS pin is the correct workaround.
