#!/bin/bash

# Pick a capture target and print it on stdout.
#
#   monitor:NAME          a whole monitor, captured natively at its own resolution
#   "X,Y WxH"             a region, in the compositor's logical coordinate space
#
# Exits 1 when the user cancels. Modes:
#
#   region      freeform selection
#   windows     snap to a monitor or window rectangle
#   smart       freeform with rectangles hinted; a bare click snaps to the
#               rectangle it landed in instead of producing a 1px capture
#   fullscreen  the focused monitor, no interaction
#   window      no picker at all: cycle to the window next to the cursor and
#               print its rectangle (next|prev|left|right|up|down)
#
#   --match-monitor    print monitor:NAME when the selection matches a monitor
#   --keep-freeze      leave the screen freeze running, print its pid first
#
# The portal is deliberately not involved: it cannot pick a window on Wayland
# through gpu-screen-recorder, and its dmabuf path fails here anyway.

set -uo pipefail

# SCREEN_CAPTURE_RUNTIME_DIR redirects only this plugin's own state, so tests can
# run somewhere else. XDG_RUNTIME_DIR must not be overridden for that purpose:
# hyprctl derives its socket path from it and loses the compositor connection.
RUNTIME_DIR="${SCREEN_CAPTURE_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/screen-capture}"
FULLSCREEN_MARKER="$RUNTIME_DIR/pick-fullscreen"
WINDOW_MARKER="$RUNTIME_DIR/pick-window"

# Monitors rotated 90/270 swap their logical width and height.
JQ_MONITOR_GEO='
  def format_geo:
    .x as $x | .y as $y |
    (.width / .scale | floor) as $w |
    (.height / .scale | floor) as $h |
    .transform as $t |
    if ($t % 2) == 1 then
      "\($x),\($y) \($h)x\($w)"
    else
      "\($x),\($y) \($w)x\($h)"
    end;
'

mkdir -p "$RUNTIME_DIR" || exit 1

active_workspace() {
  hyprctl monitors -j | jq -r '.[] | select(.focused == true) .activeWorkspace.id'
}

# Windows hidden in the group are excluded, and duplicates are collapsed:
# slurp cannot tell two windows at the same geometry apart, and the duplicate
# would stall the Tab cycle on the first copy.
window_rects() {
  hyprctl clients -j | jq -r --arg ws "$(active_workspace)" \
    '[.[] | select(.workspace.id == ($ws | tonumber) and .hidden != true) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"] | unique[]'
}

monitor_rects() {
  hyprctl monitors -j | jq -r --arg ws "$(active_workspace)" "${JQ_MONITOR_GEO} .[] | select(.activeWorkspace.id == (\$ws | tonumber)) | format_geo"
}

get_rectangles() {
  monitor_rects
  window_rects
}

focused_monitor_geo() {
  hyprctl monitors -j | jq -r "${JQ_MONITOR_GEO} .[] | select(.focused == true) | format_geo"
}

# slurp highlights the smallest rectangle containing the point and keeps the
# first on a tie, so overlapping candidates resolve the same way here.
resolve_rect_at() {
  local x=$1 y=$2
  local rect area
  local smallest_area=0

  RESOLVED_RECT=""

  while IFS= read -r rect; do
    [[ $rect =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] || continue
    ((x >= BASH_REMATCH[1] && x < BASH_REMATCH[1] + BASH_REMATCH[3] &&
      y >= BASH_REMATCH[2] && y < BASH_REMATCH[2] + BASH_REMATCH[4])) || continue

    area=$((BASH_REMATCH[3] * BASH_REMATCH[4]))
    if [[ -z $RESOLVED_RECT ]] || ((area < smallest_area)); then
      RESOLVED_RECT=$rect
      smallest_area=$area
    fi
  done

  [[ -n $RESOLVED_RECT ]]
}

# Whatever slurp is highlighting under the cursor. Monitors are fed alongside
# windows so a cursor in a gap or over the bar resolves to the monitor rather
# than to nothing.
geo_at_cursor() {
  local pos
  pos=$(hyprctl cursorpos)
  local x=${pos%,*}
  local y=${pos#*, }

  if resolve_rect_at "$x" "$y" < <(window_rects) || resolve_rect_at "$x" "$y" < <(monitor_rects); then
    echo "$RESOLVED_RECT"
  else
    focused_monitor_geo
  fi
}

# Keyboard control while slurp is open. The --take-* modes flag their intent
# with a marker file and dismiss slurp; slurp then exits with no selection,
# which is how we tell "dismissed on purpose" from "cancelled by the user".
if [[ ${1:-} == "--take-fullscreen" ]]; then
  pgrep -x slurp >/dev/null || exit 0
  touch "$FULLSCREEN_MARKER"
  pkill -x slurp
  exit 0
fi

if [[ ${1:-} == "--take-window" ]]; then
  pgrep -x slurp >/dev/null || exit 0
  touch "$WINDOW_MARKER"
  pkill -x slurp
  exit 0
fi

# Select a window without opening a picker at all.
#
#   pick-region.sh window next|prev|left|right|up|down
#
# Prints the target rectangle directly. "Current" is whichever window the cursor
# is over, resolved with the same smallest-contains rule slurp applies, so
# navigation and an interactive pick never disagree about which window is
# selected. Reading order is top to bottom, then left to right.
if [[ ${1:-} == "window" ]]; then
  direction=${2:-}
  pos=$(hyprctl cursorpos)
  origin_x=${pos%,*}
  origin_y=${pos#*, }

  candidates=$(window_rects)
  [[ -n $candidates ]] || exit 1

  rects=$(while IFS= read -r rect; do
    [[ $rect =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] || continue
    printf '%d\t%d\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "$rect"
  done <<<"$candidates" | sort -n -k1,1 -k2,2 | cut -f3-)
  [[ -n $rects ]] || exit 1

  current=""
  resolve_rect_at "$origin_x" "$origin_y" <<<"$candidates" && current=$RESOLVED_RECT

  if [[ $current =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]]; then
    origin_x=$((BASH_REMATCH[1] + BASH_REMATCH[3] / 2))
    origin_y=$((BASH_REMATCH[2] + BASH_REMATCH[4] / 2))
  fi

  target=""

  case $direction in
  next | prev)
    mapfile -t ordered <<<"$rects"
    count=${#ordered[@]}
    current_index=-1

    for i in "${!ordered[@]}"; do
      if [[ -n $current && ${ordered[i]} == "$current" ]]; then
        current_index=$i
        break
      fi
    done

    if [[ $direction == next ]]; then
      target=${ordered[$(((current_index + 1) % count))]}
    elif ((current_index == -1)); then
      target=${ordered[$((count - 1))]}
    else
      target=${ordered[$(((current_index - 1 + count) % count))]}
    fi
    ;;
  left | right | up | down)
    best_score=""

    while IFS= read -r rect; do
      [[ $rect == "$current" ]] && continue
      [[ $rect =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] || continue
      center_x=$((BASH_REMATCH[1] + BASH_REMATCH[3] / 2))
      center_y=$((BASH_REMATCH[2] + BASH_REMATCH[4] / 2))

      case $direction in
      left)  primary=$((origin_x - center_x)); perp=$((center_y - origin_y)) ;;
      right) primary=$((center_x - origin_x)); perp=$((center_y - origin_y)) ;;
      up)    primary=$((origin_y - center_y)); perp=$((center_x - origin_x)) ;;
      down)  primary=$((center_y - origin_y)); perp=$((center_x - origin_x)) ;;
      esac

      ((primary > 0)) || continue
      ((perp < 0)) && perp=$((-perp))
      score=$((primary + perp * 2))

      if [[ -z $best_score ]] || ((score < best_score)); then
        best_score=$score
        target=$rect
      fi
    done <<<"$rects"
    ;;
  *)
    exit 2
    ;;
  esac

  [[ -n $target ]] || exit 1
  echo "$target"
  exit 0
fi

MODE=smart
KEEP_FREEZE=false
MATCH_MONITOR=false

for arg in "$@"; do
  case $arg in
  --keep-freeze) KEEP_FREEZE=true ;;
  --match-monitor) MATCH_MONITOR=true ;;
  *) MODE=$arg ;;
  esac
done

# Runs slurp. An empty result with a marker present means a --take-* bind was
# pressed, so the highlighted rectangle or the monitor is the selection.
pick() {
  local selection
  rm -f "$FULLSCREEN_MARKER" "$WINDOW_MARKER"
  selection=$(slurp "$@" 2>/dev/null)

  if [[ -z $selection && -e $FULLSCREEN_MARKER ]]; then
    rm -f "$FULLSCREEN_MARKER"
    selection=$(focused_monitor_geo)
  elif [[ -z $selection && -e $WINDOW_MARKER ]]; then
    rm -f "$WINDOW_MARKER"
    selection=$(geo_at_cursor)
  fi

  printf '%s' "$selection"
}

FREEZE_PID=""
freeze_screen() {
  hyprpicker -r -z >/dev/null 2>&1 &
  FREEZE_PID=$!
  sleep .1
}

cleanup_freeze() {
  [[ $KEEP_FREEZE == true ]] && return
  [[ -n $FREEZE_PID ]] && kill $FREEZE_PID 2>/dev/null
}
trap cleanup_freeze EXIT

case "$MODE" in
region)
  freeze_screen
  SELECTION=$(pick)
  ;;
windows)
  freeze_screen
  SELECTION=$(get_rectangles | pick -r)
  ;;
fullscreen)
  SELECTION=$(focused_monitor_geo)
  ;;
smart | *)
  RECTS=$(get_rectangles)
  freeze_screen
  SELECTION=$(echo "$RECTS" | pick)

  # A bare click (area < 20px^2) snaps to whichever rectangle it landed in, so
  # users don't end up with accidental 2px captures. X and Y can be negative in
  # multi-display layouts.
  if [[ $SELECTION =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] &&
    ((BASH_REMATCH[3] * BASH_REMATCH[4] < 20)); then
    # resolve_rect_at keeps the smallest containing rectangle, so a click over a
    # window resolves to the window rather than the monitor behind it. The
    # rectangle list is monitors first, and a first-match loop would take the
    # monitor every time.
    if resolve_rect_at "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" <<<"$RECTS"; then
      SELECTION=$RESOLVED_RECT
    fi
  fi
  ;;
esac

[[ $KEEP_FREEZE == true ]] && echo "$FREEZE_PID"

[[ -n $SELECTION ]] || exit 1

# A selection that covers a monitor exactly is better served by a native
# monitor capture: same kms backend, full native resolution, no scaling math.
if [[ $MATCH_MONITOR == true ]]; then
  monitor=$(hyprctl monitors -j | jq -r --arg geo "$SELECTION" \
    "${JQ_MONITOR_GEO} .[] | select(format_geo == \$geo) | .name" | head -1)
  if [[ -n $monitor ]]; then
    echo "monitor:$monitor"
    exit 0
  fi
fi

echo "$SELECTION"
