#!/usr/bin/env bash
# de0-dbus.sh -- DE0-D overlay planter for ReproOS-Wayland-DEs-PoC.
#
# Plants the D-Bus system + session bus foundation (broker daemon +
# default policy + system & user systemd units + messagebus user) into
# a ReproOS rootfs overlay directory. This is the second Wayland-
# prerequisite layer per the campaign spec in
# `reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org` (DE0-D).
#
# Why dbus-broker (not dbus-daemon)?
#
#   The campaign spec explicitly prefers dbus-broker ("modern
#   replacement for dbus-daemon; preferred by NixOS recent versions").
#   On the repro-ubuntu (jammy 22.04) host, both packages are
#   available; dbus-broker has a smaller binary footprint and is
#   socket-activation native. We pin dbus-broker on the host and copy
#   its files directly into the overlay so the ABI matches every other
#   host-sourced binary in the R9+DE0-S layer.
#
#   Fallback: if dbus-broker is not installed on the build host, the
#   script falls back to dbus-daemon (from the dbus package) which is
#   the mature reference. The user-bus unit names converge on
#   `dbus.service` in both cases via the package's Alias= line.
#
# Usage:
#   de0-dbus.sh <OVERLAY_DIR>
#
# Idempotent: a sentinel `<OVERLAY>/var/lib/reproos-de0-dbus-done`
# short-circuits re-application. To force re-apply, delete the
# sentinel.
#
# Prerequisites:
#   - DE0-S has been (or will be) applied. logind needs D-Bus; this
#     recipe is a hard prerequisite per the campaign milestone graph.
#   - The build host runs Ubuntu 22.04 jammy (repro-ubuntu). Other
#     versions ship different libdbus + libsystemd ABIs that may not
#     match R9's from-source systemd.
#
# Risks:
#   - Cross-version ABI traps. The recipe copies host-installed
#     binaries; running on a non-jammy host risks shipping a libdbus
#     that doesn't match libsystemd's expected struct layout. The
#     script refuses to run if /etc/os-release reports anything other
#     than Ubuntu 22.04. Override with REPRO_DBUS_SKIP_OS_CHECK=1.
#   - dbus-broker writes to /run/dbus/system_bus_socket which must be
#     created by systemd via dbus.socket; we plant the socket unit so
#     systemd handles the bind.

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

if [ $# -lt 1 ]; then
  echo "usage: $0 <OVERLAY_DIR>" >&2
  exit 2
fi

OVERLAY="$1"
[ -n "$OVERLAY" ] || { echo "de0-d: OVERLAY_DIR empty" >&2; exit 2; }
mkdir -p "$OVERLAY"

log() { echo "[de0-d] $*"; }
die() { echo "[de0-d][error] $*" >&2; exit 1; }

SENTINEL="$OVERLAY/var/lib/reproos-de0-dbus-done"
if [ -f "$SENTINEL" ]; then
  log "sentinel present ($SENTINEL); skipping (idempotent no-op)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Stage 0: cross-version guard.
# ---------------------------------------------------------------------------

if [ "${REPRO_DBUS_SKIP_OS_CHECK:-0}" != "1" ]; then
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "22.04" ]; then
      die "host is ${ID:-?} ${VERSION_ID:-?}; expected ubuntu 22.04 (jammy). Set REPRO_DBUS_SKIP_OS_CHECK=1 to override."
    fi
  else
    log "warn: /etc/os-release missing; cannot verify host distro"
  fi
fi

# ---------------------------------------------------------------------------
# Stage 1: pick the daemon. Prefer dbus-broker (campaign spec
# recommendation) and fall back to dbus-daemon.
# ---------------------------------------------------------------------------

DAEMON=""
if command -v dpkg >/dev/null 2>&1; then
  if dpkg -s dbus-broker >/dev/null 2>&1; then
    DAEMON="broker"
  elif dpkg -s dbus >/dev/null 2>&1; then
    DAEMON="daemon"
  fi
fi
[ -n "$DAEMON" ] || die "neither dbus-broker nor dbus is installed on the build host (apt install dbus-broker dbus)"
log "stage 1: using daemon=$DAEMON"

# ---------------------------------------------------------------------------
# Helper: copy a host file into the overlay preserving its ABSOLUTE
# path layout. dpkg -L emits absolute paths; we mirror them under
# $OVERLAY/. Symlinks are preserved as-is (cpio cares about link
# targets, not their resolution).
# ---------------------------------------------------------------------------

plant_file() {
  local src="$1"
  local dst="$OVERLAY${src}"
  # Merged-/usr guard: on Ubuntu jammy, /lib /bin /sbin /lib64 are
  # themselves symlinks to /usr/lib etc. If we replicate those
  # symlinks into the overlay, support-lib plants under
  # $OVERLAY/lib/x86_64-linux-gnu would escape the overlay (since
  # `ln -sf /usr/lib $OVERLAY/lib` makes $OVERLAY/lib/foo resolve to
  # the host's /usr/lib/foo at apply time). Materialise these as
  # plain dirs so the overlay stays self-contained, and let the
  # initramfs assembly stage normalise the merged-/usr layout (cpio
  # segments are concatenated; if R9 already ships /lib -> /usr/lib
  # then the symlink target carries through and our dir-shaped /lib
  # gets unioned into /usr/lib at boot).
  case "$src" in
    /lib|/bin|/sbin|/lib64|/lib32|/libx32)
      mkdir -p "$dst"
      return 0
      ;;
  esac
  if [ -L "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    local tgt
    tgt=$(readlink "$src")
    ln -sf "$tgt" "$dst"
  elif [ -d "$src" ]; then
    mkdir -p "$dst"
  elif [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  else
    return 0  # missing / oddball — silently skip
  fi
}

plant_pkg() {
  # Plant every file owned by a dpkg package. Skip docs/man/lintian
  # noise to keep the overlay small (a future ISO budget concern).
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "  warn: package $pkg not installed; skipping"
    return 0
  fi
  local f
  while IFS= read -r f; do
    case "$f" in
      /usr/share/doc/*|/usr/share/man/*|/usr/share/lintian/*|/usr/share/bug/*)
        continue ;;
    esac
    plant_file "$f"
  done < <(dpkg -L "$pkg")
}

# ---------------------------------------------------------------------------
# Stage 2: plant the D-Bus packages.
#
#   - libdbus-1-3       : the libdbus shared library (clients link
#                          this; the broker itself does NOT use libdbus
#                          but every other consumer does).
#   - dbus               : ships /usr/bin/dbus-{send,daemon,monitor,…}
#                          + /etc/dbus-1/system.conf + dbus.socket
#                          + (when daemon path) the system unit.
#   - dbus-broker        : the broker binaries + its dbus-broker.service
#                          (system + user) when DAEMON=broker.
#   - dbus-user-session  : provides the user-instance dbus.socket that
#                          activates the user bus on session start.
#                          Both broker and daemon work with this
#                          socket because it only does ListenStream=
#                          on %t/bus.
# ---------------------------------------------------------------------------

log "stage 2: plant D-Bus package files"

plant_pkg libdbus-1-3
plant_pkg dbus
if [ "$DAEMON" = "broker" ]; then
  plant_pkg dbus-broker
fi
plant_pkg dbus-user-session

# Support libs that dbus-broker / dbus-daemon link against and that
# may not already be in the R9 closure. The DE0-S layer plants
# pam_systemd which already pulls libsystemd transitively at runtime,
# but we plant the .so files explicitly for belt-and-braces. Skipped
# if missing on host (dbus-daemon would refuse to start at boot in
# that case but it would refuse on the host too, so the error surface
# moves UP to recipe-apply time, which is the right thing).
SUPPORT_LIBS=(
  libexpat.so.1
  libsystemd.so.0
  libselinux.so.1
  libaudit.so.1
  libcap-ng.so.0
  libapparmor.so.1
  liblzma.so.5
  libzstd.so.1
  liblz4.so.1
  libcap.so.2
  libgcrypt.so.20
  libpcre2-8.so.0
  libgpg-error.so.0
)
HOST_LIBDIR=""
for cand in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do
  if [ -d "$cand" ]; then HOST_LIBDIR="$cand"; break; fi
done
[ -n "$HOST_LIBDIR" ] || die "host has no x86_64-linux-gnu libdir"

mkdir -p "$OVERLAY/lib/x86_64-linux-gnu"
for l in "${SUPPORT_LIBS[@]}"; do
  src="$HOST_LIBDIR/$l"
  if [ -e "$src" ]; then
    # Follow the symlink chain: libfoo.so.0 -> libfoo.so.0.X.Y.
    # Plant both the named link and the resolved file.
    plant_file "$src"
    # If $src is a symlink, also plant its target (same dir).
    if [ -L "$src" ]; then
      tgt=$(readlink "$src")
      case "$tgt" in
        /*) plant_file "$tgt" ;;
        *)  plant_file "$HOST_LIBDIR/$tgt" ;;
      esac
    fi
  fi
done

log "  planted libdbus-1-3 + dbus + dbus-user-session + support libs"
if [ "$DAEMON" = "broker" ]; then
  log "  planted dbus-broker (binaries + .service unit)"
fi

# ---------------------------------------------------------------------------
# Stage 3: messagebus user + group.
#
# The system bus runs as `messagebus:messagebus`. dbus's
# /usr/lib/sysusers.d/dbus.conf would normally create this at boot but
# we pin it deterministically in /etc/passwd + /etc/group so it
# matches the same DE0-S precedent (the repro user is also pinned not
# spawned via sysusers).
#
# UID 101 / GID 101 follows the Debian/Ubuntu convention for the
# messagebus account on a fresh install. The R9 base /etc/passwd has
# just root + nobody + repro (post-DE0-S); we union here.
# ---------------------------------------------------------------------------

log "stage 3: plant messagebus user + group"

mkdir -p "$OVERLAY/etc"

# The order of operations is tricky: DE0-S may have already planted
# /etc/passwd. We can't simply overwrite (we'd lose the repro entry)
# nor blindly append (re-apply would dupe entries). Strategy: read
# whatever's there (if anything), filter out any existing messagebus
# line, append our canonical line.
upsert_line() {
  # upsert_line <file> <key-regex> <full-line>
  local f="$1" key="$2" line="$3"
  if [ -f "$f" ]; then
    grep -v "$key" "$f" > "$f.tmp" || true
    echo "$line" >> "$f.tmp"
    mv "$f.tmp" "$f"
  else
    echo "$line" > "$f"
  fi
}

upsert_line "$OVERLAY/etc/passwd" "^messagebus:" \
  "messagebus:x:101:101:DBus Messagebus:/var/lib/dbus:/usr/sbin/nologin"
upsert_line "$OVERLAY/etc/group" "^messagebus:" \
  "messagebus:x:101:"

# /etc/shadow: locked account (`!` in password field). The DE0-S layer
# already sets 0640; we preserve.
if [ -f "$OVERLAY/etc/shadow" ]; then
  upsert_line "$OVERLAY/etc/shadow" "^messagebus:" \
    "messagebus:!:20000:0:99999:7:::"
  chmod 0640 "$OVERLAY/etc/shadow"
fi

if [ -f "$OVERLAY/etc/gshadow" ]; then
  upsert_line "$OVERLAY/etc/gshadow" "^messagebus:" \
    "messagebus:!::"
  chmod 0640 "$OVERLAY/etc/gshadow"
fi

# /var/lib/dbus: the daemon's spool dir. dbus-uuidgen writes a
# machine-id-derived random ID here on first boot. We create the dir;
# the tmpfiles.d snippet (planted below) ensures ownership at boot.
mkdir -p "$OVERLAY/var/lib/dbus"

# /run/dbus: the runtime socket dir. dbus.socket binds here. We plant
# an empty dir + tmpfiles.d entry to ensure systemd-tmpfiles-setup
# creates it with the right perms before dbus.socket activates.
mkdir -p "$OVERLAY/run/dbus"

log "  planted messagebus user + group + /var/lib/dbus + /run/dbus"

# ---------------------------------------------------------------------------
# Stage 4: tmpfiles.d snippet for /var/lib/dbus + /run/dbus
# ownership.
# ---------------------------------------------------------------------------

mkdir -p "$OVERLAY/etc/tmpfiles.d"
cat > "$OVERLAY/etc/tmpfiles.d/dbus.conf" <<'EOF'
# DE0-D: ensure D-Bus spool + runtime dirs exist with correct ownership.
# The /var/lib/dbus dir ships in the initramfs (mode 0755, root) and
# the chown is delayed to boot so the build host doesn't need root.
d /var/lib/dbus 0755 messagebus messagebus - -
d /run/dbus     0755 root       root        - -
EOF
chmod 0644 "$OVERLAY/etc/tmpfiles.d/dbus.conf"

# ---------------------------------------------------------------------------
# Stage 5: wire dbus.service into multi-user.target.wants so systemd
# activates it on normal boot. systemd-logind has Wants=dbus.service
# already (from R9's installed unit) and will pull it; we wire it
# directly too, so a boot without logind also brings up the bus.
#
# When DAEMON=broker, the Alias=dbus.service inside
# dbus-broker.service means systemd resolves `dbus.service` to the
# broker. We symlink directly to the broker unit for clarity.
# ---------------------------------------------------------------------------

log "stage 5: wire dbus.service into multi-user.target.wants"

mkdir -p "$OVERLAY/etc/systemd/system" \
         "$OVERLAY/etc/systemd/system/multi-user.target.wants" \
         "$OVERLAY/etc/systemd/system/sockets.target.wants" \
         "$OVERLAY/usr/lib/systemd/system" \
         "$OVERLAY/lib/systemd/system"

if [ "$DAEMON" = "broker" ]; then
  # DE-H2 cascade F fix: dbus-broker.service is shipped by Ubuntu jammy's
  # dbus-broker .deb at /lib/systemd/system/, NOT /usr/lib/systemd/system/.
  # R9 ships /lib as a real directory (NOT merged-/usr symlink) so a
  # symlink pointing at /usr/lib/systemd/system/dbus-broker.service is
  # broken at runtime. Always target the path where the file actually
  # lives (`/lib/systemd/system/dbus-broker.service`) AND plant a copy at
  # `/usr/lib/systemd/system/dbus-broker.service` so consumers that look
  # in either dir resolve.
  ln -sf "/lib/systemd/system/dbus-broker.service" \
         "$OVERLAY/etc/systemd/system/dbus.service"
  ln -sf "/lib/systemd/system/dbus-broker.service" \
         "$OVERLAY/etc/systemd/system/multi-user.target.wants/dbus.service"
  # DE-H2 cascade C fix: belt-and-braces plant of dbus.service alias under
  # both /usr/lib and /lib system-unit-path entries. R9 systemd's default
  # UnitPath includes both /etc/systemd/system, /usr/lib/systemd/system
  # AND /lib/systemd/system; planting a same-name unit under each
  # guarantees `systemctl status dbus.service` resolves regardless of
  # which dir the augmented-initramfs cpio segment ordering puts on top.
  ln -sf "/lib/systemd/system/dbus-broker.service" \
         "$OVERLAY/usr/lib/systemd/system/dbus.service"
  ln -sf "/lib/systemd/system/dbus-broker.service" \
         "$OVERLAY/lib/systemd/system/dbus.service"
  # DE-H2 cascade F: plant the actual broker unit file at /usr/lib too,
  # so `WantedBy=` consumers that resolve via /usr/lib's UnitPath entry
  # don't follow a broken symlink. Source is the host's /lib copy.
  if [ -f /lib/systemd/system/dbus-broker.service ]; then
    cp -a /lib/systemd/system/dbus-broker.service \
          "$OVERLAY/usr/lib/systemd/system/dbus-broker.service"
  fi
else
  # dbus-daemon variant: dbus.service shipped at /lib/systemd/system/.
  ln -sf "/lib/systemd/system/dbus.service" \
         "$OVERLAY/etc/systemd/system/dbus.service"
  ln -sf "/lib/systemd/system/dbus.service" \
         "$OVERLAY/etc/systemd/system/multi-user.target.wants/dbus.service"
  # Belt-and-braces alias under /usr/lib so lookups via either prefix
  # resolve. /lib/systemd/system/dbus.service is the dbus package
  # original; we leave it as-is.
  ln -sf "/lib/systemd/system/dbus.service" \
         "$OVERLAY/usr/lib/systemd/system/dbus.service"
fi

# dbus.socket: cascade G fix (2026-06-16).
#
# Background: Ubuntu jammy's dbus package ships dbus.socket at
# /lib/systemd/system/dbus.socket. R9 boots with `/lib` as a REAL
# directory (not the merged-/usr symlink to /usr/lib that modern
# distros use), and systemd 257.9's default UnitPath dropped
# /lib/systemd/system/ — it searches only:
#   /etc/systemd/system, /run/systemd/system,
#   /usr/local/lib/systemd/system, /usr/lib/systemd/system.
#
# Consequence pre-fix: the symlink
#   /etc/systemd/system/sockets.target.wants/dbus.socket
#     -> /lib/systemd/system/dbus.socket
# enumerates the unit name "dbus.socket" via the .wants/ dropin, but
# systemd resolves the unit by NAME against UnitPath and fails:
#   "Unit dbus.socket not found."
# sockets.target then activates 7 sockets (Credential, initctl, Journal
# (/dev/log), Journal sockets, udev Control, udev Kernel, Hostname) but
# NOT dbus.socket. dbus-broker.service can't start (Requires=dbus.socket
# unmet), systemd-logind keeps failing (Wants=dbus.service), no
# /run/user/1000 ever materialises, and the graphical session can't
# activate.
#
# Fix: plant dbus.socket under BOTH the legacy /lib/systemd/system/
# location (where the dbus package installs it; mirror cpio segment)
# AND a copy at /usr/lib/systemd/system/dbus.socket (where R9 systemd
# 257.9 actually searches). The sockets.target.wants/ symlink targets
# the /usr/lib/... path so the unit-name lookup resolves on the first
# UnitPath hit. Same pattern as the cascade-F fix for
# dbus.service -> dbus-broker.service above.
#
# The /lib/systemd/system/dbus.socket plant from `plant_pkg dbus` in
# stage 2 stays in place: this matches Ubuntu's on-disk layout and
# satisfies any tool that hard-codes the path (e.g. dpkg). The
# /usr/lib/... copy is the one systemd actually loads.
if [ -f /lib/systemd/system/dbus.socket ]; then
  cp -a /lib/systemd/system/dbus.socket \
        "$OVERLAY/usr/lib/systemd/system/dbus.socket"
fi
ln -sf "/usr/lib/systemd/system/dbus.socket" \
       "$OVERLAY/etc/systemd/system/sockets.target.wants/dbus.socket"
# Belt-and-braces: also plant a /etc/systemd/system/dbus.socket symlink
# (parallel to the dbus.service alias we already maintain at /etc/...).
# This makes `systemctl status dbus.socket` / `is-enabled dbus.socket`
# work even if a future overlay segment shadows /usr/lib.
ln -sf "/usr/lib/systemd/system/dbus.socket" \
       "$OVERLAY/etc/systemd/system/dbus.socket"

# ---------------------------------------------------------------------------
# Stage 6: user-instance bus wiring.
#
# dbus-user-session ships /usr/lib/systemd/user/dbus.{service,socket}
# and a sockets.target.wants symlink under the same tree. The
# per-user systemd manager picks these up automatically on session
# start. We plant a `/etc/systemd/user/` overlay symlink so that a
# future DE recipe (Hyprland, GNOME) can override without touching
# /usr/lib.
#
# When DAEMON=broker, the user dbus.service from dbus-user-session
# starts dbus-daemon --session. To use the broker instead, the
# dbus-broker package's user unit (Alias=dbus.service) takes
# precedence ONLY if it's been linked into the search path. We add an
# explicit /etc/systemd/user/dbus.service symlink to the broker user
# unit in the broker case.
# ---------------------------------------------------------------------------

log "stage 6: wire user-instance dbus units"

mkdir -p "$OVERLAY/etc/systemd/user" \
         "$OVERLAY/etc/systemd/user/sockets.target.wants"

if [ "$DAEMON" = "broker" ]; then
  # Override the dbus-user-session dbus.service with the broker user unit.
  ln -sf "/usr/lib/systemd/user/dbus-broker.service" \
         "$OVERLAY/etc/systemd/user/dbus.service"
fi

# Always wire dbus.socket into sockets.target.wants (matches what the
# dbus-user-session package itself does in /usr/lib/systemd/user/).
ln -sf "/usr/lib/systemd/user/dbus.socket" \
       "$OVERLAY/etc/systemd/user/sockets.target.wants/dbus.socket"

# ---------------------------------------------------------------------------
# Stage 7: default system policy.
#
# The host's /usr/share/dbus-1/system.conf is the canonical default
# policy; it was already planted by the `dbus` package in stage 2.
# We additionally plant /etc/dbus-1/system.conf as a copy so that
# admins can edit-without-touching-/usr (the convention).
# /etc/dbus-1/system.d/ is also planted by stage 2 (empty dir).
# ---------------------------------------------------------------------------

log "stage 7: plant /etc/dbus-1/system.conf"

mkdir -p "$OVERLAY/etc/dbus-1"
# Symlink to keep the overlay tiny (system.conf is ~3 KB but it
# matters that any edit goes via /etc).
ln -sf "/usr/share/dbus-1/system.conf" "$OVERLAY/etc/dbus-1/system.conf"
ln -sf "/usr/share/dbus-1/session.conf" "$OVERLAY/etc/dbus-1/session.conf"

# ---------------------------------------------------------------------------
# Stage 8: sentinel + summary.
# ---------------------------------------------------------------------------

mkdir -p "$OVERLAY/var/lib"
cat > "$SENTINEL" <<EOF
DE0-D D-Bus foundation applied.
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ -d "@$SOURCE_DATE_EPOCH")
Overlay: $OVERLAY
Daemon: $DAEMON

Planted:
  Packages:    libdbus-1-3 dbus dbus-user-session$([ "$DAEMON" = broker ] && echo " dbus-broker")
  Support libs: ${SUPPORT_LIBS[*]}
  System unit: /etc/systemd/system/dbus.service -> $([ "$DAEMON" = broker ] && echo "/usr/lib/systemd/system/dbus-broker.service" || echo "/lib/systemd/system/dbus.service")
               /usr/lib/systemd/system/dbus.service -> (same target)$([ "$DAEMON" = broker ] && echo " [+ /lib/systemd/system/dbus.service]")
  Socket:      /etc/systemd/system/sockets.target.wants/dbus.socket -> /usr/lib/systemd/system/dbus.socket
               (+ copy at /usr/lib/systemd/system/dbus.socket; original /lib/systemd/system/dbus.socket from dbus pkg retained)
  User unit:   /etc/systemd/user/sockets.target.wants/dbus.socket -> /usr/lib/systemd/user/dbus.socket
  User svc:    $([ "$DAEMON" = broker ] && echo "/etc/systemd/user/dbus.service -> /usr/lib/systemd/user/dbus-broker.service" || echo "(default: /usr/lib/systemd/user/dbus.service from dbus-user-session)")
  Policy:      /etc/dbus-1/system.conf -> /usr/share/dbus-1/system.conf
               /etc/dbus-1/session.conf -> /usr/share/dbus-1/session.conf
  User+group:  messagebus:x:101:101  (locked shadow)
  Spool:       /var/lib/dbus  (chown via tmpfiles.d at boot)
  Runtime:     /run/dbus      (created via tmpfiles.d at boot)

Wires into DE0-S:
  systemd-logind Wants=dbus.service is now satisfied; logind
  CreateSession() succeeds -> XDG_RUNTIME_DIR is populated at /run/user/1000.

Next step:
  DE0-G : Mesa + libdrm + fonts catalog tier.
EOF

# Pin mtimes for determinism.
find "$OVERLAY/etc/dbus-1" "$OVERLAY/etc/systemd" "$OVERLAY/etc/tmpfiles.d" \
     "$OVERLAY/var/lib/dbus" "$OVERLAY/run/dbus" \
     "$OVERLAY/etc/passwd" "$OVERLAY/etc/group" \
     "$SENTINEL" \
     -exec touch -h --date="@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true

log "DE0-D overlay-plant DONE (sentinel: $SENTINEL)"
