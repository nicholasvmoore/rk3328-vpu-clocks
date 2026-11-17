# rk3328-vpu-clocks

One-patch fix for the crippled VPU/decoder clocks on RK3328 boards
(Rock Pi E and friends) running the Rockchip BSP (`rkr`) kernel with the
`mpp` media stack.

**TL;DR:** out of the box, 4K HEVC decode runs at **33.8 fps — 57% of the
datasheet's 60 fps spec** — because the device tree boots the decoder
clocks at 100 MHz and the mpp driver's auto-frequency path never fires on
RK3328. Apply the DTS patch (or the boot-script alternative) and decode
runs at the driver's own declared advanced rate:

| Clocks | Decode 4K HEVC | dec→RGA→null |
|---|---|---|
| stock boot pins (100/50 MHz) | 33.79 fps | 31.55 fps |
| decoder + RGA @ 400 MHz | **70.21 fps** (117% of spec) | **40.84 fps** |

Full story: [blog.md](blog.md). Persistence options:
[persistence.md](persistence.md).

## Contents

| Path | What |
|---|---|
| `0001-*.patch` | the DTS fix, ready for `git am` / `patch -p1` against any rk3328 BSP kernel tree (tested on 6.12.81-rkr12) |
| `scripts/cru.c` | 25-line `/dev/mem` RK3328 CRU peek/poke tool (the investigation instrument; also used by the boot pin) |
| `scripts/vpu-clocks.initd` | OpenRC boot-time pin — the no-rebuild fix |
| `scripts/vpu-clocks.service` | systemd boot-time pin — same, for systemd-based images (Armbian etc.) |
| `scripts/vpu-clock-watchdog.sh` | repin loop: re-asserts the clock pins if anything moves them |
| `scripts/vpu-clock-watchdog.initd` / `.service` | runner units for the watchdog |
| `blog.md` | how the bug was found and fixed |
| `persistence.md` | making the fix survive reboots, three ways |

## Quick start

**Option A — rebuild the DTB only** (recommended):

```sh
git am 0001-arm64-dts-rockchip-rk3328-pin-VPU-decode-and-RGA-clock-rates.patch
make ARCH=arm64 dtbs            # rk3328 dtb rebuilds in seconds
# deploy rk3328-<board>.dtb the way your image does, reboot
```

**Option B — no rebuild:**

```sh
gcc -O2 -o /usr/local/bin/cru scripts/cru.c
install -m755 scripts/vpu-clocks.service /etc/systemd/system/   # or .initd for OpenRC
systemctl enable --now vpu-clocks                                # or rc-update add vpu-clocks default
```

## Verify

```sh
grep -E "vdec|rga" /sys/kernel/debug/clk/clk_summary     # expect 400 MHz entries
# then: 4K HEVC decode should roughly double its fps
```

## Notes

- The venc (H.264 encoder) side is intentionally **not** pinned: that
  driver self-manages its clocks (resume → 300 MHz, idle → 50 MHz), and
  400 MHz measured no encode gain. Leave it alone.
- The *root* fix would be a driver patch making `rkvdec2_set_freq()`
  actually fire on RK3328 — see `blog.md` for the evidence trail
  (`/proc/mpp_service/rkvdec/*` rates stay 0 forever). The DTS pin is
  the correct, simple workaround until someone finds that bug.
- Tested on: Rock Pi E (RK3328), kernel 6.12.81-rkr12 (Radxa/BSP
  `linux-6.12-stan-rkr1.1`), mpp 1.3.10, ffmpeg-rockchip.

## License

Kernel patch: GPL-2.0 (it is a DTS change against the kernel tree).
Scripts: GPL-2.0-or-later.
