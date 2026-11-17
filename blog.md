# The Rock Pi E's VPU was running at a quarter speed. Here's the one-patch fix.

*Nick Moore, November 2026. Everything referenced here is in this
repository; the internal working notes live in the private homelab
repo.*

## The symptom

I wanted to use a **Rock Pi E** (RK3328, four Cortex-A53) as a little
hardware-transcode box: 4K HEVC in, 1080p H.264 out, entirely on silicon.
The Rockchip BSP stack makes this possible: the vendor `rkr` kernel ships
`mpp_service` (Rockchip's media platform driver), and
`ffmpeg-rockchip` exposes `hevc_rkmpp` decode → `scale_rkrga` →
`h264_rkmpp` encode as a fully zero-copy pipeline — every frame touched
by hardware exactly once, the CPU ~96% idle.

Except it was slow. Not "slow for a $30 board" slow: **33.8 fps of 4K
HEVC decode** — 57% of the 60 fps the RK3328 datasheet promises. And the
full transcode chain sat at 28 fps.

## Chasing the clocks

The datasheet says the RK3328 video decoder wants 300 MHz for ordinary
work and can take **400 MHz** for advanced profiles. The device tree even
declares this — the BSP `rk3328.dtsi` gives the decoder node
`rockchip,normal-rates` and `rockchip,advanced-rates` properties, and
Rockchip's mpp driver has an auto-frequency path (`rkvdec2_set_freq`)
that's supposed to ramp the clocks per workload.

Reading the clocks under load told a different story:

```
sclk_vdec_core     100 MHz
sclk_vdec_cabac    100 MHz
aclk_rkvdec_pre    100 MHz
sclk_venc_core      50 MHz
```

Nothing ever moved them. The mpp driver exposes its requested rates at
`/proc/mpp_service/rkvdec/{aclk,clk_core,clk_cabac}` — every one read
**0**, idle and under full 4K load. `0` means `mpp_clk_set_rate()` was
never called: the auto-frequency path never fires for rkvdec on RK3328.
The `normal-rates`/`advanced-rates` in the device tree are dead text.

## Reading the CRU by hand

The RK3328 Clock-and-Reset-Unit register map is public (base
`0xFF440000`; clock-select registers `CLKSEL_CON(n)` at `0x100 + 4n`).
Two things were needed to poke them:

1. **Every write needs a hiword write-enable mask.** Bits [31:16] of the
   written word say which bits you're allowed to change. Write without
   the mask and the register silently ignores you.
2. **Watch the mux.** Each clock is a mux + divider; the divider math is
   `rate = parent / (div+1)` with CPLL at 1200 MHz. The RGA clock sat on
   its GPLL reset default (491.52/3 = 163.84 MHz) and a divider-only
   write left it there — you have to force the mux too.

With a 25-line `/dev/mem` tool, pinning all the decoder and RGA clocks
to `div=2, mux=CPLL` = **400 MHz** took decode from **33.8 → 70.2 fps —
117% of datasheet spec**, with zero decode errors. The RGA fix alone
(dec→RGA→null) went 31.4 → 40.8 fps.

| Clocks | Decode 4K HEVC | dec→RGA→null |
|---|---|---|
| boot pins (100/50 MHz) | 33.79 fps | 31.55 fps |
| decoder 300 MHz | 64.78 fps | — |
| decoder + RGA 400 MHz | **70.21 fps** | **40.84 fps** |

## Why the driver never ramps (the honest part)

The *proper* fix is a driver patch making the auto-frequency path fire.
I didn't land that one — on this BSP, `rkvdec2_set_freq()` is never
reached (suspects: `task->pixels` never set on the RK3328 task path, or
the compatible's ops entry missing `set_freq`). What I can prove is the
end state: the driver writes nothing, ever, so the boot assignment is
the only assignment that will ever happen.

## The one-patch fix

Since CCF-mediated clock writes demonstrably work (the venc driver's
runtime-resume sets its clock to 300 MHz through CCF, visibly), the fix
is to give the kernel the assignment itself — **consumer-node clock
assignment**, which runs at device probe, after the CRU has raised CPLL
to 1.2 GHz:

```dts
&rkvdec {
	assigned-clocks = <&cru ACLK_RKVDEC_PRE>, <&cru SCLK_VDEC_CORE>,
			  <&cru SCLK_VDEC_CABAC>;
	assigned-clock-rates = <400000000>, <400000000>, <400000000>;
};

&rga {
	assigned-clocks = <&cru ACLK_RGA_PRE>, <&cru SCLK_RGA>;
	assigned-clock-rates = <400000000>, <400000000>;
};
```

That's the whole patch (the `SCLK_RGA` line doubles as the mux fix —
assigning a rate makes CCF pick the CPLL parent). The venc side needs
nothing: the encoder driver manages itself, and its 400 MHz clock
measured no throughput gain anyway.

**For people who don't rebuild kernels**: the same registers can be
written at boot by a 15-line OpenRC/systemd unit with the `/dev/mem`
tool, plus a watchdog loop if you want belt-and-braces. Both are in the
same repo (`scripts/vpu-clocks.initd`,
`vpu-clock-watchdog.sh`) with the register math commented.

## Results on a real workload

With the 400 MHz pin, the board did a **full 42-minute 2160p50 TV
episode 4K HEVC → 1080p H.264 transcode at ~1.8× realtime** (~28 fps),
sustained for the entire file, CPU ~96% idle, peak temperature 59.5 °C
against a 70 °C passive-cooling trip point. The remaining ceiling is not
silicon — each of the three stages does ~40 fps solo; the per-frame
serial handoff across decode → RGA → encode costs the last ~12 ms/frame.

## For other RK3328 board owners

- Running the Rockchip BSP (Armbian vendor / Radxa rkr) kernel? Take the
  DTS patch and rebuild, or use the init-script route.
- On mainline? The mainline `rkvdec` driver doesn't support RK3328
  *encode* at all (and the RK3328 hantro variant is decode-only), so
  this patch only matters for the BSP stack — which is where all the
  working RKMPP tooling lives today.
- Verify your fix: `cat /sys/kernel/debug/clk/clk_summary | grep vdec`
  should show 400 MHz, and decode should roughly double.

The patch, the register tool, the watchdog, and the full root-cause
write-up are at <https://git.bun-arcturus.ts.net/git/rk3328-vpu-clocks>
(mirrored on GitHub). If anyone knows why `rkvdec2_set_freq()`
never fires on RK3328, I'd genuinely like to hear it — the DTS pin
works, but the driver should be doing this itself.

*Thanks to the Rockchip/Collabora BSP maintainers whose tree made all
the tooling work; the clock assignment was just the last mile.*
