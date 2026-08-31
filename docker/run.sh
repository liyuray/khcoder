#!/bin/bash
# Launch KH Coder. Pass a command, or nothing for a shell.
#
# There is no database server: each project is a single SQLite file under
# config/<project>/. Nothing to start, nothing to shut down, no volume.
#
# Build the image first:  docker build -t khcoder:latest docker/
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"          # the KH Coder source tree
BASE="$(cd "$REPO/.." && pwd)"          # where tutorial_jp / work live, if present
XAUTH="${XDG_RUNTIME_DIR:-/tmp}/khcoder.xauth"

# Hand the container an X cookie of its own rather than opening the display to
# every local user with "xhost +local:". The entry's family is rewritten to
# FamilyWild (ffff) so it matches from inside the container's hostname.
if [ -n "${DISPLAY:-}" ]; then
  : > "$XAUTH"
  chmod 600 "$XAUTH"
  for src in "${XAUTHORITY:-}" "$HOME/.Xauthority" \
             "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gdm/Xauthority"; do
    [ -n "$src" ] && [ -r "$src" ] || continue
    xauth -f "$src" nlist 2>/dev/null | sed -e 's/^..../ffff/' \
      | xauth -f "$XAUTH" nmerge - 2>/dev/null || true
  done
  # Some display managers key the cookie to a bare ":" rather than ":0".
  COOKIE=$(xauth -f "$XAUTH" list 2>/dev/null | awk 'NR==1{print $3}')
  [ -n "$COOKIE" ] && xauth -f "$XAUTH" add "$DISPLAY" MIT-MAGIC-COOKIE-1 "$COOKIE" 2>/dev/null || true
fi

MOUNTS=(-v "$REPO:/khcoder/src")
[ -d "$BASE/tutorial_jp" ] && MOUNTS+=(-v "$BASE/tutorial_jp:/khcoder/tutorial_jp")
[ -d "$BASE/work" ]        && MOUNTS+=(-v "$BASE/work:/khcoder/work")
[ -n "${DISPLAY:-}" ] && MOUNTS+=(-v /tmp/.X11-unix:/tmp/.X11-unix -v "$XAUTH:/tmp/.xauth:ro")

# Run as the invoking user so project files are not left owned by root.
exec docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e DISPLAY="${DISPLAY:-:0}" \
  -e XAUTHORITY=/tmp/.xauth \
  -e LANG=ja_JP.UTF-8 \
  "${MOUNTS[@]}" \
  khcoder:latest "${@:-/bin/bash}"
