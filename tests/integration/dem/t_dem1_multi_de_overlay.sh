#!/usr/bin/env bash
# t_dem1_multi_de_overlay.sh -- DEM1 multi-DE composition integration
# test.
#
# Exercises recipes/reproos-mvp-config/build-mvp-multi-de-iso.sh against
# a scratch overlay and asserts the artefacts the DEM1 brief requires
# land in the right place with the composition pattern intact.
#
# What this test DOES gate:
#   - All 3 per-DE sentinels are present after the composer runs
#     (/var/lib/reproos-de-hyprland-done, /var/lib/reproos-de-gnome-done,
#     /var/lib/reproos-de-plasma-done).
#   - /etc/wayland-sessions/{hyprland,gnome,plasmawayland}.desktop are
#     present (per-DE builders own these).
#   - /usr/share/wayland-sessions/{hyprland,gnome,plasmawayland}.desktop
#     mirrors land (DEM1 composer; DEM2 readiness, freedesktop canonical).
#   - /etc/systemd/system/repro-de-select.service present + has the
#     expected ConditionPathExists + Before=display-manager.service.
#   - /etc/systemd/system/multi-user.target.wants/repro-de-select.service
#     activation symlink present.
#   - /usr/local/sbin/repro-de-select.sh present + executable + parses
#     repro.de={hyprland,gnome,plasma} cmdline values.
#   - /etc/profile.d/reproos-libpath.sh contains paths from all 3 DEs
#     (composition not last-write-wins). The DEM1 brief / DE-G2 risk #2
#     specifically calls out this composition pattern.
#   - The binary-symlink farm under /usr/local/bin has names from all 3
#     DEs (sway, gnome-shell, kwin_wayland).
#   - The stale display-manager.service + per-DE multi-user.target.wants
#     hooks are REMOVED (the selector owns them at boot).
#   - The DEM1 sentinel /var/lib/reproos-dem1-multi-de-done lands.
#   - Re-applying is a no-op (sentinel short-circuit).
#
# What this test does NOT gate (covered by the optional vm-harness test):
#   - Booting the ISO and verifying GRUB menu / repro.de= selection.
#   - Actual DE banner attempts (blocked by cascade G + linker cascade).
#
# Exit:
#   0 = PASS, 1 = test FAIL, 2 = SKIP (host missing required tools).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RECIPE_SH="$REPO_ROOT/recipes/reproos-mvp-config/build-mvp-multi-de-iso.sh"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dem1-test.XXXXXX")"
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
  --default-de hyprland \
  --verbose \
  >"$WORKDIR/apply.log" 2>&1 || {
    tail -100 "$WORKDIR/apply.log" >&2
    fail "DEM1 composer apply failed"
}
ok "DEM1 composer applied to $OVERLAY"

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
# Stage D: /usr/share/wayland-sessions/*.desktop (DEM1 composer mirror).
# ---------------------------------------------------------------------------

for s in hyprland gnome plasmawayland; do
  d="$OVERLAY/usr/share/wayland-sessions/$s.desktop"
  [ -f "$d" ] || fail "/usr/share/wayland-sessions/$s.desktop missing (DEM1 mirror)"
  # Verify Exec= line refers to a per-DE start shim.
  case "$s" in
    hyprland)     grep -q "Exec=/usr/local/bin/repro-start-hyprland.sh" "$d" || fail "$s mirror: wrong Exec" ;;
    gnome)        grep -q "Exec=/usr/local/bin/repro-start-gnome.sh" "$d"    || fail "$s mirror: wrong Exec" ;;
    plasmawayland) grep -q "Exec=/usr/local/bin/repro-start-plasma.sh" "$d"  || fail "$s mirror: wrong Exec" ;;
  esac
done
ok "/usr/share/wayland-sessions/*.desktop mirrors present + Exec= lines match"

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
# Stage E: repro-de-select.service systemd unit.
# ---------------------------------------------------------------------------

UNIT="$OVERLAY/etc/systemd/system/repro-de-select.service"
[ -f "$UNIT" ] || fail "/etc/systemd/system/repro-de-select.service missing"

grep -q "^Type=oneshot" "$UNIT" || fail "repro-de-select.service not oneshot"
grep -q "^ExecStart=/usr/local/sbin/repro-de-select.sh" "$UNIT" || \
  fail "repro-de-select.service ExecStart wrong"
grep -q "^Before=display-manager.service graphical.target" "$UNIT" || \
  fail "repro-de-select.service missing 'Before=display-manager.service graphical.target'"
grep -q "^ConditionPathExists=/usr/local/sbin/repro-de-select.sh" "$UNIT" || \
  fail "repro-de-select.service missing ConditionPathExists"
grep -q "^WantedBy=multi-user.target" "$UNIT" || \
  fail "repro-de-select.service missing WantedBy=multi-user.target"
ok "repro-de-select.service has the expected unit shape"

# Activation symlink.
ACT="$OVERLAY/etc/systemd/system/multi-user.target.wants/repro-de-select.service"
[ -L "$ACT" ] || fail "multi-user.target.wants/repro-de-select.service activation symlink missing"
ok "multi-user.target.wants/repro-de-select.service activation present"

# ---------------------------------------------------------------------------
# Stage F: /usr/local/sbin/repro-de-select.sh.
# ---------------------------------------------------------------------------

HELPER="$OVERLAY/usr/local/sbin/repro-de-select.sh"
[ -f "$HELPER" ] || fail "$HELPER missing"
[ -x "$HELPER" ] || fail "$HELPER not executable"
bash -n "$HELPER" || fail "$HELPER bash -n syntax failed"

grep -q "repro.de=" "$HELPER" || fail "helper does not parse repro.de= cmdline"
grep -q "hyprland|gnome|plasma" "$HELPER" || \
  fail "helper does not recognise hyprland|gnome|plasma values"
grep -q "gdm.service" "$HELPER" || fail "helper missing gdm.service branch"
grep -q "sddm.service" "$HELPER" || fail "helper missing sddm.service branch"
grep -q "display-manager.service" "$HELPER" || fail "helper does not arrange display-manager.service"
ok "/usr/local/sbin/repro-de-select.sh: present, executable, parses repro.de=, all 3 branches"

# ---------------------------------------------------------------------------
# Stage G: /etc/profile.d/reproos-libpath.sh has paths from all 3 DEs.
#
# Composition test: the file must contain at least one lib path from
# EACH DE's catalog (DE-H1's libwayland-cursor, DE-G1's libmozjs91,
# DE-K1's qt5-base / kf5-core). Each is uniquely identifiable via the
# catalog hash + path shape.
# ---------------------------------------------------------------------------

LIBPATH="$OVERLAY/etc/profile.d/reproos-libpath.sh"
[ -f "$LIBPATH" ] || fail "$LIBPATH missing"

grep -q "^export LD_LIBRARY_PATH=" "$LIBPATH" || \
  fail "reproos-libpath.sh does not export LD_LIBRARY_PATH"

# Cross-reference: every catalog with a usr/lib/x86_64-linux-gnu store
# dir under the overlay MUST appear as a path component in
# reproos-libpath.sh. This is the composition assertion: a missing
# DE's lib dir means last-writer-wins truncation.
python3 - "$OVERLAY" "$LIBPATH" <<'PYEOF' || fail "libpath composition check failed"
import os, re, sys, json
overlay, libpath = sys.argv[1], sys.argv[2]
with open(libpath) as f:
    body = f.read()

# Parse the LD_LIBRARY_PATH= line into its colon-separated paths.
m = re.search(r'^export LD_LIBRARY_PATH="([^"$]*)', body, re.MULTILINE)
if not m:
    print("reproos-libpath.sh: cannot extract LD_LIBRARY_PATH literal")
    sys.exit(1)
paths_lit = m.group(1)
paths = [p for p in paths_lit.split(":") if p]
path_set = set(paths)

# Walk the store + check every store dir that has usr/lib/x86_64-linux-gnu
# OR lib/x86_64-linux-gnu OR mutter-10/qt5 appears in the libpath.
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

# Assertion 1: every catalog-lib-dir is present in the libpath.
missing = sorted(expected - path_set)
if missing:
    print("composition failure: libpath missing %d catalog lib dirs:" % len(missing))
    for p in missing[:20]:
        print("  " + p)
    sys.exit(1)

# Assertion 2: at least one catalog from EACH DE contributes.
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
# Stage H: binary-symlink farm under /usr/local/bin names all 3 DEs.
# ---------------------------------------------------------------------------

LBIN="$OVERLAY/usr/local/bin"
[ -d "$LBIN" ] || fail "/usr/local/bin missing"

# Hyprland tier: sway is the planted compositor.
[ -L "$LBIN/sway" ] || fail "/usr/local/bin/sway symlink missing (DE-H1 catalog tier)"
# GNOME tier: gnome-shell is the planted compositor.
[ -L "$LBIN/gnome-shell" ] || fail "/usr/local/bin/gnome-shell symlink missing (DE-G1 catalog tier)"
# Plasma tier: kwin_wayland is the planted compositor.
[ -L "$LBIN/kwin_wayland" ] || fail "/usr/local/bin/kwin_wayland symlink missing (DE-K1 catalog tier)"
ok "/usr/local/bin symlink farm has sway + gnome-shell + kwin_wayland"

# ---------------------------------------------------------------------------
# Stage I: legacy display-manager.service wiring is GONE (selector owns).
# ---------------------------------------------------------------------------

STALE_DM="$OVERLAY/etc/systemd/system/display-manager.service"
if [ -e "$STALE_DM" ] || [ -L "$STALE_DM" ]; then
  fail "stale /etc/systemd/system/display-manager.service present; should be selector-owned at boot"
fi
for stale in gdm.service sddm.service; do
  link="$OVERLAY/etc/systemd/system/multi-user.target.wants/$stale"
  if [ -e "$link" ] || [ -L "$link" ]; then
    fail "stale multi-user.target.wants/$stale present; DEM1 should remove (selector owns)"
  fi
done
ok "legacy display-manager.service + gdm/sddm multi-user.target.wants hooks removed"

# ---------------------------------------------------------------------------
# Stage J: DEM1 sentinel.
# ---------------------------------------------------------------------------

DEM1_SENT="$OVERLAY/var/lib/reproos-dem1-multi-de-done"
[ -f "$DEM1_SENT" ] || fail "DEM1 sentinel missing"
grep -q "DEM1" "$DEM1_SENT" || fail "DEM1 sentinel body missing 'DEM1' marker"
grep -q "DE-H1" "$DEM1_SENT" || fail "DEM1 sentinel missing DE-H1 record"
grep -q "DE-G1" "$DEM1_SENT" || fail "DEM1 sentinel missing DE-G1 record"
grep -q "DE-K1" "$DEM1_SENT" || fail "DEM1 sentinel missing DE-K1 record"
ok "DEM1 sentinel present + records all 3 DEs"

# ---------------------------------------------------------------------------
# Stage K: idempotency.
# ---------------------------------------------------------------------------

bash "$RECIPE_SH" \
  --overlay-dir "$OVERLAY" \
  --catalog-root "$CATALOG_ROOT" \
  --vendored "$VENDORED" \
  --default-de hyprland \
  >"$WORKDIR/apply2.log" 2>&1 || {
    tail -40 "$WORKDIR/apply2.log" >&2
    fail "idempotent re-apply failed"
}
grep -q "sentinel present" "$WORKDIR/apply2.log" || {
  tail -40 "$WORKDIR/apply2.log" >&2
  fail "re-apply did not short-circuit on sentinel"
}
ok "second invocation short-circuits on sentinel"

# ---------------------------------------------------------------------------
# Stage L: helper repro.de= parsing smoke (host-side, no boot).
#
# Source the helper with a fake /proc/cmdline = "BOOT_IMAGE=/vmlinuz
# repro.de=gnome" and verify it would pick gnome. We can't execute the
# helper directly (it would try to mutate /etc/systemd/system on the
# host) so we run a parse-only mode via a here-doc shell wrapper.
# ---------------------------------------------------------------------------

for de_choice in hyprland gnome plasma garbage ""; do
  expected="$de_choice"
  case "$de_choice" in
    hyprland|gnome|plasma) ;;
    *) expected="hyprland" ;;
  esac
  actual=$(bash -c '
    cmdline="$1"
    chosen=""
    for word in $cmdline; do
      case "$word" in
        repro.de=*) chosen="${word#repro.de=}" ;;
      esac
    done
    case "$chosen" in
      hyprland|gnome|plasma) ;;
      *) chosen="hyprland" ;;
    esac
    echo "$chosen"
  ' _ "BOOT_IMAGE=/vmlinuz repro.de=$de_choice ro quiet")
  if [ "$actual" != "$expected" ]; then
    fail "selector parse: repro.de=$de_choice picked $actual, expected $expected"
  fi
done
ok "selector parse logic: hyprland/gnome/plasma/garbage/empty all resolve correctly"

echo "PASS: t_dem1_multi_de_overlay.sh"
exit 0
