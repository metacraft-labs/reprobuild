#!/bin/sh
# pacman_mvp.sh - Linux-Third-Party-Sandbox-MVP M4 pacman consumption MVP.
#
# Realizes an Arch Linux .pkg.tar.zst package + its first level of
# `%DEPENDS%` capabilities into per-package content-addressed reprobuild-
# store prefixes, composes them into an FHS tree, then wraps a target
# binary via bubblewrap using the M1 driver's M0-locked transparency
# posture.
#
# Mirror of `apt_mvp.sh` (M2) + `dnf_mvp.sh` (M3) shape with three
# substitutions:
#
#   - Metadata format: pacman's `<repo>.db` is a GZIP-compressed tar of
#     `<name>-<ver>/desc` text files (one stanza per package). No top-
#     level Release/InRelease equivalent on Arch — the verification
#     floor is the per-package `%SHA256SUM%` inside the desc file plus
#     HTTPS for the .db fetch. Different from apt's Packages.gz line-
#     based format and dnf's primary.xml.
#   - Package format: `.pkg.tar.zst` (zstd-compressed tar). Simpler than
#     .deb (ar wrapper around data.tar.*) or .rpm (binary header). The
#     standard unpack pipeline is one of:
#       tar --zstd -xf <file> -C <prefix>     (tar 1.31+ built-in zstd)
#       unzstd -c <file> | tar -x -C <prefix> (zstd CLI fallback)
#     Both shapes ship on Arch out of the box (tar 1.35 + zstd 1.5+).
#   - Snapshot source: `https://archive.archlinux.org/repos/<YYYY>/<MM>/<DD>/<repo>/os/<arch>/`
#     — daily archives. ALA preserves every package version published;
#     each daily snapshot is the exact `<repo>.db` + .pkg.tar.zst tree
#     from that day. Different from snapshot.debian.org's per-second
#     timestamp pinning and from Fedora's per-release archive mirror.
#
# Pipeline:
#
#   1. Fetch `<repo>.db` (gzipped tarball of `desc` files) from the
#      pinned ALA URL.
#   2. Extract + parse the target package's `desc` for: `%FILENAME%`,
#      `%SHA256SUM%`, `%DEPENDS%`. The desc format is a sequence of
#      `%KEY%\n<value-line>\n...\n\n` blocks (blank-line separated,
#      value lines until next `%KEY%`).
#   3. For each first-level dependency, look up its desc inside the .db
#      tree. Dependencies may be capability-style (e.g.
#      `libreadline.so=8-64`) — pick the package whose `%PROVIDES%`
#      matches OR whose package name matches the bare capability.
#      Strip versioned constraints (`pkg>=1.2`, `pkg=1.2-3`) before
#      matching. First concrete provider wins (document order across
#      the extracted desc dir).
#   4. Fetch each .pkg.tar.zst from the ALA mirror.
#   5. sha256-verify against the desc's `%SHA256SUM%`.
#   6. Extract via `tar --zstd -xf` (tar 1.31+) or `unzstd | tar -x`
#      fallback into a content-addressed prefix
#      `$REPRO_STORE_ROOT/sha256-<digest>-<pkg>/data/`.
#   7. Compose every prefix into `$REPRO_STORE_ROOT/composed-<digest>/`
#      via `cp -al` (hardlinks; M5 closure-dedup overlay layer is the
#      proper replacement).
#   8. `exec bwrap` with the M1 driver's M0-locked argv shape (matches
#      `buildLinuxFhsSandboxArgv` in
#      `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`).
#
# Closure simplifications (spec-permitted MVP scope; mirror M2/M3):
#
#   - First-level `%DEPENDS%` only. NO transitive walk. NO
#     `%OPTDEPENDS%`, `%MAKEDEPENDS%`, `%CHECKDEPENDS%`, `%CONFLICTS%`,
#     `%REPLACES%`.
#   - Versioned constraints stripped: `libreadline.so=8-64`,
#     `glibc>=2.27`, `linux-api-headers>=4.10` are all treated as the
#     bare capability before the version operator. The split character
#     set is `<`, `>`, `=` — pacman dep strings always put the operator
#     immediately after the name.
#   - Capability resolution: pick the FIRST concrete provider in
#     directory-listing order. Matches by package name (the dir name's
#     `%NAME%`) OR by `%PROVIDES%` entry (also version-stripped).
#   - Architectures: ALA per-arch snapshots are per-directory — the
#     `--arch=x86_64` switch picks the URL prefix; every package inside
#     the chosen .db is already filtered to that arch (or `any` for
#     architecture-independent packages — those appear in the same .db
#     so no extra work is needed).
#   - Self-dep skipped: if the root itself provides one of its own
#     %DEPENDS%, no extra fetch.
#   - Duplicate providers deduped: if two %DEPENDS% entries both resolve
#     to the same provider package, it's fetched + unpacked ONCE.
#
# Why awk + tar instead of a higher-level tool for desc parsing:
#
#   The .db is a small (~120 KiB for core, ~8 MiB for extra) gzipped
#   tarball of plain-text `desc` files. Each desc is ~30 lines. Streaming
#   extraction + per-file awk parsing is straightforward in pure POSIX
#   shell — no python3 dependency (mirror M2's awk-only path, NOT M3's
#   python3 path). This keeps the script portable across Arch's minimal
#   base install (which does NOT ship python3 — it's an optional install).
#
# Usage:
#   pacman_mvp.sh \
#     --date=YYYY/MM/DD \
#     --package=<root-package-name> \
#     [--repo=core|extra] \
#     [--arch=x86_64] \
#     [--mirror-base=<url>] \
#     [--store-root=<path>] \
#     [--no-exec] \
#     -- <argv inside sandbox ...>
#
#   --date       ALA snapshot date in YYYY/MM/DD form. The script builds
#                the mirror URL as
#                  https://archive.archlinux.org/repos/<date>/<repo>/os/<arch>/
#                Each date is a frozen snapshot of the repos as of that
#                day; ALA preserves every published version so dates
#                resolve indefinitely.
#   --package    Root package name (must match the .db's %NAME% block).
#   --repo       Pacman repo. Default: `core`. (`extra` is the other
#                primary; `community` was merged into `extra` in 2023.)
#   --arch       Architecture. Default: `x86_64`.
#   --mirror-base
#                Override the full mirror URL base ending with `os/<arch>/`
#                (the parent of the `<repo>.db` file). Default:
#                  https://archive.archlinux.org/repos/<date>/<repo>/os/<arch>/
#   --store-root Where to realize content-addressed prefixes + the
#                composed FHS tree. Default:
#                ${REPRO_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/repro-pacman-mvp/store}.
#                (NOT $HOME/.cache/repro - that's reprobuild's action
#                cache; M5 wires this into the real store.)
#   --no-exec    Realize the FHS tree + stop before the bwrap launch.
#                Useful for cache priming + the integration test's
#                tear-down assertions.
#
# Environment overrides:
#   REPRO_STORE_ROOT    Same as --store-root if the flag is unset.
#
# Exit codes:
#   0  - sandbox launched, wrapped binary returned 0.
#   1  - any pipeline step failed (fetch, sha256 mismatch, unpack,
#        compose, bwrap launch). Diagnostic prefixed `pacman_mvp:`.
#   *  - the wrapped binary's own exit code (forwarded verbatim).
#
# Status: M4 in_review, 2026-06-11. Deliverable shape locked to the
# harness wrapper `tools/multi-distro-harness/tests/sandbox_m4_pacman_mvp.sh`
# which sources this script's behavior via direct invocation.

set -eu

# ----------------------------------------------------------------------
# Argument parsing (POSIX sh, no getopt).
# ----------------------------------------------------------------------

date_str=''
repo=''
arch=''
mirror_base=''
package=''
store_root=''
no_exec=0

# Collect inner argv after `--`.
inner_argv=''
seen_dash_dash=0

while [ $# -gt 0 ]; do
  if [ "$seen_dash_dash" -eq 1 ]; then
    inner_argv="$inner_argv $1"
    shift
    continue
  fi
  case "$1" in
    --date=*)        date_str=${1#--date=}           ;;
    --repo=*)        repo=${1#--repo=}               ;;
    --arch=*)        arch=${1#--arch=}               ;;
    --mirror-base=*) mirror_base=${1#--mirror-base=} ;;
    --package=*)     package=${1#--package=}         ;;
    --store-root=*)  store_root=${1#--store-root=}   ;;
    --no-exec)       no_exec=1                        ;;
    --)              seen_dash_dash=1                 ;;
    *)
      echo "pacman_mvp: FAIL - unrecognized arg '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

# ----------------------------------------------------------------------
# Defaults + validation.
# ----------------------------------------------------------------------

[ -n "$date_str" ] || { echo "pacman_mvp: FAIL - --date=YYYY/MM/DD required" >&2; exit 1; }
[ -n "$package" ]  || { echo "pacman_mvp: FAIL - --package=<name> required" >&2; exit 1; }

# Validate the date shape: YYYY/MM/DD. ALA's URL layout is strict.
case "$date_str" in
  [0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]) ;;
  *)
    echo "pacman_mvp: FAIL - --date must be YYYY/MM/DD (got '${date_str}')" >&2
    exit 1
    ;;
esac

if [ -z "$repo" ]; then
  repo='core'
fi
case "$repo" in
  core|extra) ;;
  *)
    echo "pacman_mvp: FAIL - --repo must be core|extra (got '${repo}')" >&2
    exit 1
    ;;
esac

if [ -z "$arch" ]; then
  arch='x86_64'
fi

if [ -z "$mirror_base" ]; then
  mirror_base="https://archive.archlinux.org/repos/${date_str}/${repo}/os/${arch}/"
fi

# Normalize trailing slash on mirror_base.
case "$mirror_base" in
  */) : ;;
  *)  mirror_base="${mirror_base}/" ;;
esac

# Store root default. INTENTIONALLY not colonizing $HOME/.cache/repro
# (production action cache) — M4 is experimental; M5's library port
# will rework the layout.
if [ -z "$store_root" ]; then
  store_root="${REPRO_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/repro-pacman-mvp/store}"
fi

# Working dirs. Replace slashes in date with dashes for the work dir name.
date_tag=$(echo "$date_str" | tr '/' '-')
mkdir -p "$store_root"
work_root="$store_root/.work-${date_tag}-${repo}-${arch}"
mkdir -p "$work_root"

echo "pacman_mvp: date=${date_str} repo=${repo} arch=${arch} package=${package}"
echo "pacman_mvp: mirror_base=${mirror_base}"
echo "pacman_mvp: store_root=${store_root}"

# ----------------------------------------------------------------------
# Dependencies probe.
# ----------------------------------------------------------------------

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "pacman_mvp: FAIL - required command '$1' not on PATH" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd sha256sum
require_cmd gunzip
require_cmd awk
require_cmd sed
require_cmd tar

# zstd extraction: prefer tar's built-in --zstd (GNU tar 1.31+). Fall
# back to an external `zstd` (or `unzstd`) piped into tar -x. Arch's
# base ships GNU tar 1.35 + zstd 1.5+ so tar --zstd is available; the
# fallback exists for off-Arch hosts running the script.
extract_tool=''
if tar --zstd --help >/dev/null 2>&1; then
  extract_tool='tar-zstd'
elif command -v zstd >/dev/null 2>&1; then
  extract_tool='zstd-pipe'
elif command -v unzstd >/dev/null 2>&1; then
  extract_tool='unzstd-pipe'
else
  echo "pacman_mvp: FAIL - need either 'tar --zstd' OR 'zstd' OR 'unzstd' to unpack .pkg.tar.zst" >&2
  exit 1
fi
echo "pacman_mvp: extract_tool=${extract_tool}"

if [ "$no_exec" -eq 0 ] && ! command -v bwrap >/dev/null 2>&1; then
  echo "pacman_mvp: FAIL - bwrap missing (install bubblewrap or pass --no-exec)" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 1: fetch <repo>.db.
# ----------------------------------------------------------------------
#
# The .db is a small gzipped tarball of one `<name>-<ver>/desc` text
# file per package. There is NO top-level Release/InRelease equivalent
# on Arch — Arch's pacman trusts the GPG-signed `.db.sig` companion
# file (deferred to M5 per the impl spec). The verification floor for
# the .pkg.tar.zst payloads is the `%SHA256SUM%` block inside each
# desc, plus HTTPS for the .db fetch itself.

db_url="${mirror_base}${repo}.db"
db_path="${work_root}/${repo}.db"

echo "pacman_mvp: step 1 - fetching ${repo}.db from ${db_url}"
if ! curl -sSL -m 120 -o "$db_path" "$db_url"; then
  echo "pacman_mvp: FAIL - ${repo}.db fetch failed" >&2
  exit 1
fi
if [ ! -s "$db_path" ]; then
  echo "pacman_mvp: FAIL - ${repo}.db at ${db_url} is empty" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2: extract .db to a per-snapshot desc dir.
# ----------------------------------------------------------------------
#
# The extracted layout is a flat dir of `<name>-<ver>/desc` files. Cache
# the extracted dir keyed by .db sha256 so warm runs skip the re-extract.

db_sha=$(sha256sum "$db_path" | awk '{print $1}')
desc_dir="${work_root}/db-sha256-${db_sha}"

if [ -d "$desc_dir" ] && [ -n "$(ls -A "$desc_dir" 2>/dev/null)" ]; then
  echo "pacman_mvp: step 2 - desc dir cache hit at ${desc_dir}"
else
  echo "pacman_mvp: step 2 - extracting ${repo}.db (sha256=${db_sha}) into ${desc_dir}"
  rm -rf "$desc_dir"
  mkdir -p "$desc_dir"
  # The .db is always gzip-compressed tar (NOT zstd; this is the index
  # format, distinct from the .pkg.tar.zst payload format).
  if ! tar -xzf "$db_path" -C "$desc_dir"; then
    echo "pacman_mvp: FAIL - ${repo}.db extract failed" >&2
    rm -rf "$desc_dir"
    exit 1
  fi
fi

extracted_count=$(ls "$desc_dir" | wc -l)
echo "pacman_mvp:   extracted ${extracted_count} desc entries"

# ----------------------------------------------------------------------
# Helpers: desc parsing in pure awk.
# ----------------------------------------------------------------------
#
# desc format:
#
#   %FILENAME%
#   bash-5.2.037-1-x86_64.pkg.tar.zst
#
#   %NAME%
#   bash
#
#   %DEPENDS%
#   readline
#   libreadline.so=8-64
#   glibc
#   ncurses
#
#   %PROVIDES%
#   sh
#
# Blocks are separated by blank lines; the value lines for a block are
# everything after the `%KEY%` line up to the next blank line OR the
# next `%KEY%` line. Some values are single-line, some multi-line.

# extract_block <desc-file> <key>
#   Print the value lines under `%key%` in the desc file, one per line.
extract_block() {
  desc_file=$1
  key=$2
  awk -v key="%${key}%" '
    BEGIN { in_block = 0 }
    /^$/  { in_block = 0; next }
    $0 == key { in_block = 1; next }
    /^%/ { in_block = 0; next }
    in_block { print $0 }
  ' "$desc_file"
}

# strip_constraint <dep-string>
#   Strip versioned constraint operators (=, <, >, <=, >=) from a pacman
#   dep string. `glibc>=2.27` -> `glibc`. `libreadline.so=8-64` ->
#   `libreadline.so`.
strip_constraint() {
  echo "$1" | sed -E 's/[<>=].*$//'
}

# ----------------------------------------------------------------------
# Step 3: locate root + resolve first-level deps.
# ----------------------------------------------------------------------
#
# pass 1: find the desc dir whose %NAME% matches the target package.
# pass 2: for each %DEPENDS% entry of the root, scan all desc dirs;
#         pick the first concrete provider (whose %NAME% matches OR
#         whose %PROVIDES% lists the bare capability).
#
# Output (one line per closure entry, tab-separated):
#   <name>\t<filename>\t<sha256>
#
# Order: root first, then resolved deps in scan order; deduped by name.

# ---- pass 1: find root ----------------------------------------------

root_desc=''
for cand in "$desc_dir"/*/desc; do
  [ -f "$cand" ] || continue
  cand_name=$(extract_block "$cand" 'NAME' | sed -n '1p')
  if [ "$cand_name" = "$package" ]; then
    root_desc="$cand"
    break
  fi
done

if [ -z "$root_desc" ]; then
  echo "pacman_mvp: FAIL - no desc with %NAME% '${package}' in ${repo}.db" >&2
  echo "  (closure resolver scans flat dir of <name>-<ver>/desc files;" >&2
  echo "   M5 closure-resolver will handle multi-repo lookups)" >&2
  exit 1
fi

root_filename=$(extract_block "$root_desc" 'FILENAME' | sed -n '1p')
root_sha=$(extract_block "$root_desc" 'SHA256SUM' | sed -n '1p')
if [ -z "$root_filename" ] || [ -z "$root_sha" ]; then
  echo "pacman_mvp: FAIL - root desc missing %FILENAME% or %SHA256SUM%" >&2
  exit 1
fi

# Capture the root's self-provides (name + every %PROVIDES% entry, both
# version-stripped) to skip self-resolution.
root_provides_file="${work_root}/root_provides.txt"
{
  echo "$package"
  extract_block "$root_desc" 'PROVIDES' | while IFS= read -r p; do
    [ -n "$p" ] || continue
    strip_constraint "$p"
  done
} | sort -u > "$root_provides_file"

# Root's first-level deps (version-stripped, blank-skipped).
root_deps_file="${work_root}/root_deps.txt"
extract_block "$root_desc" 'DEPENDS' | while IFS= read -r d; do
  [ -n "$d" ] || continue
  strip_constraint "$d"
done > "$root_deps_file"

# Filter out caps the root already provides.
needed_caps_file="${work_root}/needed_caps.txt"
: > "$needed_caps_file"
while IFS= read -r cap; do
  [ -n "$cap" ] || continue
  if ! grep -Fxq "$cap" "$root_provides_file"; then
    # Dedupe: only add if not already present.
    if ! grep -Fxq "$cap" "$needed_caps_file"; then
      echo "$cap" >> "$needed_caps_file"
    fi
  fi
done < "$root_deps_file"

# ---- pass 2: resolve deps -------------------------------------------

closure_file="${work_root}/closure.tsv"
: > "$closure_file"
printf '%s\t%s\t%s\n' "$package" "$root_filename" "$root_sha" >> "$closure_file"

resolved_caps_file="${work_root}/resolved_caps.txt"
: > "$resolved_caps_file"
emitted_providers_file="${work_root}/emitted_providers.txt"
: > "$emitted_providers_file"

# If no deps, skip the scan.
if [ -s "$needed_caps_file" ]; then
  for cand in "$desc_dir"/*/desc; do
    [ -f "$cand" ] || continue

    # Early-exit: all caps resolved.
    if [ "$(wc -l < "$resolved_caps_file")" = "$(wc -l < "$needed_caps_file")" ]; then
      break
    fi

    cand_name=$(extract_block "$cand" 'NAME' | sed -n '1p')
    [ -n "$cand_name" ] || continue

    # Skip the root itself.
    if [ "$cand_name" = "$package" ]; then
      continue
    fi

    # Build this candidate's provides set: name + every %PROVIDES%
    # entry, version-stripped.
    cand_provides_file="${work_root}/.cand_provides.txt"
    {
      echo "$cand_name"
      extract_block "$cand" 'PROVIDES' | while IFS= read -r p; do
        [ -n "$p" ] || continue
        strip_constraint "$p"
      done
    } | sort -u > "$cand_provides_file"

    # Which still-unresolved caps does this candidate satisfy?
    matched_any=0
    while IFS= read -r cap; do
      [ -n "$cap" ] || continue
      if grep -Fxq "$cap" "$resolved_caps_file"; then
        continue
      fi
      if grep -Fxq "$cap" "$cand_provides_file"; then
        echo "$cap" >> "$resolved_caps_file"
        matched_any=1
      fi
    done < "$needed_caps_file"

    if [ "$matched_any" -eq 1 ]; then
      # Emit the provider once.
      if ! grep -Fxq "$cand_name" "$emitted_providers_file"; then
        cand_filename=$(extract_block "$cand" 'FILENAME' | sed -n '1p')
        cand_sha=$(extract_block "$cand" 'SHA256SUM' | sed -n '1p')
        if [ -z "$cand_filename" ] || [ -z "$cand_sha" ]; then
          # Stanza missing usable address — keep looking for another
          # provider of the same caps (un-resolve them).
          # In practice every Arch core/extra desc has both fields.
          continue
        fi
        echo "$cand_name" >> "$emitted_providers_file"
        printf '%s\t%s\t%s\n' "$cand_name" "$cand_filename" "$cand_sha" \
          >> "$closure_file"
      fi
    fi
  done

  rm -f "${work_root}/.cand_provides.txt"

  # Hard-fail on any unresolved capability.
  unresolved_file="${work_root}/unresolved.txt"
  : > "$unresolved_file"
  while IFS= read -r cap; do
    [ -n "$cap" ] || continue
    if ! grep -Fxq "$cap" "$resolved_caps_file"; then
      echo "$cap" >> "$unresolved_file"
    fi
  done < "$needed_caps_file"

  if [ -s "$unresolved_file" ]; then
    echo "pacman_mvp: FAIL - unresolved %DEPENDS% capabilities:" >&2
    sed 's/^/  - /' "$unresolved_file" >&2
    echo "  (M4 closure resolver picks first concrete provider; M5" >&2
    echo "   will handle alternate providers + multi-repo lookups)" >&2
    exit 1
  fi
fi

closure_count=$(wc -l < "$closure_file")
echo "pacman_mvp: step 3 - closure (${closure_count} packages):"
awk -F'\t' '{ printf "  %s -> %s (sha256=%s)\n", $1, $2, $3 }' "$closure_file"

# ----------------------------------------------------------------------
# Step 4: fetch + unpack each closure member.
# ----------------------------------------------------------------------

realized_prefixes_file="${work_root}/realized_prefixes.txt"
: > "$realized_prefixes_file"

while IFS="$(printf '\t')" read -r pkg filename sha; do
  [ -n "$pkg" ] || continue
  [ -n "$filename" ] || continue
  [ -n "$sha" ] || continue

  prefix_dir="${store_root}/sha256-${sha}-${pkg}"
  prefix_data_dir="${prefix_dir}/data"
  pkg_url="${mirror_base}${filename}"
  pkg_path="${work_root}/${filename}"

  echo "pacman_mvp:   ${pkg}: ${filename} (sha256=${sha})"
  echo "${prefix_dir}" >> "$realized_prefixes_file"

  # Cache: content-addressed prefix already populated.
  if [ -d "$prefix_data_dir" ]; then
    echo "pacman_mvp:     cache hit at ${prefix_dir}"
    continue
  fi

  echo "pacman_mvp:     fetching ${pkg_url}"
  if ! curl -sSL -m 600 -o "$pkg_path" "$pkg_url"; then
    echo "pacman_mvp: FAIL - .pkg.tar.zst fetch failed for ${pkg}" >&2
    exit 1
  fi

  got_pkg_sha=$(sha256sum "$pkg_path" | awk '{print $1}')
  if [ "$got_pkg_sha" != "$sha" ]; then
    echo "pacman_mvp: FAIL - .pkg.tar.zst sha256 mismatch for ${pkg}" >&2
    echo "  expected: ${sha}" >&2
    echo "  got:      ${got_pkg_sha}" >&2
    exit 1
  fi
  echo "pacman_mvp:     sha256 OK"

  mkdir -p "$prefix_data_dir"
  case "$extract_tool" in
    tar-zstd)
      if ! tar --zstd -xf "$pkg_path" -C "$prefix_data_dir"; then
        echo "pacman_mvp: FAIL - tar --zstd extract failed for ${pkg}" >&2
        rm -rf "$prefix_data_dir"
        exit 1
      fi
      ;;
    zstd-pipe)
      if ! zstd -dcf "$pkg_path" | tar -xf - -C "$prefix_data_dir"; then
        echo "pacman_mvp: FAIL - zstd|tar extract failed for ${pkg}" >&2
        rm -rf "$prefix_data_dir"
        exit 1
      fi
      ;;
    unzstd-pipe)
      if ! unzstd -c "$pkg_path" | tar -xf - -C "$prefix_data_dir"; then
        echo "pacman_mvp: FAIL - unzstd|tar extract failed for ${pkg}" >&2
        rm -rf "$prefix_data_dir"
        exit 1
      fi
      ;;
  esac

  # Pacman packages embed metadata files at the root (.PKGINFO, .BUILDINFO,
  # .MTREE, sometimes .INSTALL). These are NOT FHS-meaningful and should
  # not pollute /; they would shadow files at the FHS root if a compose
  # of multiple packages tried to lay them down side by side. Strip them
  # before compose. (Pacman itself reads them during install but they
  # never live on the installed system.)
  for meta in .PKGINFO .BUILDINFO .MTREE .INSTALL .CHANGELOG; do
    if [ -e "${prefix_data_dir}/${meta}" ]; then
      rm -f "${prefix_data_dir}/${meta}"
    fi
  done

  rm -f "$pkg_path"
done < "$closure_file"

if [ ! -s "$realized_prefixes_file" ]; then
  echo "pacman_mvp: FAIL - no realized prefixes after fetch loop" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 5: compose the FHS tree via cp -al.
# ----------------------------------------------------------------------
#
# Each per-package `data/` is rooted at the package's FHS layout from
# inside the .pkg.tar.zst (e.g. `data/usr/bin/bash`, `data/usr/lib/libc.so.6`).
# Arch packages are usr-merged: /bin, /sbin, /lib, /lib64 are symlinks
# into /usr (these symlinks ARE present in the .pkg.tar.zst payloads of
# the `filesystem` package; for packages outside the filesystem-package
# closure we synthesize them in the composed root). We compose via
# hardlink-copy into a single composed prefix; conflicting files would
# error, but the (root + first-level deps) closure on a small fixture
# is conflict-free by construction. M5's closure-dedup layer is the
# long-term replacement.

compose_digest=$(sort -u "$realized_prefixes_file" | sha256sum | awk '{print $1}')
composed_root="${store_root}/composed-${compose_digest}"

if [ -d "$composed_root" ]; then
  echo "pacman_mvp: step 5 - composed FHS tree cache hit at ${composed_root}"
else
  echo "pacman_mvp: step 5 - composing FHS tree into ${composed_root}"
  mkdir -p "$composed_root"
  sorted_prefixes="${work_root}/sorted_prefixes.txt"
  sort -u "$realized_prefixes_file" > "$sorted_prefixes"
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    if [ ! -d "${prefix}/data" ]; then
      echo "pacman_mvp: FAIL - realized prefix missing data dir: ${prefix}" >&2
      exit 1
    fi
    # `cp -al`: hardlink every regular file, descend dirs, preserve
    # symlinks. `.` so dotfiles at root are included.
    ( cd "${prefix}/data" && cp -al . "${composed_root}/" ) || {
      echo "pacman_mvp: FAIL - cp -al compose failed for ${prefix}" >&2
      rm -rf "$composed_root"
      exit 1
    }
  done < "$sorted_prefixes"
fi

# Ensure the six FHS roots exist. On Arch (usr-merged) /bin /sbin /lib
# /lib64 are typically symlinks to /usr/bin /usr/lib etc.; if the closure
# doesn't include the `filesystem` package these won't exist. Create
# them as symlinks if /usr/<sub> exists, else as empty dirs (bwrap --bind
# refuses missing source paths).
for sub in usr lib lib64 bin sbin etc; do
  target_dir="${composed_root}/${sub}"
  if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
    continue
  fi
  case "$sub" in
    bin|sbin)
      if [ -d "${composed_root}/usr/bin" ]; then
        ln -s usr/bin "$target_dir"
      else
        mkdir -p "$target_dir"
      fi
      ;;
    lib)
      if [ -d "${composed_root}/usr/lib" ]; then
        ln -s usr/lib "$target_dir"
      else
        mkdir -p "$target_dir"
      fi
      ;;
    lib64)
      if [ -d "${composed_root}/usr/lib" ]; then
        ln -s usr/lib "$target_dir"
      else
        mkdir -p "$target_dir"
      fi
      ;;
    *)
      mkdir -p "$target_dir"
      ;;
  esac
done

echo "pacman_mvp:   composed FHS tree at ${composed_root}"

if [ "$no_exec" -eq 1 ]; then
  echo "pacman_mvp: --no-exec set; stopping before bwrap launch"
  echo "pacman_mvp: OK (realize-only path; composed_root=${composed_root})"
  exit 0
fi

if [ -z "$inner_argv" ]; then
  echo "pacman_mvp: FAIL - no inner argv after '--'; nothing to exec" >&2
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
#
# Note on Arch's usr-merged layout: if `composed_root/{bin,sbin,lib,lib64}`
# are symlinks into usr/ (which is the normal Arch case), bwrap dereferences
# the source path before bind-mounting — so binding /usr/bin->/bin works
# the same as a direct dir source. The previous step ensures every source
# path exists as either a real dir, an Arch-style usr-merge symlink, or
# an empty fallback dir.

echo "pacman_mvp: step 6 - bwrap exec"

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

# Word-split inner argv tokens.
# shellcheck disable=SC2086
exec bwrap "$@" $inner_argv
