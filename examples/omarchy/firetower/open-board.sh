#!/bin/sh
# Open the board once: focus its window when one is open, else open one,
# starting the board's server first if none is running. `firetower board
# --open` starts a server and a window on every call, so a bar click would
# pile them up.
#
# The window is a web app window (Omarchy's omarchy-launch-webapp) onto
# http://127.0.0.1:<port>/, so Hyprland knows it by a class starting
# chrome-127.0.0.1 and a title ending in "Firetower" (the title carries a
# count when something needs a look).
ft="${1:-$HOME/.local/bin/firetower}"

board_up() { pgrep -u "$(id -u)" -f '^(/[^ ]*/)?firetower board' >/dev/null; }
if ! board_up; then
  setsid "$ft" board >/dev/null 2>&1 </dev/null &
  i=0
  while [ $i -lt 50 ]; do
    board_up && "$ft" board --url >/dev/null 2>&1 && break
    sleep 0.1; i=$((i + 1))
  done
fi
url=$("$ft" board --url) || { notify-send "Firetower" "The board didn't start."; exit 1; }

addr=$(hyprctl clients -j | jq -r '.[] | select((.class | startswith("chrome-127.0.0.1")) and (.title | test("Firetower$"))) | .address' | head -n1)
if [ -n "$addr" ]; then
  # Hyprland's Lua dispatcher first, then the older one.
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1 \
    || hyprctl dispatch focuswindow "address:$addr" >/dev/null
  exit 0
fi
exec omarchy-launch-webapp "$url"
