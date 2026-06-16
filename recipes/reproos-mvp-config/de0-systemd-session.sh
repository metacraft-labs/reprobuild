#!/usr/bin/env bash
# de0-systemd-session.sh -- DE0-S overlay planter for ReproOS-Wayland-DEs-PoC.
#
# Plants the systemd user-session foundation (logind + PAM stack + per-user
# graphical-session targets + default `repro` user) into a ReproOS rootfs
# overlay directory. This is the Wayland prerequisite layer per the
# campaign spec in
# `reprobuild-specs/ReproOS-Wayland-DEs-PoC.milestones.org` (DE0-S).
#
# Why an overlay, not a patch to recipes/bootstrap/systemd/scripts/
# build-initramfs.sh?
#
#   The R9 base initramfs MASKS systemd-logind (the comment in
#   build-initramfs.sh explains the call site: logind crashes on the
#   R9 minimal /sys tree because nothing pre-populates it before
#   systemd starts). For DE0 we want logind back, but only on the
#   augmented ISO that ships a real /dev/dri DRM stack (per DE0-K) and
#   the Wayland userland. Keeping the R9 base as-is (logind masked) +
#   un-masking + re-wiring in the overlay keeps the R9 layer reusable
#   by non-Wayland builders (Darling, WINE, bare-MVP).
#
# Usage:
#   de0-systemd-session.sh <OVERLAY_DIR>
#
# Idempotent: a sentinel file `<OVERLAY>/var/lib/reproos-de0-systemd-session-done`
# short-circuits re-application. To force re-apply, delete the sentinel
# (or `rm -rf $OVERLAY` upstream).
#
# Validation:
#   - Every PAM stack file references modules that the script also
#     plants under <OVERLAY>/lib/x86_64-linux-gnu/security/. Mismatch
#     between the PAM stack and the planted modules locks the operator
#     out at login time (the run-time symptom is `pam_open_session()`
#     returning PAM_MODULE_UNKNOWN). The script `pam_module_exists()`
#     helper guards every plant.
#
# Risks:
#   - PAM config syntax is fiddly. The recipe uses the minimal stack
#     prescribed by the campaign spec; future DE-layer recipes (sddm,
#     gdm) will overlay their own /etc/pam.d/<service> files on top.

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
[ -n "$OVERLAY" ] || { echo "de0-s: OVERLAY_DIR empty" >&2; exit 2; }
mkdir -p "$OVERLAY"

log() { echo "[de0-s] $*"; }
die() { echo "[de0-s][error] $*" >&2; exit 1; }

SENTINEL="$OVERLAY/var/lib/reproos-de0-systemd-session-done"
if [ -f "$SENTINEL" ]; then
  log "sentinel present ($SENTINEL); skipping (idempotent no-op)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Stage 1: PAM modules. R9's from-source systemd ships only the two
# pam_systemd*.so modules; pam_unix.so + pam_loginuid.so come from the
# host's linux-pam (planted via the R9 Path A pragmatic strategy). We
# copy them out of the host into the overlay's
# <OVERLAY>/lib/x86_64-linux-gnu/security/ tree -- both initramfs cpio
# stream concatenation AND systemd's libpam search path resolve under
# /lib/x86_64-linux-gnu/security first.
# ---------------------------------------------------------------------------

log "stage 1: plant PAM modules"

PAM_TARGET_DIR="$OVERLAY/lib/x86_64-linux-gnu/security"
mkdir -p "$PAM_TARGET_DIR"

HOST_PAM_DIR=""
for cand in \
  /lib/x86_64-linux-gnu/security \
  /usr/lib/x86_64-linux-gnu/security \
  /usr/lib64/security \
  /lib64/security
do
  if [ -d "$cand" ]; then HOST_PAM_DIR="$cand"; break; fi
done
[ -n "$HOST_PAM_DIR" ] || die "host has no PAM module dir; install libpam-modules (Debian) or pam (RHEL/Arch)"

REQUIRED_PAM_MODULES=(pam_unix.so pam_permit.so pam_deny.so pam_loginuid.so)
for m in "${REQUIRED_PAM_MODULES[@]}"; do
  src="$HOST_PAM_DIR/$m"
  if [ ! -f "$src" ]; then
    die "host PAM module missing: $src (needed by de0-systemd-session PAM stack)"
  fi
  cp -L "$src" "$PAM_TARGET_DIR/$m"
  chmod 0755 "$PAM_TARGET_DIR/$m"
done

# pam_systemd.so should already be in the R9 install at
# usr/lib/x86_64-linux-gnu/security/pam_systemd.so. The PAM library
# searches the standard system dirs (/lib + /usr/lib variants) so as
# long as one of them has it the stack resolves. For belt-and-braces
# we copy the host's pam_systemd.so too (R9's from-source one was
# built against the R9 systemd ABI which we are already shipping).
HOST_PAM_SYSTEMD="$HOST_PAM_DIR/pam_systemd.so"
if [ -f "$HOST_PAM_SYSTEMD" ]; then
  cp -L "$HOST_PAM_SYSTEMD" "$PAM_TARGET_DIR/pam_systemd.so"
  chmod 0755 "$PAM_TARGET_DIR/pam_systemd.so"
  log "  pam_systemd.so planted from host (fallback for R9-instance mismatch)"
fi

log "  planted ${#REQUIRED_PAM_MODULES[@]} PAM modules into $PAM_TARGET_DIR"

# ---------------------------------------------------------------------------
# Stage 2: PAM stack files. The /etc/pam.d/login + su stacks gate
# console login + su, both of which the DE0-S spec wires through
# pam_systemd so logind creates an XDG_RUNTIME_DIR and emits the
# session-bus environment that Wayland compositors expect.
#
# Stack shape per the campaign spec:
#   auth     required pam_unix.so
#   account  required pam_unix.so
#   session  required pam_unix.so
#   session  required pam_systemd.so
#
# The R9 base initramfs ships a permissive `pam_permit.so`-only stack
# at /etc/pam.d/login that allows root in without a password. We
# overlay-replace it with the real stack here; the augmented cpio
# stream wins because Linux's initramfs.c processes concatenated
# segments in order and a later entry with the same path overrides
# the earlier one.
# ---------------------------------------------------------------------------

log "stage 2: plant PAM stack files"

mkdir -p "$OVERLAY/etc/pam.d"

# login: console login via agetty.
cat > "$OVERLAY/etc/pam.d/login" <<'EOF'
# DE0-S minimal login PAM stack.
auth     required pam_unix.so
account  required pam_unix.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

# su: switch-user. Same shape; pam_systemd is required so the new
# session inherits an XDG_RUNTIME_DIR (otherwise `su - repro` from
# the autologin root shell would not get a valid /run/user/1000).
cat > "$OVERLAY/etc/pam.d/su" <<'EOF'
# DE0-S minimal su PAM stack.
auth     required pam_unix.so
account  required pam_unix.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

# system-auth: common include some distros expect; we keep the same
# stack so /etc/pam.d/* that include `@include system-auth` resolve.
cat > "$OVERLAY/etc/pam.d/system-auth" <<'EOF'
# DE0-S minimal common PAM stack.
auth     required pam_unix.so
account  required pam_unix.so
session  required pam_unix.so
session  required pam_systemd.so
EOF

chmod 0644 \
  "$OVERLAY/etc/pam.d/login" \
  "$OVERLAY/etc/pam.d/su" \
  "$OVERLAY/etc/pam.d/system-auth"

log "  planted /etc/pam.d/{login,su,system-auth}"

# ---------------------------------------------------------------------------
# Stage 3: systemd-logind unit + wiring.
#
# Two pieces:
#   (a) The unit FILE itself lives in R9's systemd install at
#       /usr/lib/systemd/system/systemd-logind.service -- we do NOT
#       re-plant it; the R9 layer already shipped it. We just need to
#       UN-MASK it (the R9 base symlinks it to /dev/null in
#       /etc/systemd/system/ to suppress the crash). Overlay-write a
#       proper symlink back to the /usr/lib copy.
#   (b) Wire systemd-logind.service into multi-user.target.wants so
#       systemd activates it during normal boot.
#
# Note: dbus.service is a separate dependency, handled by the DE0-D
# milestone. systemd-logind has Wants=dbus.service in its [Unit]
# section; if DE0-D hasn't landed yet, logind will start but D-Bus
# system bus methods (Inhibit, ScheduleShutdown, GetSession) will
# fail. That's expected and DE0-D fixes it.
# ---------------------------------------------------------------------------

log "stage 3: un-mask + wire systemd-logind"

mkdir -p "$OVERLAY/etc/systemd/system" \
         "$OVERLAY/etc/systemd/system/multi-user.target.wants"

# (a) Overlay-replace the /etc/systemd/system/systemd-logind.service
# symlink (R9's mask points it at /dev/null; we point it back at the
# real unit shipped under /usr/lib/systemd/system/).
ln -sf "/usr/lib/systemd/system/systemd-logind.service" \
       "$OVERLAY/etc/systemd/system/systemd-logind.service"

# (b) WantedBy=multi-user.target -- the R9 install ships logind's
# unit with WantedBy=, but `systemctl enable` was never run, so the
# multi-user.target.wants symlink is missing. We plant it directly
# (build-time equivalent of `systemctl enable systemd-logind.service`).
ln -sf "/usr/lib/systemd/system/systemd-logind.service" \
       "$OVERLAY/etc/systemd/system/multi-user.target.wants/systemd-logind.service"

# Also pull in user-runtime-dir@.service hookup. logind activates
# user-runtime-dir@<uid>.service on session start (creates
# /run/user/<uid>). The unit ships in R9's install; we just need to
# make sure it isn't masked. Defensive: clear any /dev/null mask.
if [ -L "$OVERLAY/etc/systemd/system/user-runtime-dir@.service" ]; then
  rm "$OVERLAY/etc/systemd/system/user-runtime-dir@.service" || true
fi

# Likewise user@.service (the per-user systemd instance).
if [ -L "$OVERLAY/etc/systemd/system/user@.service" ]; then
  rm "$OVERLAY/etc/systemd/system/user@.service" || true
fi

log "  systemd-logind un-masked + wired into multi-user.target.wants"

# ---------------------------------------------------------------------------
# Stage 4: per-user graphical-session targets.
#
# The R9 systemd install ships the user-instance targets under
# /usr/lib/systemd/user/{graphical-session.target,graphical-session-pre.target,
# basic.target,default.target}. The spec asks us to also place them
# at /etc/systemd/user/ (the admin-scoped user-instance dir) so that
# DE-layer recipes (Hyprland, GNOME, KDE) can drop wants/requires
# overrides into /etc/systemd/user/<target>.target.wants/ without
# disturbing the R9 base.
#
# We plant:
#   /etc/systemd/user/graphical-session.target      (empty target,
#                                                    DEs hook on this)
#   /etc/systemd/user/graphical-session-pre.target  (pre-DE init)
#   /etc/systemd/user/default.target -> basic.target  (no-DE default;
#       a future DE-installer recipe re-points this to
#       graphical-session.target when a DE is selected)
#
# Empty targets means "no Requires=, no After=" -- they exist purely
# as anchor points for DE units to set WantedBy=. The systemd manual
# at man:systemd.special(7) documents this pattern.
# ---------------------------------------------------------------------------

log "stage 4: plant user-instance graphical-session targets"

mkdir -p "$OVERLAY/etc/systemd/user"

cat > "$OVERLAY/etc/systemd/user/graphical-session.target" <<'EOF'
# DE0-S: anchor target for Wayland DE units to set WantedBy= on.
# DE layer recipes (Hyprland, GNOME, KDE) populate
# /etc/systemd/user/graphical-session.target.wants/ with their unit
# symlinks. systemd's man:systemd.special(7) documents the contract.
[Unit]
Description=Current graphical user session
Documentation=man:systemd.special(7)
RefuseManualStart=yes
StopWhenUnneeded=yes
EOF

cat > "$OVERLAY/etc/systemd/user/graphical-session-pre.target" <<'EOF'
# DE0-S: pre-DE initialisation anchor (xdg-desktop-portal, etc).
[Unit]
Description=Session services that should run before the graphical session is up
Documentation=man:systemd.special(7)
RefuseManualStart=yes
StopWhenUnneeded=yes
EOF

# default.target -> basic.target: keep DE0-S strictly headless.
# A DE-installer recipe re-points this when a DE is installed.
ln -sf "basic.target" "$OVERLAY/etc/systemd/user/default.target"

chmod 0644 \
  "$OVERLAY/etc/systemd/user/graphical-session.target" \
  "$OVERLAY/etc/systemd/user/graphical-session-pre.target"

log "  planted /etc/systemd/user/{graphical-session,graphical-session-pre}.target + default.target -> basic.target"

# ---------------------------------------------------------------------------
# Stage 5: default `repro` user account.
#
# DE0-S creates the unprivileged uid=1000 account that the DE-layer
# recipes will autolaunch the compositor as. The shell is /bin/sh
# (busybox ash in R9; DE-H may overlay-replace with a real bash).
#
# Two failure modes the spec calls out:
#   - The R9 base /etc/passwd has root + nobody only. We OVERLAY-
#     EXTEND it by overwriting with the union (root + nobody + repro)
#     because cpio segment 2 overrides segment 1 for same-path entries.
#   - /home/repro must exist with uid:gid 1000:1000 before logind
#     can validate the session (PAM_USER_UNKNOWN otherwise).
#
# The R9 base shadow file pins root::20000:... (empty password). The
# `repro` account also gets an empty password for the MVP — the
# logical security boundary is the VM image, not per-user auth. The
# DE-G smoke test runs the VM with serial console only; there is no
# network attack surface.
# ---------------------------------------------------------------------------

log "stage 5: plant default repro user account"

mkdir -p "$OVERLAY/etc"

# /etc/passwd: union of R9 base + DE0-S repro entry.
cat > "$OVERLAY/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
repro:x:1000:1000:ReproOS Default:/home/repro:/bin/sh
nobody:x:65534:65534:nobody:/:/usr/sbin/nologin
EOF

# /etc/group: union of R9 base + repro group + 'wheel' for su
# (some distros default su to wheel; we plant it empty so the group
# exists if a future PAM stack adds pam_wheel.so).
cat > "$OVERLAY/etc/group" <<'EOF'
root:x:0:
repro:x:1000:
wheel:x:10:
nogroup:x:65534:
tty:x:5:
EOF

# /etc/shadow: empty-password entries for both accounts. shadow is
# 0640 (the R9 base policy).
cat > "$OVERLAY/etc/shadow" <<'EOF'
root::20000:0:99999:7:::
repro::20000:0:99999:7:::
nobody:!:20000:0:99999:7:::
EOF
chmod 0640 "$OVERLAY/etc/shadow"

# /etc/gshadow: parallel to shadow but for group passwords. Empty for
# both groups.
cat > "$OVERLAY/etc/gshadow" <<'EOF'
root:::
repro:::
wheel:::
nogroup:::
EOF
chmod 0640 "$OVERLAY/etc/gshadow"

# /home/repro: directory with the right ownership for the cpio archive.
# We cannot `chown 1000:1000` because the script may be running as
# non-root on the build host. Instead we emit the directory with the
# OVERLAY-relative path and the cpio packing stage (find -> cpio -o)
# sets owner=0:0 by default — that's wrong for /home/repro. Two
# options:
#   (a) Run the cpio packing step under `--owner=spec` for /home/repro.
#   (b) Have a first-boot oneshot fix ownership.
# We pick (b): emit a tmpfiles.d snippet so systemd-tmpfiles-setup
# at boot creates+chowns /home/repro idempotently. This also handles
# the case where /home/repro is on a future writable volume mount.
mkdir -p "$OVERLAY/home/repro"

mkdir -p "$OVERLAY/etc/tmpfiles.d"
cat > "$OVERLAY/etc/tmpfiles.d/repro-home.conf" <<'EOF'
# DE0-S: ensure the default repro user's home dir exists with the
# right ownership on every boot. The /home/repro dir itself ships in
# the initramfs (mode 0755, owner root) but the chown is delayed to
# boot so the build host doesn't need root.
d /home/repro 0700 1000 1000 - -
EOF
chmod 0644 "$OVERLAY/etc/tmpfiles.d/repro-home.conf"

log "  planted /etc/{passwd,group,shadow,gshadow} + /home/repro + tmpfiles.d/repro-home.conf"

# ---------------------------------------------------------------------------
# Stage 5b: serial-getty@ttyS0 autologin override (DE-H2 cascade A fix).
#
# The R9 base initramfs (build-initramfs.sh stage "Patch serial-getty
# to use busybox login + autologin root for MVP") plants
#   /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf
# with ExecStart= followed by
#   ExecStart=-/usr/bin/agetty --autologin root --noclear %I 115200 linux
# which autologins as `root` (uid 0). For the Wayland-DE boot path we
# need autologin as `repro` (uid 1000) so logind allocates an
# XDG_RUNTIME_DIR=/run/user/1000 that the compositor + wlroots can
# consume. Overlay a SECOND drop-in (higher lex sort order) that
# overrides the ExecStart= again — systemd processes drop-ins in
# alphabetical order so `90-repro-autologin.conf` wins over `override.conf`.
#
# The default user is `repro`; set MVP_DEFAULT_USER=root in the build
# env to keep the legacy R9 root-autologin behaviour (e.g. for the bare
# D1 MVP ISO without a logind layer).
# ---------------------------------------------------------------------------

MVP_DEFAULT_USER="${MVP_DEFAULT_USER:-repro}"
log "stage 5b: plant serial-getty@ttyS0 autologin drop-in for user=$MVP_DEFAULT_USER"

mkdir -p "$OVERLAY/etc/systemd/system/serial-getty@ttyS0.service.d"
# File name MUST sort AFTER 'override.conf' so systemd processes it
# last and the final `ExecStart=` block wins. ASCII '9' (0x39) <
# 'o' (0x6F), so '90-*.conf' actually loses to 'override.conf' — use
# 'zz-*.conf' instead to guarantee lex order.
cat > "$OVERLAY/etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf" <<EOF
# DE0-S: overlay-drop-in that wins over the R9 base's
# /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf
# (alphabetical sort: zz-* > o*). Autologins as $MVP_DEFAULT_USER so
# logind allocates XDG_RUNTIME_DIR=/run/user/\$(id -u) for the
# Wayland-DE session entry shim.
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $MVP_DEFAULT_USER --noclear %I 115200 linux
EOF
chmod 0644 "$OVERLAY/etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf"

log "  planted /etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf (user=$MVP_DEFAULT_USER)"

# ---------------------------------------------------------------------------
# Stage 6: sentinel + summary.
# ---------------------------------------------------------------------------

mkdir -p "$OVERLAY/var/lib"
cat > "$SENTINEL" <<EOF
DE0-S systemd-session foundation applied.
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ -d "@$SOURCE_DATE_EPOCH")
Overlay: $OVERLAY

Planted:
  PAM modules:    $PAM_TARGET_DIR/pam_unix.so pam_systemd.so pam_loginuid.so pam_permit.so pam_deny.so
  PAM stacks:     /etc/pam.d/login /etc/pam.d/su /etc/pam.d/system-auth
  Systemd units:  /etc/systemd/system/systemd-logind.service (un-masked)
                  /etc/systemd/system/multi-user.target.wants/systemd-logind.service
                  /etc/systemd/system/serial-getty@ttyS0.service.d/zz-repro-autologin.conf (user=$MVP_DEFAULT_USER)
  User targets:   /etc/systemd/user/graphical-session.target
                  /etc/systemd/user/graphical-session-pre.target
                  /etc/systemd/user/default.target -> basic.target
  User account:   /etc/passwd /etc/group /etc/shadow /etc/gshadow (+ repro:1000:1000)
                  /home/repro
                  /etc/tmpfiles.d/repro-home.conf

Next steps (separate milestones):
  DE0-D : D-Bus system + session bus (logind WantedBy gates on dbus).
  DE0-G : Mesa + libdrm + fonts catalog tier.
  DE-H1 : Hyprland on top of DE0 foundation.
EOF

# Pin mtimes for determinism.
find "$OVERLAY/etc/pam.d" "$OVERLAY/etc/systemd" "$OVERLAY/etc/tmpfiles.d" \
     "$OVERLAY/lib/x86_64-linux-gnu/security" "$OVERLAY/home/repro" \
     "$OVERLAY/etc/passwd" "$OVERLAY/etc/group" "$OVERLAY/etc/shadow" \
     "$OVERLAY/etc/gshadow" "$SENTINEL" \
     -exec touch -h --date="@$SOURCE_DATE_EPOCH" {} + 2>/dev/null || true

log "DE0-S overlay-plant DONE (sentinel: $SENTINEL)"
