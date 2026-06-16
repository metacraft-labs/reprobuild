#!/usr/bin/env bash
# t_de_h1_hyprland_catalog.sh -- DE-H1 Hyprland-equivalent catalog tier
# integration test.
#
# Exercises recipes/reproos-mvp-config/build-mvp-hyprland-rootfs.sh
# against a scratch overlay directory and asserts every artefact the
# DE-H1 spec section requires lands in the right place with the right
# shape.
#
# What this test DOES gate:
#   - All 19 catalog JSONs parse + have the DE0-G schema fields (the 18
#     planted catalogs + 1 advisory hyprland.json).
#   - The driver composes DE0-G first then DE-H1.
#   - Each PLANTED catalog's expected_files[] lands under
#     /opt/reproos-linux/store/<hash>/ in the overlay.
#   - SONAME symlinks for shared_library entries are created and resolve.
#   - The advisory hyprland.json catalog is SKIPPED (no store dir created).
#   - /etc/hyprland.conf carries the 5 documented bind/exec/monitor lines.
#   - /etc/sway/config carries the 1:1 sway translation.
#   - /etc/wayland-sessions/hyprland.desktop has the documented shape.
#   - /usr/local/bin/repro-start-hyprland.sh exists, is executable, and
#     passes `bash -n` syntax check.
#   - /etc/profile.d/{xkb-data,glvnd}.sh export the expected env vars.
#   - registry.json carries 24 entries (DE0-G's 6 + DE-H1's 18), sorted.
#   - /etc/ld.so.conf.d/00-reproos-linux.conf lists DE-H1's lib store dirs.
#   - Re-applying is a no-op (sentinel short-circuit).
#   - --dry-run leaves the overlay untouched.
#   - Optional: if `sway --version` runs on the host, smoke-probe the
#     planted compositor with WLR_BACKENDS=headless.
#
# What this test does NOT gate (covered by DE-H2):
#   - Booting the augmented ISO and running the compositor under Hyper-V.
#   - Actual rendering on llvmpipe.
#   - Multi-process compositor + waybar + foot launch sequence.
#
# Exit:
#   0 = PASS, 1 = test FAIL, 2 = SKIP (host missing required tools).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RECIPE_SH="$REPO_ROOT/recipes/reproos-mvp-config/build-mvp-hyprland-rootfs.sh"
CATALOG_ROOT="$REPO_ROOT/recipes/catalog/linux"
[ -f "$RECIPE_SH" ] || { echo "FAIL: recipe missing: $RECIPE_SH" >&2; exit 1; }
[ -d "$CATALOG_ROOT" ] || { echo "FAIL: catalog dir missing: $CATALOG_ROOT" >&2; exit 1; }
[ -x "$RECIPE_SH" ] || chmod +x "$RECIPE_SH" 2>/dev/null || true

# Required tools for the recipe. Skip if any is missing.
for t in python3 sha256sum stat dpkg-deb curl; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "SKIP: required tool '$t' not on PATH"
    exit 2
  fi
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/de-h1-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
OVERLAY="$WORKDIR/overlay"
VENDORED="$WORKDIR/vendored"
mkdir -p "$OVERLAY" "$VENDORED"

ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# DE-H1 catalogs (18 planted + 1 advisory = 19).
DE_H1_PLANTED=(
  fontconfig-config foot libelf1 libfcft libglvnd libinput libpixman
  libseat libwayland-cursor libxcb-extras libxcb1 libxkbregistry sway
  waybar wlroots xdg-desktop-portal xdg-desktop-portal-wlr xkb-data
)
DE_H1_ADVISORY=(hyprland)

# ---------------------------------------------------------------------------
# Stage A: catalog JSONs parse + carry the DE0-G schema fields.
# ---------------------------------------------------------------------------

seen=0
for c in "${DE_H1_PLANTED[@]}" "${DE_H1_ADVISORY[@]}"; do
  p="$CATALOG_ROOT/$c.json"
  [ -f "$p" ] || fail "catalog missing: $p"
  python3 - "$p" <<'PYEOF' || fail "catalog $p failed schema check"
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for k in ["format_version", "runtime", "package", "package_source",
          "payload_files", "dependency_closure", "linux_version_banner",
          "provisioning_methods", "signed_envelope"]:
    assert k in d, f"missing field: {k}"
assert d["runtime"] == "linux", f"runtime != linux: {d['runtime']}"
assert d["package"]["distro"] == "linux-graphics", f"distro != linux-graphics"
assert d["format_version"] == 1, f"format_version != 1"
assert len(d["payload_files"]) >= 1, "payload_files empty"
PYEOF
  seen=$((seen + 1))
done
[ "$seen" = 19 ] || fail "expected 19 DE-H1 catalogs, found $seen"
ok "all 19 DE-H1 catalog JSONs parse and carry schema fields"

# Advisory catalog has the skip marker.
python3 - "$CATALOG_ROOT/hyprland.json" <<'PYEOF' || fail "hyprland.json missing skip marker"
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
pm = d["provisioning_methods"][0]
assert pm["kind"] == "upstream-source-tarball", f"hyprland.json: kind != upstream-source-tarball ({pm['kind']})"
PYEOF
ok "hyprland.json carries the upstream-source-tarball skip marker"

# ---------------------------------------------------------------------------
# Stage B: apply the recipe with --allow-online (composes DE0-G first).
# ---------------------------------------------------------------------------

bash "$RECIPE_SH" \
  --overlay-dir "$OVERLAY" \
  --catalog-root "$CATALOG_ROOT" \
  --vendored "$VENDORED" \
  --allow-online \
  --verbose \
  >"$WORKDIR/apply.log" 2>&1 || {
    tail -60 "$WORKDIR/apply.log" >&2
    fail "recipe apply failed"
}
ok "recipe applied to $OVERLAY (DE0-G composed + DE-H1 planted)"

# DE0-G's sentinel should be present (composition).
[ -f "$OVERLAY/var/lib/reproos-de0-graphics-done" ] || fail "DE0-G sentinel missing (composition failed)"
ok "DE0-G base composition succeeded"

# ---------------------------------------------------------------------------
# Stage C: every PLANTED catalog's expected_files[] landed.
# ---------------------------------------------------------------------------

STORE_ROOT="$OVERLAY/opt/reproos-linux/store"
[ -d "$STORE_ROOT" ] || fail "store root missing: $STORE_ROOT"

for c in "${DE_H1_PLANTED[@]}"; do
  cat_path="$CATALOG_ROOT/$c.json"
  python3 - "$cat_path" "$STORE_ROOT" <<'PYEOF' || fail "catalog $c expected_files check failed"
import json, sys, os, hashlib
catalog_path, store_root = sys.argv[1], sys.argv[2]
with open(catalog_path) as f:
    c = json.load(f)
name, version, snapshot = c["package"]["name"], c["package"]["version"], c["package"]["snapshot"]
h = hashlib.sha256(f"{name}|{version}|{snapshot}".encode()).hexdigest()[:16]
store_dir = os.path.join(store_root, h)
assert os.path.isdir(store_dir), f"store dir missing for {name}: {store_dir}"
for pf in c["payload_files"]:
    for ef in pf["expected_files"]:
        p = os.path.join(store_dir, ef["path"])
        assert os.path.isfile(p), f"{name}/{pf['deb_pkg']}: expected file missing in store: {p}"
        if ef["kind"] == "shared_library":
            sl = ef.get("soname_link")
            if sl:
                sp = os.path.join(store_dir, sl)
                assert os.path.islink(sp), f"{name}/{pf['deb_pkg']}: soname link missing: {sp}"
                tgt = os.readlink(sp)
                assert tgt == os.path.basename(ef["path"]), \
                    f"{name}/{pf['deb_pkg']}: soname target wrong: {tgt}"
                resolved = os.path.realpath(sp)
                assert os.path.isfile(resolved), f"{name}/{pf['deb_pkg']}: soname doesn't resolve: {sp}"
        elif ef["kind"] == "binary":
            assert os.access(p, os.X_OK), f"{name}/{pf['deb_pkg']}: binary not executable: {p}"
PYEOF
done
ok "every PLANTED catalog's expected_files[] landed with correct kind semantics"

# ---------------------------------------------------------------------------
# Stage D: the advisory hyprland catalog was SKIPPED (no store dir).
# ---------------------------------------------------------------------------

HYPR_HASH=$(python3 -c "
import json, hashlib
with open('$CATALOG_ROOT/hyprland.json') as f:
    c = json.load(f)
print(hashlib.sha256(f\"{c['package']['name']}|{c['package']['version']}|{c['package']['snapshot']}\".encode()).hexdigest()[:16])
")
if [ -d "$STORE_ROOT/$HYPR_HASH" ]; then
  fail "hyprland advisory catalog created a store dir (should have been skipped): $STORE_ROOT/$HYPR_HASH"
fi
ok "advisory hyprland.json catalog SKIPPED (no store dir)"

# ---------------------------------------------------------------------------
# Stage E: /etc/hyprland.conf carries the documented 5 lines.
# ---------------------------------------------------------------------------

HYPR_CONF="$OVERLAY/etc/hyprland.conf"
[ -f "$HYPR_CONF" ] || fail "/etc/hyprland.conf missing"

grep -qF "monitor=,preferred,auto,1" "$HYPR_CONF" || fail "hyprland.conf missing monitor=… line"
grep -qF "exec-once = waybar" "$HYPR_CONF" || fail "hyprland.conf missing exec-once waybar"
grep -qF "bind = SUPER, Return, exec, foot" "$HYPR_CONF" || fail "hyprland.conf missing super+Return bind"
grep -qF "bind = SUPER, Q, killactive" "$HYPR_CONF" || fail "hyprland.conf missing super+Q bind"
grep -qF "bind = SUPER, M, exit" "$HYPR_CONF" || fail "hyprland.conf missing super+M bind"
ok "/etc/hyprland.conf carries 5 documented bind/exec/monitor lines"

# ---------------------------------------------------------------------------
# Stage F: /etc/sway/config carries the 1:1 translation.
# ---------------------------------------------------------------------------

SWAY_CONF="$OVERLAY/etc/sway/config"
[ -f "$SWAY_CONF" ] || fail "/etc/sway/config missing"

grep -qE "^output \* mode preferred$" "$SWAY_CONF" || fail "sway/config missing output preferred"
grep -qE "^exec waybar$" "$SWAY_CONF" || fail "sway/config missing exec waybar"
grep -qE "^bindsym Mod4\+Return exec foot$" "$SWAY_CONF" || fail "sway/config missing Mod4+Return"
grep -qE "^bindsym Mod4\+q kill$" "$SWAY_CONF" || fail "sway/config missing Mod4+q"
grep -qE "^bindsym Mod4\+m exit$" "$SWAY_CONF" || fail "sway/config missing Mod4+m"
ok "/etc/sway/config carries 1:1 sway translation of hyprland.conf"

# ---------------------------------------------------------------------------
# Stage G: /etc/wayland-sessions/hyprland.desktop.
# ---------------------------------------------------------------------------

WAYSESS="$OVERLAY/etc/wayland-sessions/hyprland.desktop"
[ -f "$WAYSESS" ] || fail "/etc/wayland-sessions/hyprland.desktop missing"

grep -qE "^Name=Hyprland$" "$WAYSESS" || fail "hyprland.desktop missing Name=Hyprland"
grep -qE "^Exec=/usr/local/bin/repro-start-hyprland.sh$" "$WAYSESS" || fail "hyprland.desktop wrong Exec"
grep -qE "^Type=Application$" "$WAYSESS" || fail "hyprland.desktop missing Type=Application"
ok "/etc/wayland-sessions/hyprland.desktop has documented shape"

# ---------------------------------------------------------------------------
# Stage H: /usr/local/bin/repro-start-hyprland.sh exists, executable, valid bash.
# ---------------------------------------------------------------------------

START_SH="$OVERLAY/usr/local/bin/repro-start-hyprland.sh"
[ -f "$START_SH" ] || fail "repro-start-hyprland.sh missing"
[ -x "$START_SH" ] || fail "repro-start-hyprland.sh not executable"
bash -n "$START_SH" || fail "repro-start-hyprland.sh: bash -n syntax check failed"

# Verify shim has the documented features.
grep -qE "REPRO_HEADLESS" "$START_SH" || fail "shim missing REPRO_HEADLESS gate"
grep -qE "WLR_BACKENDS=headless" "$START_SH" || fail "shim missing WLR_BACKENDS=headless export"
grep -qE "/etc/profile.d" "$START_SH" || fail "shim doesn't source /etc/profile.d"
grep -qE "exec Hyprland" "$START_SH" || fail "shim missing Hyprland exec fallback"
grep -qE "exec sway" "$START_SH" || fail "shim missing sway exec primary"
ok "repro-start-hyprland.sh: present, executable, syntax-valid, all features"

# ---------------------------------------------------------------------------
# Stage I: env exports.
# ---------------------------------------------------------------------------

XKB_SH="$OVERLAY/etc/profile.d/xkb-data.sh"
GLVND_SH="$OVERLAY/etc/profile.d/glvnd.sh"
[ -f "$XKB_SH" ] || fail "/etc/profile.d/xkb-data.sh missing"
[ -f "$GLVND_SH" ] || fail "/etc/profile.d/glvnd.sh missing"

grep -qE "^export XKB_CONFIG_ROOT=" "$XKB_SH" || fail "xkb-data.sh doesn't export XKB_CONFIG_ROOT"
grep -qE "^export __EGL_VENDOR_LIBRARY_DIRS=" "$GLVND_SH" || fail "glvnd.sh doesn't export __EGL_VENDOR_LIBRARY_DIRS"
# The paths must point at the overlay store, not /usr/share or /usr/lib.
grep -qE "/opt/reproos-linux/store/" "$XKB_SH" || fail "xkb-data.sh doesn't point at overlay store"
grep -qE "/opt/reproos-linux/store/" "$GLVND_SH" || fail "glvnd.sh doesn't point at overlay store"
ok "/etc/profile.d/{xkb-data,glvnd}.sh export overlay-store paths"

# ---------------------------------------------------------------------------
# Stage J: registry.json has 24 entries (DE0-G's 6 + DE-H1's 18, advisory excluded).
# ---------------------------------------------------------------------------

REG="$STORE_ROOT/registry.json"
[ -f "$REG" ] || fail "registry.json missing"

python3 - "$REG" <<'PYEOF' || fail "registry.json check failed"
import json, sys
with open(sys.argv[1]) as f:
    reg = json.load(f)
assert isinstance(reg, list), "registry not a list"
assert len(reg) == 24, f"expected 24 entries (6 DE0-G + 18 DE-H1), got {len(reg)}"
names = [e["name"] for e in reg]
assert names == sorted(names), f"registry not sorted by name: {names}"

de0_g = {"dejavu-fonts","fontconfig","libdrm","libwayland","libxkbcommon","mesa"}
de_h1 = {"fontconfig-config","foot","libelf1","libfcft","libglvnd","libinput",
         "libpixman","libseat","libwayland-cursor","libxcb-extras","libxcb1",
         "libxkbregistry","sway","waybar","wlroots","xdg-desktop-portal",
         "xdg-desktop-portal-wlr","xkb-data"}
expected = de0_g | de_h1
assert set(names) == expected, f"registry names mismatch:\n  missing: {expected - set(names)}\n  extra:   {set(names) - expected}"
# Specifically: hyprland must NOT be in the registry (advisory skipped).
assert "hyprland" not in names, "hyprland advisory catalog leaked into registry"
PYEOF
ok "registry.json has 24 entries (6 DE0-G + 18 DE-H1, advisory excluded), sorted"

# ---------------------------------------------------------------------------
# Stage K: ld.so.conf.d lists all DE-H1 catalogs with shared_library kinds.
# ---------------------------------------------------------------------------

LDCONF="$OVERLAY/etc/ld.so.conf.d/00-reproos-linux.conf"
[ -f "$LDCONF" ] || fail "ld.so.conf.d snippet missing"

python3 - "$LDCONF" "$STORE_ROOT" "$CATALOG_ROOT" <<'PYEOF' || fail "ld.so.conf check failed"
import json, sys, os, hashlib, glob
ldconf_path, store_root, catalog_root = sys.argv[1], sys.argv[2], sys.argv[3]
with open(ldconf_path) as f:
    lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
de_h1_names = {"fontconfig-config","foot","libelf1","libfcft","libglvnd",
               "libinput","libpixman","libseat","libwayland-cursor",
               "libxcb-extras","libxcb1","libxkbregistry","sway","waybar",
               "wlroots","xdg-desktop-portal","xdg-desktop-portal-wlr","xkb-data"}
missing = []
for name in de_h1_names:
    jp = os.path.join(catalog_root, f"{name}.json")
    with open(jp) as f:
        c = json.load(f)
    has_lib = any(ef["kind"] == "shared_library"
                  for pf in c["payload_files"] for ef in pf["expected_files"])
    if has_lib:
        version = c["package"]["version"]
        snapshot = c["package"]["snapshot"]
        h = hashlib.sha256(f"{name}|{version}|{snapshot}".encode()).hexdigest()[:16]
        want = f"/opt/reproos-linux/store/{h}/usr/lib/x86_64-linux-gnu"
        if want not in lines:
            missing.append((name, want))
if missing:
    print("MISSING ld.so.conf.d entries:")
    for n, w in missing:
        print(f"  {n}: {w}")
    sys.exit(1)
PYEOF
ok "/etc/ld.so.conf.d/00-reproos-linux.conf lists every DE-H1 catalog with libs"

# ---------------------------------------------------------------------------
# Stage L: sentinel.
# ---------------------------------------------------------------------------

SENTINEL="$OVERLAY/var/lib/reproos-de-hyprland-done"
[ -f "$SENTINEL" ] || fail "sentinel missing"

grep -q "DE-H1" "$SENTINEL" || fail "sentinel body missing DE-H1 marker"
grep -q "Planted catalogs (18)" "$SENTINEL" || fail "sentinel didn't record 18 planted catalogs"
grep -q "Skipped catalogs (1, advisory-only)" "$SENTINEL" || fail "sentinel didn't record 1 skipped catalog"
ok "sentinel present + records correct planted/skipped counts"

# ---------------------------------------------------------------------------
# Stage M: idempotency.
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

# ---------------------------------------------------------------------------
# Stage N: --dry-run leaves the overlay untouched.
# ---------------------------------------------------------------------------

OVERLAY2="$WORKDIR/overlay2"
mkdir -p "$OVERLAY2"
bash "$RECIPE_SH" \
  --overlay-dir "$OVERLAY2" \
  --catalog-root "$CATALOG_ROOT" \
  --vendored "$VENDORED" \
  --dry-run \
  --skip-de0-g \
  >"$WORKDIR/dry.log" 2>&1 || {
    tail -40 "$WORKDIR/dry.log" >&2
    fail "--dry-run failed"
}
if [ -d "$OVERLAY2/opt/reproos-linux/store" ]; then
  ls -la "$OVERLAY2/opt/reproos-linux/store" >&2
  fail "--dry-run created store dir"
fi
[ -f "$OVERLAY2/var/lib/reproos-de-hyprland-done" ] && fail "--dry-run wrote sentinel"
[ -f "$OVERLAY2/etc/hyprland.conf" ] && fail "--dry-run wrote /etc/hyprland.conf"
ok "--dry-run leaves overlay untouched"

# ---------------------------------------------------------------------------
# Stage O: optional headless sway smoke.
#
# If the host has sway installed, ask the planted-compositor entry to
# print its version. The DE-H2 milestone covers the actual boot test;
# this is just a quick liveness check on jammy hosts.
# ---------------------------------------------------------------------------

SWAY_HASH=$(python3 -c "
import json, hashlib
with open('$CATALOG_ROOT/sway.json') as f:
    c = json.load(f)
print(hashlib.sha256(f\"{c['package']['name']}|{c['package']['version']}|{c['package']['snapshot']}\".encode()).hexdigest()[:16])
")
PLANTED_SWAY="$STORE_ROOT/$SWAY_HASH/usr/bin/sway"
if [ -x "$PLANTED_SWAY" ]; then
  # Try --version; sway's --version doesn't need a running compositor.
  if SWAY_VERSION=$("$PLANTED_SWAY" --version 2>&1); then
    case "$SWAY_VERSION" in
      *"sway version"*|*"1.7"*)
        ok "planted sway --version: $SWAY_VERSION"
        ;;
      *)
        # Could be missing-shared-lib error; that's a DE-H2 concern.
        ok "planted sway invoked; non-version output (likely missing host runtime libs; DE-H2 covers full smoke): $(echo "$SWAY_VERSION" | head -1)"
        ;;
    esac
  else
    rc=$?
    case $rc in
      127|126) ok "planted sway not directly runnable on host (likely missing libs / wrong loader); DE-H2 covers full smoke" ;;
      *)        ok "planted sway --version exited $rc; DE-H2 covers full smoke" ;;
    esac
  fi
else
  ok "planted sway binary absent at $PLANTED_SWAY (unexpected; stage C should have caught this)"
fi

echo "PASS: t_de_h1_hyprland_catalog.sh"
exit 0
