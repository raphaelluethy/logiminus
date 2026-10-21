# Logiminus

A small replacement for Logi Options+ for the **Logitech Spotlight 2** presenter on macOS:
a menu bar agent plus a CLI (for Raycast script commands).

- Light press + hold top button → laser pointer dot, moved by the remote's gyro
- Hard press → spotlight (dims the screen around a circle)
- Next / Back → → / ←; holding Back sends ⇧B (black screen) during a presentation,
  otherwise it steps back repeatedly
- Haptics level, presentation timer with haptic alerts, battery in the menu
- The overlay is a non-activating panel and no event taps are installed, so it
  never steals focus or slows the keyboard

Currently supports the Bolt USB receiver; Bluetooth is next.

## Build & install

```sh
scripts/build-app.sh --install   # → ~/Applications/Logiminus.app, CLI → ~/.local/bin/logiminus
```

The app needs **Accessibility** permission (to send arrow keys). It is signed with the
first Apple Development identity found (override with `LOGIMINUS_SIGN_IDENTITY`), so the
permission survives rebuilds. Quit Logi Options+ — both cannot drive the device at once.

## CLI

```
logiminus enable | disable | toggle | status
logiminus haptic <waveform>
logiminus timer start [minutes] | stop
logiminus quit
logiminus monitor [--divert] [-v]     # debug: print HID++ traffic
```

`enable`/`toggle` start the app if it is not running. `disable` hands the buttons back to the
device's native behaviour. Raycast script commands are in `raycast/` — add that folder
under Raycast → Extensions → Script Commands.

## Protocol notes (HID++ 2.0, reverse engineered)

The Spotlight 2 sits behind a Bolt receiver (`046d:c548`, vendor collection usage page
`0xFF00`) and may show up in more than one pairing slot. It sleeps after a few seconds idle;
the receiver then answers `8F … 04` until a request wakes it, and announces wake-ups with
`0x41` connection notifications.

| Index | Feature | Use |
|---|---|---|
| 0x09 | 0x1004 Unified battery | fn1 → `[percent, level, charging]` |
| 0x0B | 0x1B04 Reprog controls v4 | fn3 setCidReporting `[cid, flags, remap]`; events fn0 buttons, fn1 raw XY |
| 0x0F | 0x19B0 Haptics | fn1/fn2 get/set `[enabled, level]`, fn3 play `[waveform]` |
| 0x10 | 0x19C0 Force sensing button | fn1 capabilities, fn2 current force |

Control IDs: `0x50` top tap, `0xD8` top light hold (raw XY), `0x1A8` top hard press (replaces
`0xD8`, raw XY), `0xD9`/`0xDA` next click/hold, `0xDB`/`0xDC` back click/hold, `0xFB`
start/stop presentation, `0x1B0` haptic trigger. Holding Next + Back together is handled by
the firmware (Bluetooth pairing mode) and is never reported; the device drops off the receiver
and may re-appear in another slot. Raw XY: signed 16-bit big-endian dx, dy.
