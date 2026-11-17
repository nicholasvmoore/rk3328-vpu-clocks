#!/bin/sh
# vpu-clock-watchdog.sh — repin RK3328 decoder/RGA CRU dividers to 400 MHz
# whenever something moves them. Belt-and-braces for the DTS/initd pins:
# the BSP mpp driver never touches rkvdec clocks on RK3328 today, but the
# venc driver re-applies its own defaults at every session start, and a
# future driver change could do the same to the decoder — this keeps the
# proven 400 MHz config live without a reboot. Same logic as the pin=1
# mode of vpu-telemetry.sh, minus telemetry.
#
# Needs root (cru writes /dev/mem). Run via rc: see vpu-clock-watchdog
# initd below, or manually: doas -n /usr/local/bin/vpu-clock-watchdog.sh
#
# usage: vpu-clock-watchdog.sh [interval-seconds]   (default 5)

CRU=${CRU:-/usr/local/bin/cru}
INTERVAL=${1:-5}

# reg  lowhalf-target  full-write-with-mask
# CON(48) 0x1C0: aclk_rkvdec_pre + sclk_vdec_cabac -> 0x0202 each
# CON(49) 0x1C4: sclk_vdec_core -> 0x0002 (low field only)
# CON(36) 0x190: clk_rga + aclk_rga_pre -> 0x0202 each
PIN_48=0xFFFF0202
PIN_49=0x00FF0202
PIN_36=0xFFFF0202

while :; do
	c48=$($CRU 0x1c0 2>/dev/null)
	[ $((c48 & 0xffff)) != $((0x0202)) ] && $CRU 0x1c0 $PIN_48 >/dev/null
	c49=$($CRU 0x1c4 2>/dev/null)
	[ $((c49 & 0xff)) != $((0x02)) ] && $CRU 0x1c4 $PIN_49 >/dev/null
	c36=$($CRU 0x190 2>/dev/null)
	[ $((c36 & 0xffff)) != $((0x0202)) ] && $CRU 0x190 $PIN_36 >/dev/null
	sleep "$INTERVAL"
done
