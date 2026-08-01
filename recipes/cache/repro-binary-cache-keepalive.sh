#!/bin/sh
# Keep the repro-cache WSL distro alive. WSL ignores systemd services when it
# decides whether a distro is idle, so a foreground wsl.exe client must remain
# attached while the cache is expected to serve builds.

set -eu

LOCK_FILE=/run/repro-binary-cache-keepalive.lock

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  # Another keeper already owns the foreground WSL session.
  exit 0
fi

systemctl start repro-binary-cache.service repro-binary-cache-rsync.timer

while systemctl is-active --quiet repro-binary-cache.service; do
  sleep 30
done

echo "repro-binary-cache.service stopped unexpectedly" >&2
exit 1
