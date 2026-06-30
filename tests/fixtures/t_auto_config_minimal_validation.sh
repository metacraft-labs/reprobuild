#!/usr/bin/env bash
# M9.R.50.3 -- schema validation gate for auto-config-minimal.toml.
#
# Spec: reprobuild-specs/ReproOS-Image-Recipe.md (M9.R.50.1) section 3.
#
# Runs the SAME toml_get function that build-reproos-image.sh uses
# against the smoke fixture, asserts every required key is present
# with a value of the expected shape, and rejects any unknown
# top-level section.  Keeps the fixture in lock-step with the
# build script's parser.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixtures/auto-config-minimal.toml"

if [ ! -f "$FIXTURE" ]; then
  echo "[t_auto_config_minimal] fixture missing: $FIXTURE" >&2
  exit 64
fi

# Mirror the toml_get from build-reproos-image.sh verbatim.
toml_get() {
  awk -v section="$2" -v key="$3" '
    BEGIN { cur=""; }
    /^[[:space:]]*#/ { next; }
    /^[[:space:]]*$/ { next; }
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "");
      cur=$0;
      next;
    }
    {
      line=$0;
      sub(/[[:space:]]*#.*$/, "", line);
      n=split(line, kv, "=");
      if (n<2) next;
      k=kv[1];
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k);
      v=kv[2];
      for (i=3;i<=n;i++) v=v"="kv[i];
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
      gsub(/^"|"$/, "", v);
      gsub(/^'\''|'\''$/, "", v);
      if (cur == section && k == key) { print v; exit; }
    }
  ' "$1"
}

fail=0
assert_nonempty() {
  local section="$1" key="$2"
  local v
  v="$(toml_get "$FIXTURE" "$section" "$key")"
  if [ -z "$v" ]; then
    echo "[t_auto_config_minimal] FAIL: [${section}].${key} is missing or empty" >&2
    fail=1
  else
    echo "[t_auto_config_minimal] OK   [${section}].${key} = $v"
  fi
}

assert_value() {
  local section="$1" key="$2" want="$3"
  local v
  v="$(toml_get "$FIXTURE" "$section" "$key")"
  if [ "$v" != "$want" ]; then
    echo "[t_auto_config_minimal] FAIL: [${section}].${key} = '$v', want '$want'" >&2
    fail=1
  else
    echo "[t_auto_config_minimal] OK   [${section}].${key} = $v"
  fi
}

# Required fields.
assert_nonempty ""             "hostname"
assert_nonempty "user"         "name"
assert_nonempty "user"         "password_hash"
assert_nonempty "disk"         "size_gb"
assert_nonempty "disk.layout"  "type"
assert_nonempty "de"           "default"
assert_nonempty "network"      "ipv4"

# Enum / preset value checks.
type_v="$(toml_get "$FIXTURE" "disk.layout" "type")"
case "$type_v" in
  uefi-ext4) echo "[t_auto_config_minimal] OK   [disk.layout].type = $type_v (supported preset)" ;;
  *) echo "[t_auto_config_minimal] FAIL: unsupported [disk.layout].type: $type_v" >&2; fail=1 ;;
esac
de_v="$(toml_get "$FIXTURE" "de" "default")"
case "$de_v" in
  sway|kwin|mutter|plasmashell|sddm) echo "[t_auto_config_minimal] OK   [de].default = $de_v" ;;
  *) echo "[t_auto_config_minimal] FAIL: unsupported [de].default: $de_v" >&2; fail=1 ;;
esac
ipv4_v="$(toml_get "$FIXTURE" "network" "ipv4")"
case "$ipv4_v" in
  dhcp) echo "[t_auto_config_minimal] OK   [network].ipv4 = $ipv4_v" ;;
  *) echo "[t_auto_config_minimal] FAIL: v1 only supports [network].ipv4 = 'dhcp'; got '$ipv4_v'" >&2; fail=1 ;;
esac

# Password hash must look like a Unix crypt format ($id$salt$hash).
pw="$(toml_get "$FIXTURE" "user" "password_hash")"
case "$pw" in
  '$6$'*|'$y$'*|'$5$'*|'$1$'*)
    echo "[t_auto_config_minimal] OK   [user].password_hash format looks valid" ;;
  *) echo "[t_auto_config_minimal] FAIL: [user].password_hash does not match a known crypt format ($id$salt$hash)" >&2; fail=1 ;;
esac

# Section-name allowlist guard against typos that the toml_get
# silently ignores.  Use awk to collect every [section] header and
# reject anything outside the v1 schema.
ALLOWED_SECTIONS=" user disk disk.layout de network activities "
mapfile -t sections < <(awk '/^[[:space:]]*\[.*\][[:space:]]*$/ {
  gsub(/^[[:space:]]*\[|\][[:space:]]*$/, ""); print
}' "$FIXTURE")
for s in "${sections[@]}"; do
  case "$ALLOWED_SECTIONS" in
    *" $s "*) echo "[t_auto_config_minimal] OK   section [$s] in allowlist" ;;
    *) echo "[t_auto_config_minimal] FAIL: unknown section [$s]" >&2; fail=1 ;;
  esac
done

if [ "$fail" != "0" ]; then
  echo "[t_auto_config_minimal] FAILED" >&2
  exit 1
fi
echo "[t_auto_config_minimal] PASS"
exit 0
