# Spotlight 2 protocol notes

Reverse engineered from the device (HID++ 2.0, protocol 4.5, product id `0xB506`) and the
Logi Options+ device cache. Everything here was observed on firmware `RBO 08.03.0019`.

## Transport

The remote pairs with a Logitech receiver (`046d:c548`). HID++ goes through the receiver's
vendor collection (usage page `0xFF00`) using long reports (`0x11`, 20 bytes); the remote is
addressed by its pairing slot (1–6). The remote can occupy **more than one slot** and may come
back in a different one after pairing mode or a reconnect.

It sleeps after a few seconds idle. The receiver then answers requests with
`10 <slot> 8F <feat> <fn> 04 00` (HID++ 1.0 error 0x04) until a request wakes it, which takes
about a second. On wake-up the receiver sends a `0x41` connection notification
(`10 <slot> 41 …`, bit 6 of byte 4 set = link lost).

Over **Bluetooth LE** the remote (`046d:b506`) is a single HID device whose primary usage is
keyboard; HID++ lives in a secondary vendor collection (usage page `0xFF43`, usage `0x0202`,
report id `0x11` only) and the remote is addressed as device index `0xFF`. Because of the
keyboard collection, opening it requires Input Monitoring permission (`kIOReturnNotPermitted`
otherwise). The same feature indices and control IDs apply.

Holding Next + Back together puts the remote into Bluetooth pairing mode; the firmware handles
it and nothing is reported.

## Features

| Index | Feature | Notes |
|---|---|---|
| 0x01 | 0x0001 Feature set | 0x24 features |
| 0x03 | 0x0005 Device name | "Spotlight 2" |
| 0x04 | 0x1D4B Wireless device status | |
| 0x09 | 0x1004 Unified battery | fn1 → `[percent, level, charging, …]` |
| 0x0B | 0x1B04 Reprog controls v4 (v6) | see below |
| 0x0C / 0x0D | 0x1814 / 0x1815 Change host / hosts info | |
| 0x0E | 0x2250 | unknown |
| 0x0F | 0x19B0 Haptics (v3) | fn0 capabilities, fn1 get / fn2 set `[enabled, level]`, fn3 play `[waveform]`, fn4 playing waveform |
| 0x10 | 0x19C0 Force sensing button (v2) | fn0 count, fn1 capabilities, fn2 current force |
| 0x11 | 0x1A01 | unknown (presenter) |
| 0x12 | 0x2205 Pointer motion scaling | |

Options+ stores haptic level 35 and enabled; waveform 17 is called `belly_breathing`.

The force-sensing capability layout follows Options+' protobuf (`button_index, min_force,
default_force, max_force, high_force, force_change_capability, layer_config_capability,
num_thresholds, default_l2_force`); the exact byte mapping is not confirmed yet.

## Controls (0x1B04)

| CID | Gesture | Flags |
|---|---|---|
| `0x0050` | top button, quick tap (natively left click) | divertable |
| `0x00D8` | top button, light press held | divertable, raw XY |
| `0x01A8` | top button, hard press (replaces `0x00D8` while pressed hard) | divertable, raw XY |
| `0x00D9` / `0x00DA` | next: click / hold | divertable |
| `0x00DB` / `0x00DC` | back: click / hold | divertable |
| `0x00FB` | start / stop presentation (gesture unknown) | divertable |
| `0x01B0` | haptic trigger (gesture unknown) | divertable |
| `0x00FC` | — | not reprogrammable |

The firmware tells click from hold itself, so a hold produces only the hold CID.

`setCidReporting` (fn3): `[cid_hi, cid_lo, flags, remap_hi, remap_lo]` with flags
`0x01` divert, `0x02` divert valid, `0x10` raw XY, `0x20` raw XY valid.

Events (software id 0):
- fn0 diverted buttons: up to 4 pressed CIDs, big-endian, zero padded
- fn1 raw XY: `dx, dy` signed 16-bit big-endian, ~100 Hz while a raw-XY control is held
