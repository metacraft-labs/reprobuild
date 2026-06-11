#!/bin/sh
# apt_mvp.sh - Linux-Third-Party-Sandbox-MVP M2 apt consumption MVP.
#
# Realizes a Debian .deb package + its first level of `Depends:` into
# per-package content-addressed reprobuild-store prefixes, composes them
# into an FHS tree, then wraps a target binary via bubblewrap using the
# M1 driver's M0-locked transparency posture.
#
# This is the M2 "simpler path" the spec calls out: a POSIX-sh
# orchestrator over the apt-side fetch + unpack pipeline plus an exec
# of bubblewrap with the M1 driver's argv shape. A typed Nim
# `libs/repro_apt_catalog/` library + a `repro_apt_mvp` binary that
# calls into `applyLinuxFhsSandbox` directly is M5 scope (per spec
# instruction "Library implementation is M5 scope").
#
# Pipeline:
#
#   1. Pin one snapshot.debian.org timestamp + one Debian codename +
#      one architecture (no per-host detection — this is MVP scope).
#   2. Fetch `dists/<codename>/InRelease`.
#      The InRelease file is a clearsigned manifest of every per-
#      component index file with sha256 sums. M2 SKIPS the GPG
#      signature verification (spec: "SKIP GPG verification for M2 —
#      defer to M5"); the sha256 entries inside the InRelease body
#      are still used as the verification floor for the Packages.gz
#      we download.
#   3. Look up `main/binary-<arch>/Packages.gz` sha256 from InRelease.
#   4. Fetch + sha256-verify Packages.gz, gunzip it.
#   5. For the root package and EACH first-level Depends: parse out
#      `Filename:` + `SHA256:`, fetch the .deb from
#      `<snapshot-url>/<Filename>`, sha256-verify it, unpack via
#      `dpkg-deb -x` (if available) or `ar x` + `tar x` (off-Debian
#      fallback), into a content-addressed prefix
#      `$REPRO_STORE_ROOT/sha256-<digest>-<pkg>/`.
#   6. Compose every prefix into `$REPRO_STORE_ROOT/composed-<digest>/`
#      via `cp -al` (hardlink-copy; M5 will replace this with the
#      proper closure-dedup overlay layer).
#   7. exec `bwrap` with the M0-locked transparency-posture argv
#      vector matching `buildLinuxFhsSandboxArgv` in M1's
#      `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`.
#
# Closure simplifications (spec-permitted MVP scope):
#
#   - First-level Depends only. NO transitive walk. NO Pre-Depends,
#     Conflicts, Provides, Suggests, Recommends, Replaces, Breaks.
#   - Versioned constraints stripped: `libc6 (>= 2.34)` -> `libc6`.
#   - Alternatives stripped: `foo | bar` -> `foo`. First option wins.
#   - Virtual packages via Provides: NOT resolved. If a Depends entry
#     is a virtual name with no concrete Package: stanza, fetch fails
#     and we bail out with a diagnostic. M5 closure-resolver will
#     handle this.
#   - Arch is hard-pinned to amd64 (snapshot.debian.org has no other
#     test fixture pinned in M2).
#
# Usage:
#   apt_mvp.sh \
#     --snapshot=<YYYYMMDDTHHMMSSZ> \
#     --codename=<bookworm|bullseye|trixie|...> \
#     --package=<root-package-name> \
#     [--store-root=<path>] \
#     [--store-root-fallback=<path>] \
#     [--no-exec] \
#     -- <argv inside sandbox ...>
#
# Environment overrides:
#   REPRO_STORE_ROOT    Where to realize the content-addressed prefixes
#                       and the composed FHS tree. Default:
#                       `${XDG_CACHE_HOME:-$HOME/.cache}/repro-apt-mvp/store`.
#                       (NOT `$HOME/.cache/repro` — that's reprobuild's
#                       action cache and we do NOT want to leak M2's
#                       experimental cache lines into the production
#                       cache layout. M5's library version wires into
#                       the real store.)
#
# Exit codes:
#   0  - sandbox launched, wrapped binary returned 0.
#   1  - any pipeline step failed (fetch, sha256 mismatch, unpack,
#        compose, bwrap launch). Diagnostic prefixed `apt_mvp:`.
#   *  - the wrapped binary's own exit code (forwarded verbatim) if
#        the sandbox launched but the binary returned non-zero.
#
# Status: M2 in_review, 2026-06-11. The deliverable shape is locked to
# the harness wrapper `tools/multi-distro-harness/tests/sandbox_m2_apt_mvp.sh`
# which sources this script's behavior via direct invocation.

set -eu

# ----------------------------------------------------------------------
# Argument parsing (POSIX sh, no getopt).
# ----------------------------------------------------------------------

snapshot=''
codename=''
package=''
store_root=''
no_exec=0

# Collect inner argv after `--`.
inner_argv=''
seen_dash_dash=0

while [ $# -gt 0 ]; do
  if [ "$seen_dash_dash" -eq 1 ]; then
    # Everything after `--` is inner sandbox argv.
    inner_argv="$inner_argv $1"
    shift
    continue
  fi
  case "$1" in
    --snapshot=*) snapshot=${1#--snapshot=} ;;
    --codename=*) codename=${1#--codename=} ;;
    --package=*)  package=${1#--package=}   ;;
    --store-root=*) store_root=${1#--store-root=} ;;
    --no-exec)    no_exec=1 ;;
    --)           seen_dash_dash=1 ;;
    *)
      echo "apt_mvp: FAIL - unrecognized arg '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

# ----------------------------------------------------------------------
# Defaults + validation.
# ----------------------------------------------------------------------

[ -n "$snapshot" ] || { echo "apt_mvp: FAIL - --snapshot=<ts> required" >&2; exit 1; }
[ -n "$codename" ] || { echo "apt_mvp: FAIL - --codename=<name> required" >&2; exit 1; }
[ -n "$package" ]  || { echo "apt_mvp: FAIL - --package=<name> required" >&2; exit 1; }

# Hard-pin arch to amd64 (M2 MVP scope; M3/M4 will generalize if needed).
arch='amd64'

# Store root default. We INTENTIONALLY do NOT colonize $HOME/.cache/repro
# (the production action cache) — M2 is experimental and its layout will
# be reworked by M5's library port. Use a sibling cache dir.
if [ -z "$store_root" ]; then
  store_root="${REPRO_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/repro-apt-mvp/store}"
fi

# Snapshot URL base. The redirect from /archive/debian/<ts>/... resolves
# to time-machine.debian.net or snapshot.debian.org; curl -L follows it.
snapshot_base="https://snapshot.debian.org/archive/debian/${snapshot}"
component='main'

# Working dirs.
mkdir -p "$store_root"
work_root="$store_root/.work-${snapshot}-${codename}-${arch}"
mkdir -p "$work_root"

echo "apt_mvp: snapshot=${snapshot} codename=${codename} arch=${arch} package=${package}"
echo "apt_mvp: store_root=${store_root}"

# ----------------------------------------------------------------------
# Dependencies probe.
# ----------------------------------------------------------------------

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "apt_mvp: FAIL - required command '$1' not on PATH" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd sha256sum
require_cmd gunzip
require_cmd awk
require_cmd sed

# Either dpkg-deb (Debian native) OR ar + tar (off-Debian fallback) for
# unpack. Prefer dpkg-deb; fall back to ar+tar.
unpack_tool=''
if command -v dpkg-deb >/dev/null 2>&1; then
  unpack_tool='dpkg-deb'
elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  unpack_tool='ar+tar'
else
  echo "apt_mvp: FAIL - need either dpkg-deb OR ar+tar to unpack .deb files" >&2
  exit 1
fi
echo "apt_mvp: unpack_tool=${unpack_tool}"

# bwrap is required iff we are going to exec; if --no-exec we just
# realize the FHS tree and stop (useful for cache priming + the
# integration test's tear-down assertions).
if [ "$no_exec" -eq 0 ] && ! command -v bwrap >/dev/null 2>&1; then
  echo "apt_mvp: FAIL - bwrap missing (install bubblewrap or pass --no-exec)" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 1: fetch InRelease.
# ----------------------------------------------------------------------
#
# The InRelease file lives at
#   <snapshot-base>/dists/<codename>/InRelease
# and contains the sha256 sums of every per-component index file
# (Packages, Packages.gz, Packages.xz, Sources, Contents, ...). The
# file itself is GPG-clearsigned in the production flow; M2 SKIPS GPG
# verification per spec and uses only the embedded sha256 entries.

inrelease_url="${snapshot_base}/dists/${codename}/InRelease"
inrelease_path="${work_root}/InRelease"

echo "apt_mvp: step 1 - fetching InRelease from ${inrelease_url}"
if ! curl -sSL -m 60 -o "$inrelease_path" "$inrelease_url"; then
  echo "apt_mvp: FAIL - InRelease fetch failed" >&2
  exit 1
fi
if [ ! -s "$inrelease_path" ]; then
  echo "apt_mvp: FAIL - InRelease at ${inrelease_url} is empty" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2: locate the Packages.gz sha256 in InRelease.
# ----------------------------------------------------------------------
#
# The InRelease body has a SHA256: section followed by lines of the
# shape:
#
#   <64-hex-sha256> <bytes> <relative-path>
#
# We want the line whose path matches main/binary-<arch>/Packages.gz.
# awk in-section state machine: enter the SHA256 section, exit when a
# new top-level key appears (line starting with non-space non-hex).

packages_rel="${component}/binary-${arch}/Packages.gz"
packages_sha=$(awk -v target="$packages_rel" '
  /^SHA256:/ { in_sha = 1; next }
  in_sha && /^[A-Za-z]/ { in_sha = 0 }
  in_sha && NF == 3 && $3 == target { print $1; exit }
' "$inrelease_path")

if [ -z "$packages_sha" ]; then
  echo "apt_mvp: FAIL - no SHA256 entry for ${packages_rel} in InRelease" >&2
  exit 1
fi
echo "apt_mvp: step 2 - Packages.gz expected sha256=${packages_sha}"

# ----------------------------------------------------------------------
# Step 3: fetch + verify + gunzip Packages.gz.
# ----------------------------------------------------------------------

packages_gz_url="${snapshot_base}/dists/${codename}/${packages_rel}"
packages_gz_path="${work_root}/Packages.gz"
packages_path="${work_root}/Packages"

echo "apt_mvp: step 3 - fetching Packages.gz from ${packages_gz_url}"
if ! curl -sSL -m 300 -o "$packages_gz_path" "$packages_gz_url"; then
  echo "apt_mvp: FAIL - Packages.gz fetch failed" >&2
  exit 1
fi

got_sha=$(sha256sum "$packages_gz_path" | awk '{print $1}')
if [ "$got_sha" != "$packages_sha" ]; then
  echo "apt_mvp: FAIL - Packages.gz sha256 mismatch" >&2
  echo "  expected: ${packages_sha}" >&2
  echo "  got:      ${got_sha}" >&2
  exit 1
fi
echo "apt_mvp:   sha256 OK"

gunzip -kf "$packages_gz_path"
if [ ! -s "$packages_path" ]; then
  echo "apt_mvp: FAIL - Packages decompressed empty" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Helper: extract one field from one package stanza in Packages.
# ----------------------------------------------------------------------
#
# Packages format: blank-line-separated stanzas; each stanza is a list
# of `Key: value` lines with optional continuation lines starting with
# whitespace. We want a SPECIFIC field of a SPECIFIC Package: NAME
# stanza. Use awk:

extract_field() {
  pkg=$1
  field=$2
  awk -v pkg="$pkg" -v field="$field" '
    BEGIN { in_pkg = 0 }
    /^$/  { in_pkg = 0; next }
    /^Package:[ \t]+/ {
      sub(/^Package:[ \t]+/, "")
      in_pkg = ($0 == pkg)
      next
    }
    in_pkg {
      # Match "Field: value" at start of line.
      if (index($0, field ":") == 1) {
        sub(/^[A-Za-z0-9_-]+:[ \t]+/, "")
        print $0
        exit
      }
    }
  ' "$packages_path"
}

# ----------------------------------------------------------------------
# Helper: closure resolution.
# ----------------------------------------------------------------------
#
# Given a root package name, return the package name plus its
# first-level Depends (one per line). Closure simplifications:
#   - For each alternatives group `A | B | C`, pick the first option A.
#   - Strip versioned constraints `(>= 2.34)`.
#   - Strip arch qualifiers `:any`.
#   - Skip Pre-Depends, Conflicts, Provides, Suggests, Recommends
#     (Depends only — M5 generalizes).

resolve_first_level_closure() {
  root=$1
  echo "$root"
  depends=$(extract_field "$root" 'Depends')
  if [ -z "$depends" ]; then
    return 0
  fi
  # `Depends: foo (>= 1), bar | baz, qux:any` -> one dep per line, first
  # alternative, no constraints, no arch.
  echo "$depends" | awk '
    {
      # Split on commas.
      n = split($0, parts, ",")
      for (i = 1; i <= n; i++) {
        d = parts[i]
        # First alternative of `A | B`.
        sub(/\|.*/, "", d)
        # Strip parenthesised version constraint.
        sub(/\(.*\)/, "", d)
        # Strip arch qualifier.
        sub(/:[a-zA-Z0-9-]+/, "", d)
        # Trim whitespace.
        gsub(/^[ \t]+/, "", d)
        gsub(/[ \t]+$/, "", d)
        if (d != "") print d
      }
    }
  '
}

# ----------------------------------------------------------------------
# Step 4: resolve closure, fetch + unpack each package.
# ----------------------------------------------------------------------

closure_file="${work_root}/closure.txt"
resolve_first_level_closure "$package" > "$closure_file"
if [ ! -s "$closure_file" ]; then
  echo "apt_mvp: FAIL - resolve_first_level_closure produced empty list" >&2
  exit 1
fi

echo "apt_mvp: step 4 - closure ($(wc -l < "$closure_file") packages):"
sed 's/^/  /' < "$closure_file"

# Per-package realized prefixes, recorded for the compose step.
realized_prefixes_file="${work_root}/realized_prefixes.txt"
: > "$realized_prefixes_file"

# Iterate the closure. Use redirect-from-file (NOT pipe) so `exit 1`
# inside the loop body terminates the script, not just a subshell.
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue

  filename=$(extract_field "$pkg" 'Filename')
  sha256=$(extract_field "$pkg" 'SHA256')
  size=$(extract_field "$pkg" 'Size')

  if [ -z "$filename" ] || [ -z "$sha256" ]; then
    # Virtual package (no concrete stanza); spec-permitted to bail.
    echo "apt_mvp: FAIL - no concrete Filename/SHA256 for '${pkg}'" >&2
    echo "  (likely a virtual package via Provides; M5 closure resolver" >&2
    echo "   will handle this — M2 scope is hard-pinned to concrete pkgs)" >&2
    exit 1
  fi

  prefix_dir="${store_root}/sha256-${sha256}-${pkg}"
  prefix_data_dir="${prefix_dir}/data"
  deb_url="${snapshot_base}/${filename}"
  deb_path="${work_root}/${pkg}.deb"

  echo "apt_mvp:   ${pkg}: ${filename} (size=${size}, sha256=${sha256})"
  echo "${prefix_dir}" >> "$realized_prefixes_file"

  # Cache: if the data dir already exists from a prior run, skip fetch +
  # unpack. (Content addressing means the same sha256 always yields the
  # same bytes; presence of `data/` is a stable cache hit signal.)
  if [ -d "$prefix_data_dir" ]; then
    echo "apt_mvp:     cache hit at ${prefix_dir}"
    continue
  fi

  echo "apt_mvp:     fetching ${deb_url}"
  if ! curl -sSL -m 300 -o "$deb_path" "$deb_url"; then
    echo "apt_mvp: FAIL - .deb fetch failed for ${pkg}" >&2
    exit 1
  fi

  got_deb_sha=$(sha256sum "$deb_path" | awk '{print $1}')
  if [ "$got_deb_sha" != "$sha256" ]; then
    echo "apt_mvp: FAIL - .deb sha256 mismatch for ${pkg}" >&2
    echo "  expected: ${sha256}" >&2
    echo "  got:      ${got_deb_sha}" >&2
    exit 1
  fi
  echo "apt_mvp:     sha256 OK"

  mkdir -p "$prefix_data_dir"
  case "$unpack_tool" in
    dpkg-deb)
      if ! dpkg-deb -x "$deb_path" "$prefix_data_dir"; then
        echo "apt_mvp: FAIL - dpkg-deb -x failed for ${pkg}" >&2
        rm -rf "$prefix_data_dir"
        exit 1
      fi
      ;;
    ar+tar)
      # .deb is an ar archive of {debian-binary, control.tar.*, data.tar.*}.
      # We only need data.tar.*. Extract via ar then untar the data member.
      unpack_work="${work_root}/.unpack-${pkg}"
      rm -rf "$unpack_work"
      mkdir -p "$unpack_work"
      ( cd "$unpack_work" && ar x "$deb_path" ) || {
        echo "apt_mvp: FAIL - ar x failed for ${pkg}" >&2
        rm -rf "$prefix_data_dir" "$unpack_work"
        exit 1
      }
      data_tar=''
      for cand in data.tar.zst data.tar.xz data.tar.gz data.tar.bz2 data.tar; do
        if [ -f "${unpack_work}/${cand}" ]; then
          data_tar="${unpack_work}/${cand}"
          break
        fi
      done
      if [ -z "$data_tar" ]; then
        echo "apt_mvp: FAIL - no data.tar.* member in ${pkg}" >&2
        rm -rf "$prefix_data_dir" "$unpack_work"
        exit 1
      fi
      # tar -xf auto-detects compression in GNU tar (which is what every
      # target distro ships); for portability with busybox tar we case-
      # decompress.
      case "$data_tar" in
        *.zst) zstd -dcf "$data_tar" | tar -xf - -C "$prefix_data_dir" ;;
        *.xz)  xz -dc  "$data_tar" | tar -xf - -C "$prefix_data_dir" ;;
        *.gz)  gunzip -c "$data_tar" | tar -xf - -C "$prefix_data_dir" ;;
        *.bz2) bzip2 -dc "$data_tar" | tar -xf - -C "$prefix_data_dir" ;;
        *)     tar -xf "$data_tar" -C "$prefix_data_dir" ;;
      esac || {
        echo "apt_mvp: FAIL - data.tar extract failed for ${pkg}" >&2
        rm -rf "$prefix_data_dir" "$unpack_work"
        exit 1
      }
      rm -rf "$unpack_work"
      ;;
  esac

  rm -f "$deb_path"
done < "$closure_file"

# Sanity: the realized-prefix list should match the closure.
if [ ! -s "$realized_prefixes_file" ]; then
  echo "apt_mvp: FAIL - no realized prefixes after fetch loop" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 5: compose the FHS tree via cp -al.
# ----------------------------------------------------------------------
#
# Each per-package `data/` is rooted at the package's FHS layout (e.g.
# `data/usr/bin/hello`, `data/lib/x86_64-linux-gnu/libc.so.6`). We
# compose by hardlink-copying every package's `data/` into a single
# `composed-<digest>/` prefix; conflicting files would error, but the
# closure we resolve (one root + its direct Depends) is conflict-free
# in the Debian model by construction.
#
# `cp -al` is the M2-permitted simplification ("cp -al for now; M5
# dedup is the proper closure layer"). Hardlinks share inodes with the
# per-package data dirs; the composed tree is therefore O(closure-size)
# in metadata, not in bytes.

# Digest the composed tree by digesting the sorted list of realized
# prefixes — this is the stable address of "this exact closure".
compose_digest=$(sort -u "$realized_prefixes_file" | sha256sum | awk '{print $1}')
composed_root="${store_root}/composed-${compose_digest}"

if [ -d "$composed_root" ]; then
  echo "apt_mvp: step 5 - composed FHS tree cache hit at ${composed_root}"
else
  echo "apt_mvp: step 5 - composing FHS tree into ${composed_root}"
  mkdir -p "$composed_root"
  # Read sorted prefix list from a tmp file (redirect, not pipe) so an
  # exit inside the loop terminates the script.
  sorted_prefixes="${work_root}/sorted_prefixes.txt"
  sort -u "$realized_prefixes_file" > "$sorted_prefixes"
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    if [ ! -d "${prefix}/data" ]; then
      echo "apt_mvp: FAIL - realized prefix missing data dir: ${prefix}" >&2
      exit 1
    fi
    # `cp -al`: hardlink every regular file, descend dirs. `.` so dotfiles
    # at root are included.
    ( cd "${prefix}/data" && cp -al . "${composed_root}/" ) || {
      echo "apt_mvp: FAIL - cp -al compose failed for ${prefix}" >&2
      rm -rf "$composed_root"
      exit 1
    }
  done < "$sorted_prefixes"
fi

# Ensure the six FHS roots exist (some packages don't populate all of
# them — e.g. a libfoo .deb may have no `/etc`. bwrap --bind refuses if
# the source path is missing).
for sub in usr lib lib64 bin sbin etc; do
  if [ ! -d "${composed_root}/${sub}" ]; then
    mkdir -p "${composed_root}/${sub}"
  fi
done

echo "apt_mvp:   composed FHS tree at ${composed_root}"

# Resolve the binary path to invoke. The user passes a sandbox-side
# absolute path (e.g. `/usr/bin/hello`); for the integration test
# default we expect the inner argv to be set explicitly.
if [ "$no_exec" -eq 1 ]; then
  echo "apt_mvp: --no-exec set; stopping before bwrap launch"
  echo "apt_mvp: OK (realize-only path; composed_root=${composed_root})"
  exit 0
fi

if [ -z "$inner_argv" ]; then
  echo "apt_mvp: FAIL - no inner argv after '--'; nothing to exec" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 6: bwrap exec with the M1 driver's M0-locked argv shape.
# ----------------------------------------------------------------------
#
# Argv shape MUST match `buildLinuxFhsSandboxArgv` in:
#   libs/repro_elevation/src/repro_elevation/posix_system_driver.nim
#
# Six --bind of composed/<sub> -> /<sub> for {usr,lib,lib64,bin,sbin,etc}
# + --dev-bind /dev /dev
# + --bind for {/home,/tmp,/run,/sys,/var} pass-through
# + --proc /proc
# + -- + <inner argv>
#
# NO --unshare-*, NO --cap-drop, NO --seccomp, NO --ro-bind — the M0
# transparency posture is mechanism only, not isolation policy.

echo "apt_mvp: step 6 - bwrap exec"

# Build the argv tail as positional parameters so we can pass the inner
# argv verbatim (no quoting trips, no shell metacharacter expansion).
set -- \
  --bind "${composed_root}/usr"   /usr   \
  --bind "${composed_root}/lib"   /lib   \
  --bind "${composed_root}/lib64" /lib64 \
  --bind "${composed_root}/bin"   /bin   \
  --bind "${composed_root}/sbin"  /sbin  \
  --bind "${composed_root}/etc"   /etc   \
  --dev-bind /dev  /dev  \
  --bind     /home /home \
  --bind     /tmp  /tmp  \
  --bind     /run  /run  \
  --bind     /sys  /sys  \
  --bind     /var  /var  \
  --proc     /proc \
  --

# Append inner argv tokens (word-split is intentional here: the caller
# passed them as separate `--` tail args; we accumulated them into one
# string with leading spaces, so $inner_argv expands as multiple words).
# shellcheck disable=SC2086
exec bwrap "$@" $inner_argv
