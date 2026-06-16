#!/usr/bin/env bash
# t_dem2_login_selection.sh -- DEM2 SDDM login-time DE selection integration test.
#
# Exercises recipes/reproos-mvp-config/build-mvp-multi-de-sddm-iso.sh
# against a scratch overlay and asserts the DEM2 selection model is in
# place: one SDDM greeter, NO repro-de-select.service, all 3 wayland
# sessions enumerable from /usr/share/wayland-sessions/.
#
# What this test DOES gate:
#   - All 3 per-DE sentinels are present after the composer runs.
#   - /etc/wayland-sessions/{hyprland,gnome,plasmawayland}.desktop are
#     present (per-DE builders own these).
#   - /usr/share/wayland-sessions/{hyprland,gnome,plasmawayland}.desktop
#     mirrors land (DEM2 composer; freedesktop canonical path SDDM
#     enumerates).
#   - Each .desktop file at /usr/share/wayland-sessions/ has an Exec=
#     line pointing at /usr/local/bin/<shim> AND a Name= line.
#   - No NAME= collisions across the 3 sessions.
#   - /etc/sddm.conf:
#       * Has [General] DisplayServer=wayland.
#       * Has [Wayland] EnableHiDPI=false.
#       * Does NOT have [Autologin] section (DEM1's DE-K1 had it; DEM2
#         strips it so the greeter UI surfaces).
#   - SDDM systemd unit is present in the catalog store + the
#     /etc/systemd/system/multi-user.target.wants/sddm.service activation
#     symlink is present.
#   - /etc/systemd/system/display-manager.service is a symlink that
#     points at the SDDM unit (no DEM1-style selector indirection).
#   - DEM1-specific artefacts are NOT present:
#       * No /etc/systemd/system/repro-de-select.service.
#       * No /usr/local/sbin/repro-de-select.sh.
#       * No /etc/systemd/system/multi-user.target.wants/repro-de-select.service.
#   - GDM activation symlink is REMOVED (avoid greeter race).
#   - /etc/profile.d/reproos-libpath.sh contains paths from all 3 DEs
#     (same composition pattern as DEM1).
#   - The DEM2 sentinel /var/lib/reproos-dem2-multi-de-sddm-done lands.
#   - Re-applying is a no-op (sentinel short-circuit).
#
# What this test does NOT gate (covered by the optional vm-harness test):
#   - Booting the ISO and verifying the SDDM greeter UI lists 3 sessions.
#   - Actual DE banner attempts (blocked by cascade G + linker cascade).
#
# Exit:
#   0 = PASS, 1 = test FAIL, 2 = SKIP (host missing required tools).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RECIPE_SH="$REPO_ROOT/recipes/reproos-mvp-config/build-mvp-multi-de-sddm-iso.sh"
CATALOG_ROOT="$REPO_ROOT/recipes/catalog/linux"
[ -f "$RECIPE_SH" ] || { echo "FAIL: recipe missing: $RECIPE_SH" >&2; exit 1; }
[ -d "$CATALOG_ROOT" ] || { echo "FAIL: catalog dir missing: $CATALOG_ROOT" >&2; exit 1; }
[ -x "$RECIPE_SH" ] || chmod +x "$RECIPE_SH" 2>/dev/null || true

# Required tools for the composer (it transitively calls the three
# per-DE builders, each of which uses dpkg-deb / curl / sha256sum).
for t in python3 sha256sum stat dpkg-deb curl; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "SKIP: required tool '$t' not on PATH"
    exit 2
  fi
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dem2-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
OVERLAY="$WORKDIR/overlay"
VENDORED="$WORKDIR/vendored"
mkdir -p "$OVERLAY" "$VENDORED"

ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Stage A: apply the composer.
# ---------------------------------------------------------------------------

bash "$RECIPE_SH" \
  --overlay-dir "$OVERLAY" \
  --catalog-root "$CATALOG_ROOT" \
  --vendored "$VENDORED" \
  --allow-online \
  --verbose \
  >"$WORKDIR/apply.log" 2>&1 || {
    tail -100 "$WORKDIR/apply.log" >&2
    fail "DEM2 composer apply failed"
}
ok "DEM2 composer applied to $OVERLAY"

# ---------------------------------------------------------------------------
# Stage B: per-DE sentinels.
# ---------------------------------------------------------------------------

for sent in reproos-de-hyprland-done reproos-de-gnome-done reproos-de-plasma-done; do
  [ -f "$OVERLAY/var/lib/$sent" ] || fail "per-DE sentinel missing: $sent"
done
ok "all 3 per-DE sentinels present (hyprland, gnome, plasma)"

# ---------------------------------------------------------------------------
# Stage C: /etc/wayland-sessions/*.desktop (per-DE builders).
# ---------------------------------------------------------------------------

for s in hyprland gnome plasmawayland; do
  d="$OVERLAY/etc/wayland-sessions/$s.desktop"
  [ -f "$d" ] || fail "/etc/wayland-sessions/$s.desktop missing"
done
ok "/etc/wayland-sessions/{hyprland,gnome,plasmawayland}.desktop all present"

# ---------------------------------------------------------------------------
# Stage D: /usr/share/wayland-sessions/*.desktop (DEM2 composer mirror;
# SDDM canonical search path).
# ---------------------------------------------------------------------------

declare -A SESSION_EXEC=(
  [hyprland]="/usr/local/bin/repro-start-hyprland.sh"
  [gnome]="/usr/local/bin/repro-start-gnome.sh"
  [plasmawayland]="/usr/local/bin/repro-start-plasma.sh"
)

for s in hyprland gnome plasmawayland; do
  d="$OVERLAY/usr/share/wayland-sessions/$s.desktop"
  [ -f "$d" ] || fail "/usr/share/wayland-sessions/$s.desktop missing (DEM2 mirror)"
  grep -q "^Exec=${SESSION_EXEC[$s]}" "$d" || \
    fail "$s mirror: Exec= line missing or wrong (expected ${SESSION_EXEC[$s]})"
  grep -q "^Name=" "$d" || fail "$s mirror: Name= line missing"
  exec_target="${SESSION_EXEC[$s]}"
  [ -f "$OVERLAY$exec_target" ] || fail "$s session shim missing: $exec_target"
done
ok "/usr/share/wayland-sessions/*.desktop mirrors present + Exec= lines point at /usr/local/bin/ shims"

# Verify no NAME collisions: 3 distinct files, 3 distinct DesktopNames.
declare -A seen_names
for d in "$OVERLAY"/usr/share/wayland-sessions/*.desktop; do
  name="$(grep -E '^Name=' "$d" | head -1 | cut -d= -f2)"
  [ -n "$name" ] || fail "wayland-session file lacks Name=: $d"
  if [ -n "${seen_names[$name]:-}" ]; then
    fail "wayland-session Name= collision: '$name' (in $d AND ${seen_names[$name]})"
  fi
  seen_names["$name"]="$d"
done
ok "no Name= collisions across the 3 wayland-session entries"

# ---------------------------------------------------------------------------
# Stage E: /etc/sddm.conf shape.
# ---------------------------------------------------------------------------

SDDM_CONF="$OVERLAY/etc/sddm.conf"
[ -f "$SDDM_CONF" ] || fail "/etc/sddm.conf missing"

# [General] DisplayServer=wayland.
grep -q "^\[General\]" "$SDDM_CONF" || fail "sddm.conf missing [General] section"
grep -q "^DisplayServer=wayland" "$SDDM_CONF" || \
  fail "sddm.conf missing DisplayServer=wayland"

# [Wayland] EnableHiDPI=false.
grep -q "^\[Wayland\]" "$SDDM_CONF" || fail "sddm.conf missing [Wayland] section"
grep -q "^EnableHiDPI=false" "$SDDM_CONF" || \
  fail "sddm.conf missing EnableHiDPI=false"

# NO [Autologin] (DEM2's key delta vs DE-K1).
if grep -qE "^\[Autologin\]" "$SDDM_CONF"; then
  echo "FAIL: sddm.conf still has [Autologin] section (DEM2 should strip)" >&2
  grep -nE "^\[" "$SDDM_CONF" >&2
  exit 1
fi
# Also: no User= line (which DE-K1's Autologin block planted) at the top
# level. Catch the case where Autologin's body slipped in without its
# header.
if grep -qE "^User=repro" "$SDDM_CONF"; then
  fail "sddm.conf still has 'User=repro' (autologin remnant)"
fi
if grep -qE "^Session=plasmawayland.desktop" "$SDDM_CONF"; then
  fail "sddm.conf still has 'Session=plasmawayland.desktop' (autologin remnant)"
fi
ok "/etc/sddm.conf: DisplayServer=wayland + EnableHiDPI=false + no [Autologin]"

# ---------------------------------------------------------------------------
# Stage F: display-manager.service -> sddm.service (direct, no DEM1
# selector).
# ---------------------------------------------------------------------------

DM_LINK="$OVERLAY/etc/systemd/system/display-manager.service"
[ -L "$DM_LINK" ] || fail "/etc/systemd/system/display-manager.service is not a symlink (DEM2 wires it directly)"
dm_target="$(readlink "$DM_LINK")"
case "$dm_target" in
  */sddm.service) ;;
  *) fail "display-manager.service does not target sddm.service (got: $dm_target)" ;;
esac
# Verify the symlink target file exists at the rootfs-relative path
# (resolve against $OVERLAY).
case "$dm_target" in
  /*) abs_target="$OVERLAY$dm_target" ;;
  *)  abs_target="$OVERLAY/etc/systemd/system/$dm_target" ;;
esac
[ -f "$abs_target" ] || fail "display-manager.service target missing in overlay: $dm_target"
ok "/etc/systemd/system/display-manager.service -> $dm_target (sddm.service)"

# SDDM activation symlink (DE-K1 owns; DEM2 keeps).
SDDM_ACT="$OVERLAY/etc/systemd/system/multi-user.target.wants/sddm.service"
[ -L "$SDDM_ACT" ] || [ -e "$SDDM_ACT" ] || \
  fail "multi-user.target.wants/sddm.service activation missing"
ok "multi-user.target.wants/sddm.service activation present"

# ---------------------------------------------------------------------------
# Stage G: DEM1-specific artefacts MUST NOT be present.
# ---------------------------------------------------------------------------

for stale in \
  /etc/systemd/system/repro-de-select.service \
  /etc/systemd/system/multi-user.target.wants/repro-de-select.service \
  /usr/local/sbin/repro-de-select.sh; do
  abs="$OVERLAY$stale"
  if [ -e "$abs" ] || [ -L "$abs" ]; then
    fail "DEM1 artefact present (DEM2 should not plant): $stale"
  fi
done
ok "no DEM1 artefacts (repro-de-select.service / .sh) planted"

# ---------------------------------------------------------------------------
# Stage H: GDM activation symlink REMOVED (DEM2 keeps SDDM only).
# ---------------------------------------------------------------------------

GDM_ACT="$OVERLAY/etc/systemd/system/multi-user.target.wants/gdm.service"
if [ -L "$GDM_ACT" ] || [ -e "$GDM_ACT" ]; then
  fail "multi-user.target.wants/gdm.service still present (DEM2 should remove; SDDM-only)"
fi
ok "multi-user.target.wants/gdm.service removed (no greeter race)"

# ---------------------------------------------------------------------------
# Stage I: /etc/profile.d/reproos-libpath.sh composes all 3 DEs.
#
# Same composition assertion as DEM1: every catalog with a
# usr/lib/x86_64-linux-gnu store dir must appear as a path component.
# ---------------------------------------------------------------------------

LIBPATH="$OVERLAY/etc/profile.d/reproos-libpath.sh"
[ -f "$LIBPATH" ] || fail "$LIBPATH missing"

grep -q "^export LD_LIBRARY_PATH=" "$LIBPATH" || \
  fail "reproos-libpath.sh does not export LD_LIBRARY_PATH"

python3 - "$OVERLAY" "$LIBPATH" <<'PYEOF' || fail "libpath composition check failed"
import os, re, sys, json
overlay, libpath = sys.argv[1], sys.argv[2]
with open(libpath) as f:
    body = f.read()

m = re.search(r'^export LD_LIBRARY_PATH="([^"$]*)', body, re.MULTILINE)
if not m:
    print("reproos-libpath.sh: cannot extract LD_LIBRARY_PATH literal")
    sys.exit(1)
paths_lit = m.group(1)
paths = [p for p in paths_lit.split(":") if p]
path_set = set(paths)

store_root = os.path.join(overlay, "opt/reproos-linux/store")
expected = set()
present_per_de = {"DE-H1": set(), "DE-G1": set(), "DE-K1": set()}
de_h1 = {"sway","waybar","wlroots","foot","libwayland-cursor","libpixman",
         "libcairo2","libxcb1"}
de_g1 = {"gdm","gnome-shell","mutter","gnome-session","gjs","libmozjs91",
         "libgtk4","gsettings-desktop-schemas"}
de_k1 = {"sddm","kwin","plasma-workspace","plasma-framework","qt5-base",
         "qt5-declarative","kf5-core","kf5-frameworks"}

with open(os.path.join(store_root, "registry.json")) as f:
    reg = json.load(f)
by_hash = {e["store_hash"]: e["name"] for e in reg}

for h in os.listdir(store_root):
    full = os.path.join(store_root, h)
    if not os.path.isdir(full):
        continue
    name = by_hash.get(h, "<unknown>")
    for libdir in ("usr/lib/x86_64-linux-gnu", "lib/x86_64-linux-gnu",
                   "usr/lib/x86_64-linux-gnu/mutter-10"):
        if os.path.isdir(os.path.join(full, libdir)):
            expected_path = "/opt/reproos-linux/store/%s/%s" % (h, libdir)
            expected.add(expected_path)
            if name in de_h1:
                present_per_de["DE-H1"].add(name)
            elif name in de_g1:
                present_per_de["DE-G1"].add(name)
            elif name in de_k1:
                present_per_de["DE-K1"].add(name)

missing = sorted(expected - path_set)
if missing:
    print("composition failure: libpath missing %d catalog lib dirs:" % len(missing))
    for p in missing[:20]:
        print("  " + p)
    sys.exit(1)

for de, contribs in present_per_de.items():
    if not contribs:
        print("composition failure: %s contributed zero catalog lib dirs to libpath" % de)
        sys.exit(1)

print("composition OK: %d catalog lib dirs present; DE-H1 from %d, DE-G1 from %d, DE-K1 from %d"
      % (len(expected), len(present_per_de["DE-H1"]),
         len(present_per_de["DE-G1"]), len(present_per_de["DE-K1"])))
PYEOF
ok "/etc/profile.d/reproos-libpath.sh contains paths from all 3 DEs (composition not last-writer-wins)"

# ---------------------------------------------------------------------------
# Stage J: DEM2 sentinel.
# ---------------------------------------------------------------------------

DEM2_SENT="$OVERLAY/var/lib/reproos-dem2-multi-de-sddm-done"
[ -f "$DEM2_SENT" ] || fail "DEM2 sentinel missing"
grep -q "DEM2" "$DEM2_SENT" || fail "DEM2 sentinel body missing 'DEM2' marker"
grep -q "DE-H1" "$DEM2_SENT" || fail "DEM2 sentinel missing DE-H1 record"
grep -q "DE-G1" "$DEM2_SENT" || fail "DEM2 sentinel missing DE-G1 record"
grep -q "DE-K1" "$DEM2_SENT" || fail "DEM2 sentinel missing DE-K1 record"
grep -q "SDDM" "$DEM2_SENT" || fail "DEM2 sentinel missing SDDM reference"
ok "DEM2 sentinel present + records all 3 DEs + SDDM choice"

# ---------------------------------------------------------------------------
# Stage K: idempotency.
# ---------------------------------------------------------------------------

bash "$RECIPE_SH" \
  --overlay-dir "$OVERLAY" \
  --catalog-root "$CATALOG_ROOT" \
  --vendored "$VENDORED" \
  >"$WORKDIR/apply2.log" 2>&1 || {
    tail -40 "$WORKDIR/apply2.log" >&2
    fail "idempotent re-apply failed"
}
grep -q "sentinel present" "$WORKDIR/apply2.log" || {
  tail -40 "$WORKDIR/apply2.log" >&2
  fail "re-apply did not short-circuit on sentinel"
}
ok "second invocation short-circuits on sentinel"

echo "PASS: t_dem2_login_selection.sh"
exit 0
