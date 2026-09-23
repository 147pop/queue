#!/bin/sh
set -e

: "${SCREEN_W:=1280}"
: "${SCREEN_H:=800}"
: "${START_URL:=https://ipinfo.io/json}"
: "${USER_AGENT:=}"

export DISPLAY=:0

Xvfb :0 -screen 0 "${SCREEN_W}x${SCREEN_H}x24" -nolisten tcp &

for _ in $(seq 1 50); do
  [ -e /tmp/.X11-unix/X0 ] && break
  sleep 0.1
done

x11vnc -display :0 -forever -shared -nopw -quiet -localhost -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

UA_FLAG=""
[ -n "$USER_AGENT" ] && UA_FLAG="--user-agent=$USER_AGENT"

exec chromium \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --no-first-run \
  --no-default-browser-check \
  --test-type \
  --window-position=0,0 \
  --window-size="${SCREEN_W},${SCREEN_H}" \
  --start-maximized \
  ${UA_FLAG:+"$UA_FLAG"} \
  "$START_URL"
