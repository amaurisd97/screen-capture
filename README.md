# Screen Capture — Noctalia plugin

Record the screen, a single window or a region, with desktop + microphone audio
and a webcam overlay, from the bar or the control center.

## Status

Working. Loaded into this machine's Noctalia from a local `path` source; the
menu panel, the service, the widget and the shortcut all run, and a region +
webcam + desktop/mic capture has been recorded, finalized and played back.

## Requirements

All present on this machine and declared in `plugin.toml`:

`gpu-screen-recorder` · `slurp` · `jq` · `hyprctl` · `ffmpeg` · `pactl` · `flock`

For the webcam overlay: `mpv` and `v4l2-ctl`.

## How it works

The capture logic lives in `scripts/` and talks through files in a runtime
directory. The Luau entries orchestrate it: `menu.luau` is the pre-recording
panel, `service.luau` owns the run and drives the picker, and the widget and
shortcut are thin clients that only mirror state. Every script is a standalone
command and can be run, and debugged, on its own.

| Script | Role |
| --- | --- |
| `pick-region.sh` | Prints the capture target: `monitor:NAME` or `X,Y WxH` |
| `record.sh` | `start` / `stop` / `status`, serialized on its own lock |
| `webcam-list.sh` | Lists `/dev/video*` nodes that can actually capture |
| `webcam-resize.sh` | Sizes and places the webcam overlay |

### Recording menu

Left click on the widget (or the control-center tile) opens the `menu` panel,
which asks before every recording:

- **What to record** — Region, Application (window), or Full screen.
- **Audio** — None, Desktop, Microphone, or Desktop + microphone.
- **Record with camera** — a toggle, shown only when a camera is present.

Record closes the panel (so nothing of it is captured), runs the picker for
region/window targets, and starts the capture. Right click skips the panel and
records again with the last choice. The panel is a normal Noctalia surface and
can also be opened with
`noctalia msg panel-toggle amaurisd/screen-capture:menu`.

### Capture targets

| Mode | Result |
| --- | --- |
| `smart` | Draw freely, or click straight onto a window to snap to it |
| `windows` | Snap to a window or monitor rectangle |
| `region` | Freeform only |
| `fullscreen` | The focused monitor, no interaction |
| `window <dir>` | Cycle to a window next to the cursor and print it, no picker |

`smart` feeds monitor and window rectangles to `slurp` as hints and snaps a bare
click to whichever rectangle it landed in, so clicking a window records exactly
that window. `--match-monitor` upgrades a selection that covers a whole monitor
to a native monitor capture, which skips the scaling math and keeps the panel's
own resolution.

Keyboard while the picker is open:

```sh
scripts/pick-region.sh --take-fullscreen        # take the focused monitor
scripts/pick-region.sh --take-window            # take the rectangle under the cursor
scripts/pick-region.sh --select-window next     # move the selection
```

### Webcam

The camera is a floating `mpv` window showing the v4l2 device, cropped to 8:9
portrait, sized as a preset of the **region being recorded** and anchored to its
bottom-right corner. Because the recorder captures the screen, the camera ends up
baked into a single encode: one encoder pass, no compositing.

`float`, `pin`, resize and move are dispatched at runtime rather than declared as
Hyprland window rules, so the plugin needs no changes to your Hyprland config.

### Audio

`-a default_output|default_input -ac opus` merges desktop and microphone into
one track. Separate tracks play one at a time in most players.

The intermediate audio codec is Opus, not AAC: gsr 6.1.x's AAC path hands the
mp4 muxer two frames with the same dts (`Application provided invalid, non
monotonically increasing dts to muxer in stream 1`) and then fails to write
frame index 1. The affected frames fall inside the 400ms that finalize mutes, so
the glitch is inaudible, but the error is real and Opus shows no such warning.

On stop the file is finalized: the first frame is trimmed, the first 400ms muted
(PipeWire's capture open pops there), a 50ms fade added, and loudness normalized
to -14 LUFS. The audio is re-encoded to AAC there (ffmpeg's default for mp4), so
`normalize_audio = false` still skips the trim, mute, fade and loudness pass but
keeps AAC output.

## Why not the portal

`gpu-screen-recorder -w portal` cannot pick a window on Wayland: `-w window` and
`-w focused` are X11-only, and the portal is the only Wayland path to a window
target. It also does not work here — the dmabuf modifiers Hyprland offers fail
EGL import and PipeWire ends with `alloc buffers: Invalid argument`, after which
GSR cannot start. Reproduced for both a full-screen and a window target.

Omarchy hits the same wall and defaults its own portal backend off for exactly
this reason. This plugin does not use it at all.

## Codecs

`vainfo` on this machine reports encode entrypoints for H.264 and HEVC only.
VP9 is decode-only and there is no AV1 hardware at all, so GSR's
`-fallback-cpu-encoding yes` quietly switches AV1 to software, which is far too
slow for 2 cores. The quality setting is a named preset because GSR's `-q`
rejects a number outside CBR mode.

## Install

A Noctalia `path` source is a **directory of plugins**, and each plugin lives in
a directory named after the part of its id that follows the slash. This checkout
is the plugin itself, but its directory is not named `screen-capture`, so link
it under a source root first:

```sh
mkdir -p ~/Projects/noctalia-plugins
ln -sfn ~/Projects/leveling_up_screenrecording ~/Projects/noctalia-plugins/screen-capture
noctalia msg plugins source add local path ~/Projects/noctalia-plugins
noctalia msg plugins enable amaurisd/screen-capture
```

`.luau` edits hot-reload; `plugin.toml` changes are picked up on the next
`noctalia msg config-reload`. A reload or disable stops an active recording, so
do not edit `service.luau` mid-capture.

Then add `amaurisd/screen-capture:widget` to a bar and
`amaurisd/screen-capture:toggle` to the control center in Settings.

## Testing the scripts without the plugin

Set `SCREEN_CAPTURE_RUNTIME_DIR` so nothing lands in the real runtime
directory. Do **not** override `XDG_RUNTIME_DIR` for this: `hyprctl` derives its
socket path from it and loses the compositor connection.

```sh
export SCREEN_CAPTURE_RUNTIME_DIR=/tmp/sc-test
./scripts/record.sh start --target=monitor:eDP-1 --directory=/tmp/sc-test/out
./scripts/record.sh status
./scripts/record.sh stop
```

## IPC

The service answers both its internal state channel (the widget and tile) and
external IPC:

```sh
noctalia msg plugin amaurisd/screen-capture:service all toggle
noctalia msg plugin amaurisd/screen-capture:service all start
noctalia msg plugin amaurisd/screen-capture:service all start region
noctalia msg plugin amaurisd/screen-capture:service all start window
noctalia msg plugin amaurisd/screen-capture:service all start fullscreen
noctalia msg plugin amaurisd/screen-capture:service all record-last
noctalia msg plugin amaurisd/screen-capture:service all record-fullscreen
noctalia msg plugin amaurisd/screen-capture:service all stop
noctalia msg panel-toggle amaurisd/screen-capture:menu
```

`start <source>` overrides the capture source for that run; any other value uses
the last choice. `record-last` and `toggle` start with the last choice, or stop
when something is already running.

## Known limitations

- The capture target is frozen at selection time. Moving the window afterwards
  does not move the recorded rectangle.
- `no_dim` cannot be set at runtime — it only exists as a Hyprland window rule —
  so the overlay may dim while it is unfocused. Dimming is cosmetic.
- Region coordinates are the compositor's logical space, matching what `slurp`
  reports. Works with fractional scaling because GSR converts using the monitor.
- Audio and webcam are per-run choices from the menu; the `audio_source` and
  `webcam_size` settings only seed the menu's defaults.