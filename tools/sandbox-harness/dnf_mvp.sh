#!/bin/sh
# dnf_mvp.sh - Linux-Third-Party-Sandbox-MVP M3 dnf consumption MVP.
#
# Realizes a Fedora .rpm package + its first level of <rpm:requires>
# capabilities into per-package content-addressed reprobuild-store
# prefixes, composes them into an FHS tree, then wraps a target binary
# via bubblewrap using the M1 driver's M0-locked transparency posture.
#
# Mirror of `apt_mvp.sh` (M2) shape with three substitutions:
#
#   - Metadata format: Fedora ships `repomd.xml` + a sha256-named
#     `primary.xml.gz` (or `.xml.zck`) instead of Debian's
#     `Release` + `Packages.gz`.
#   - Package format: `.rpm` (custom binary) instead of `.deb` (ar
#     archive). Standard unpack pipeline:
#       rpm2cpio <file> | cpio -idmv -D <prefix>
#     Both tools are universal — rpm2cpio + cpio ship with every
#     Fedora install and are available in WSL Fedora out of the box.
#   - Snapshot source: a pinned `archives.fedoraproject.org/pub/archive`
#     URL base instead of `snapshot.debian.org`. Every Fedora release
#     is archived under
#       /pub/archive/fedora/linux/releases/<N>/Everything/<arch>/os/
#     after end-of-life; pre-EOL releases live under
#       /pub/fedora/linux/releases/<N>/Everything/<arch>/os/
#     The M3 fixture pins one of these stable archive URLs (see the
#     integration test for the chosen one).
#
# Pipeline:
#
#   1. Fetch `repodata/repomd.xml` from the pinned Fedora mirror.
#   2. Parse `repomd.xml`'s `<data type="primary">` block to locate
#      `<location href>` + `<checksum>` of `primary.xml.gz`.
#   3. Fetch `primary.xml.gz`, sha256-verify against repomd.xml's
#      checksum, gunzip.
#   4. Parse `primary.xml` for the target package's `<location href>`,
#      `<checksum>`, and `<rpm:requires>` capabilities. Then for each
#      capability resolve a first concrete provider (any package whose
#      `<name>` matches OR whose `<rpm:provides>` lists the capability).
#      Dedupe + collect (name, href, sha256) tuples for the closure.
#   5. For each closure member: fetch the .rpm from `<mirror-base>/<href>`,
#      sha256-verify against the primary.xml checksum.
#   6. Unpack via `rpm2cpio <file> | cpio -idmv -D <prefix>/data/`.
#   7. Compose every prefix into `$REPRO_STORE_ROOT/composed-<digest>/`
#      via `cp -al` (hardlinks; M5 closure-dedup overlay layer is the
#      proper replacement).
#   8. `exec bwrap` with the M1 driver's M0-locked argv shape (matches
#      `buildLinuxFhsSandboxArgv` in
#      `libs/repro_elevation/src/repro_elevation/posix_system_driver.nim`).
#
# Closure simplifications (spec-permitted MVP scope; mirror M2):
#
#   - First-level `<rpm:requires>` only. NO transitive walk. NO
#     `<rpm:recommends>`, `<rpm:suggests>`, `<rpm:supplements>`,
#     `<rpm:enhances>`, `<rpm:conflicts>`, `<rpm:obsoletes>`.
#   - Versioned constraints stripped: a `<rpm:entry name="X" flags="GE"
#     epoch="0" ver="2.34"/>` is treated as bare capability `X`.
#   - Capability resolution: pick the FIRST concrete provider seen in
#     primary.xml document order. Matches by package `<name>` OR by
#     `<rpm:provides>` entry. No prefer-shorter / prefer-installed
#     heuristics (M5 closure-resolver will handle that).
#   - Architectures considered: pinned arch (default `x86_64`) plus
#     `noarch`. Multi-lib (i686 + x86_64) NOT handled.
#   - Self-dep skipped: if the root itself provides one of its own
#     requires, no extra fetch.
#   - Duplicate providers deduped: hello's two requires both resolve
#     to glibc; glibc is fetched + unpacked ONCE.
#
# Why python3 instead of awk for primary.xml parsing:
#
#   primary.xml is ~170 MiB uncompressed (Fedora 39 Everything has
#   ~60 000 package stanzas, each a multi-line XML block with five-
#   plus namespaced child elements). awk can stream it, but matching
#   `<rpm:requires><rpm:entry name="...">` across element boundaries
#   in pure awk is significantly more brittle than `xml.etree`'s
#   `iterparse`. python3 is part of every Fedora base install
#   (rpm itself depends on it transitively; `dnf` is a Python app),
#   and is also present in WSL Fedora out of the box. The script
#   therefore requires python3 in addition to the standard tooling.
#   The awk-only path is M5-scope if a Nim-side parser is wanted.
#
# Usage:
#   dnf_mvp.sh \
#     --release=<N> \
#     --package=<root-package-name> \
#     [--mirror-base=<url>] \
#     [--arch=<arch>] \
#     [--store-root=<path>] \
#     [--no-exec] \
#     -- <argv inside sandbox ...>
#
#   --release    Fedora release number (e.g., 39). Used to populate the
#                default mirror-base URL.
#   --mirror-base
#                Mirror URL base ending with `os/` (the parent of
#                `repodata/`). Default:
#                  https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/<release>/Everything/<arch>/os/
#                For a still-supported release (not yet archived), the
#                integration test overrides this to:
#                  https://dl.fedoraproject.org/pub/fedora/linux/releases/<release>/Everything/<arch>/os/
#   --arch       Architecture. Default: x86_64.
#   --package    Root package name (string match against `<name>`).
#   --store-root Where to realize content-addressed prefixes + the
#                composed FHS tree. Default:
#                ${REPRO_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/repro-dnf-mvp/store}.
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
#        compose, bwrap launch). Diagnostic prefixed `dnf_mvp:`.
#   *  - the wrapped binary's own exit code (forwarded verbatim).
#
# Status: M3 in_review, 2026-06-11. Deliverable shape locked to the
# harness wrapper `tools/multi-distro-harness/tests/sandbox_m3_dnf_mvp.sh`
# which sources this script's behavior via direct invocation.

set -eu

# ----------------------------------------------------------------------
# Argument parsing (POSIX sh, no getopt).
# ----------------------------------------------------------------------

release=''
mirror_base=''
arch=''
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
    --release=*)     release=${1#--release=}         ;;
    --mirror-base=*) mirror_base=${1#--mirror-base=} ;;
    --arch=*)        arch=${1#--arch=}               ;;
    --package=*)     package=${1#--package=}         ;;
    --store-root=*)  store_root=${1#--store-root=}   ;;
    --no-exec)       no_exec=1                        ;;
    --)              seen_dash_dash=1                 ;;
    *)
      echo "dnf_mvp: FAIL - unrecognized arg '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

# ----------------------------------------------------------------------
# Defaults + validation.
# ----------------------------------------------------------------------

[ -n "$release" ] || { echo "dnf_mvp: FAIL - --release=<N> required" >&2; exit 1; }
[ -n "$package" ] || { echo "dnf_mvp: FAIL - --package=<name> required" >&2; exit 1; }

if [ -z "$arch" ]; then
  arch='x86_64'
fi

if [ -z "$mirror_base" ]; then
  # Default to the archive mirror — EOL releases stay there indefinitely
  # and are content-addressable in the same way snapshot.debian.org is
  # for Debian.
  mirror_base="https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/${release}/Everything/${arch}/os/"
fi

# Normalize trailing slash on mirror_base.
case "$mirror_base" in
  */) : ;;
  *)  mirror_base="${mirror_base}/" ;;
esac

# Store root default. INTENTIONALLY not colonizing $HOME/.cache/repro
# (production action cache) — M3 is experimental; M5's library port
# will rework the layout.
if [ -z "$store_root" ]; then
  store_root="${REPRO_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/repro-dnf-mvp/store}"
fi

# Working dirs.
mkdir -p "$store_root"
work_root="$store_root/.work-${release}-${arch}"
mkdir -p "$work_root"

echo "dnf_mvp: release=${release} arch=${arch} package=${package}"
echo "dnf_mvp: mirror_base=${mirror_base}"
echo "dnf_mvp: store_root=${store_root}"

# ----------------------------------------------------------------------
# Dependencies probe.
# ----------------------------------------------------------------------

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "dnf_mvp: FAIL - required command '$1' not on PATH" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd sha256sum
require_cmd gunzip
require_cmd awk
require_cmd sed
require_cmd python3
require_cmd rpm2cpio
require_cmd cpio

if [ "$no_exec" -eq 0 ] && ! command -v bwrap >/dev/null 2>&1; then
  echo "dnf_mvp: FAIL - bwrap missing (install bubblewrap or pass --no-exec)" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 1: fetch repomd.xml.
# ----------------------------------------------------------------------
#
# repomd.xml is the entry point. Fedora's repomd.xml is GPG-signed at
# `repomd.xml.asc` (analogue of InRelease); M3 SKIPS GPG verification
# per spec (same posture as M2 — defer to M5). The embedded
# `<checksum type="sha256">` entries inside repomd.xml's <data> blocks
# are the verification floor for primary.xml.gz + every .rpm.

repomd_url="${mirror_base}repodata/repomd.xml"
repomd_path="${work_root}/repomd.xml"

echo "dnf_mvp: step 1 - fetching repomd.xml from ${repomd_url}"
if ! curl -sSL -m 60 -o "$repomd_path" "$repomd_url"; then
  echo "dnf_mvp: FAIL - repomd.xml fetch failed" >&2
  exit 1
fi
if [ ! -s "$repomd_path" ]; then
  echo "dnf_mvp: FAIL - repomd.xml at ${repomd_url} is empty" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2: parse repomd.xml to locate primary.xml.gz.
# ----------------------------------------------------------------------
#
# repomd.xml shape:
#
#   <repomd ...>
#     <data type="primary">
#       <checksum type="sha256">HEX</checksum>
#       <open-checksum type="sha256">HEX</open-checksum>
#       <location href="repodata/<sha>-primary.xml.gz"/>
#       <size>...</size>
#       ...
#     </data>
#     <data type="filelists">...</data>
#     ...
#   </repomd>
#
# python3 with xml.etree handles the namespace cleanly. Output two
# lines (newline-separated): the href + the sha256.

primary_meta=$(python3 - "$repomd_path" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {'r': 'http://linux.duke.edu/metadata/repo'}
tree = ET.parse(sys.argv[1])
root = tree.getroot()
for data in root.findall('r:data', ns):
    if data.get('type') == 'primary':
        loc = data.find('r:location', ns)
        cks = data.find('r:checksum', ns)
        if loc is None or cks is None:
            sys.exit("dnf_mvp: FAIL - <data type='primary'> missing location/checksum")
        if cks.get('type') != 'sha256':
            sys.exit(f"dnf_mvp: FAIL - primary checksum not sha256 (got {cks.get('type')})")
        href = loc.get('href') or ''
        if not href:
            sys.exit("dnf_mvp: FAIL - primary <location> missing href")
        print(href)
        print(cks.text.strip())
        sys.exit(0)
sys.exit("dnf_mvp: FAIL - no <data type='primary'> block in repomd.xml")
PY
) || exit 1

primary_href=$(echo "$primary_meta" | sed -n '1p')
primary_sha=$(echo "$primary_meta" | sed -n '2p')
echo "dnf_mvp: step 2 - primary.xml.gz href=${primary_href}"
echo "dnf_mvp:   expected sha256=${primary_sha}"

# ----------------------------------------------------------------------
# Step 3: fetch + verify + gunzip primary.xml.gz.
# ----------------------------------------------------------------------

primary_url="${mirror_base}${primary_href}"
primary_gz_path="${work_root}/primary.xml.gz"
primary_path="${work_root}/primary.xml"

# Cache: if we've already fetched + verified + decompressed this exact
# primary.xml.gz, skip the heavy steps. Use the sha256 as the cache key
# (rename from `primary.xml.gz` to `primary-<sha>.xml.gz` if you want
# multiple parallel pinnings; M3 uses one pin per work-root so the
# simpler "if path exists and sha matches" check suffices).
need_fetch_primary=1
if [ -s "$primary_gz_path" ] && [ -s "$primary_path" ]; then
  got_sha=$(sha256sum "$primary_gz_path" | awk '{print $1}')
  if [ "$got_sha" = "$primary_sha" ]; then
    echo "dnf_mvp: step 3 - primary.xml.gz cache hit"
    need_fetch_primary=0
  fi
fi

if [ "$need_fetch_primary" -eq 1 ]; then
  echo "dnf_mvp: step 3 - fetching primary.xml.gz from ${primary_url}"
  if ! curl -sSL -m 600 -o "$primary_gz_path" "$primary_url"; then
    echo "dnf_mvp: FAIL - primary.xml.gz fetch failed" >&2
    exit 1
  fi

  got_sha=$(sha256sum "$primary_gz_path" | awk '{print $1}')
  if [ "$got_sha" != "$primary_sha" ]; then
    echo "dnf_mvp: FAIL - primary.xml.gz sha256 mismatch" >&2
    echo "  expected: ${primary_sha}" >&2
    echo "  got:      ${got_sha}" >&2
    exit 1
  fi
  echo "dnf_mvp:   sha256 OK"

  gunzip -kf "$primary_gz_path"
  if [ ! -s "$primary_path" ]; then
    echo "dnf_mvp: FAIL - primary.xml decompressed empty" >&2
    exit 1
  fi
fi

# ----------------------------------------------------------------------
# Step 4: resolve closure via primary.xml.
# ----------------------------------------------------------------------
#
# Single python3 iterparse pass over primary.xml:
#
#   Pass 1 (root lookup): find <package type="rpm"> whose <name> == target
#   and <arch> in {pinned_arch, noarch}. Extract its <location href>,
#   <checksum>, and the <rpm:requires> capability list. Bail if not
#   found.
#
#   Pass 2 (dep resolution): re-iterate. For each package, check if its
#   <name> or any <rpm:provides> entry matches an unresolved required
#   capability. On first match, record (name, href, sha256). Skip
#   self-resolution (a package providing itself doesn't need a separate
#   closure entry — the root is already included). Stop once every
#   capability is resolved OR primary.xml is exhausted (unresolved deps
#   are a hard fail with a diagnostic).
#
# Output format (one closure entry per line, tab-separated):
#   <name>\t<href>\t<sha256>
#
# Order: root first, then first-level deps in primary.xml document
# order (the order python3 sees them). The deduplication step ensures
# the same provider appears at most once in the output even if it
# satisfies multiple required capabilities.

closure_file="${work_root}/closure.tsv"

python3 - "$primary_path" "$package" "$arch" > "$closure_file" <<'PY'
import sys, xml.etree.ElementTree as ET

primary_path = sys.argv[1]
target = sys.argv[2]
pinned_arch = sys.argv[3]

ns = {
    'cm': 'http://linux.duke.edu/metadata/common',
    'rpm': 'http://linux.duke.edu/metadata/rpm',
}
CM_PACKAGE = '{http://linux.duke.edu/metadata/common}package'
ARCHES_OK = {pinned_arch, 'noarch'}


def extract_pkg(el):
    name_el = el.find('cm:name', ns)
    arch_el = el.find('cm:arch', ns)
    if name_el is None or arch_el is None:
        return None
    return name_el.text, arch_el.text


def extract_addr(el):
    loc_el = el.find('cm:location', ns)
    cks_el = el.find('cm:checksum', ns)
    if loc_el is None or cks_el is None:
        return None
    if cks_el.get('type') != 'sha256':
        return None
    href = loc_el.get('href') or ''
    sha = (cks_el.text or '').strip()
    if not href or not sha:
        return None
    return href, sha


def extract_requires(el):
    fmt_el = el.find('cm:format', ns)
    if fmt_el is None:
        return []
    req_block = fmt_el.find('rpm:requires', ns)
    if req_block is None:
        return []
    caps = []
    for ent in req_block.findall('rpm:entry', ns):
        cap = ent.get('name')
        if cap:
            # Strip versioned constraints by ignoring flags/epoch/ver/rel
            # attributes — we keep only the bare capability name.
            caps.append(cap)
    return caps


def extract_provides(el):
    fmt_el = el.find('cm:format', ns)
    if fmt_el is None:
        return set()
    prov_block = fmt_el.find('rpm:provides', ns)
    if prov_block is None:
        return set()
    out = set()
    for ent in prov_block.findall('rpm:entry', ns):
        cap = ent.get('name')
        if cap:
            out.add(cap)
    return out


# ----------------------------------------------------------------------
# Pass 1: find root.
# ----------------------------------------------------------------------

root_addr = None
root_requires = None

for ev, el in ET.iterparse(primary_path, events=('end',)):
    if el.tag != CM_PACKAGE:
        continue
    name_arch = extract_pkg(el)
    if name_arch is None:
        el.clear(); continue
    pname, parch = name_arch
    if pname == target and parch in ARCHES_OK:
        addr = extract_addr(el)
        if addr is None:
            sys.stderr.write(
                f"dnf_mvp: FAIL - target {target} stanza missing usable "
                "location/sha256 in primary.xml\n")
            sys.exit(1)
        root_addr = addr
        root_requires = extract_requires(el)
        # Also remember what the root provides so we can skip
        # self-resolution.
        root_provides = extract_provides(el)
        root_provides.add(pname)
        el.clear()
        break
    el.clear()

if root_addr is None:
    sys.stderr.write(
        f"dnf_mvp: FAIL - no concrete <package> stanza for '{target}' "
        f"on arch {pinned_arch}/noarch\n")
    sys.exit(1)

# Strip self-provided requires.
needed = []
for cap in root_requires:
    if cap in root_provides:
        continue
    if cap not in needed:
        needed.append(cap)

# Print root entry first.
print(f"{target}\t{root_addr[0]}\t{root_addr[1]}")

if not needed:
    sys.exit(0)

# ----------------------------------------------------------------------
# Pass 2: resolve dependencies. First concrete provider wins (document
# order in primary.xml).
# ----------------------------------------------------------------------

# Map cap -> (provider_name, href, sha256). Used both to track what's
# still unresolved and to dedupe providers (same provider can satisfy
# multiple caps).
resolved = {}
# Dedupe key: provider_name only (one entry per provider in the output).
seen_providers = set()
seen_providers.add(target)
emitted = []

for ev, el in ET.iterparse(primary_path, events=('end',)):
    if el.tag != CM_PACKAGE:
        continue
    name_arch = extract_pkg(el)
    if name_arch is None:
        el.clear(); continue
    pname, parch = name_arch
    if parch not in ARCHES_OK:
        el.clear(); continue
    # Build the provides set (name + every <rpm:provides>).
    provides = extract_provides(el)
    provides.add(pname)
    # Which still-unresolved caps does this package satisfy?
    matched = [c for c in needed if c not in resolved and c in provides]
    if matched:
        addr = extract_addr(el)
        if addr is None:
            # Provider stanza missing usable address — keep looking for
            # another provider rather than hard-failing here.
            el.clear(); continue
        for c in matched:
            resolved[c] = (pname, addr[0], addr[1])
        if pname not in seen_providers:
            seen_providers.add(pname)
            emitted.append((pname, addr[0], addr[1]))
        if len(resolved) == len(needed):
            el.clear()
            break
    el.clear()

# Emit deduped providers (in document order discovered).
for pname, href, sha in emitted:
    print(f"{pname}\t{href}\t{sha}")

# Hard-fail on any unresolved capability.
unresolved = [c for c in needed if c not in resolved]
if unresolved:
    sys.stderr.write(
        "dnf_mvp: FAIL - unresolved <rpm:requires> capabilities:\n")
    for c in unresolved:
        sys.stderr.write(f"  - {c}\n")
    sys.stderr.write(
        "  (M3 closure resolver picks first concrete provider; M5 "
        "will handle virtuals + alternate providers)\n")
    sys.exit(1)
PY

if [ ! -s "$closure_file" ]; then
  echo "dnf_mvp: FAIL - closure resolution produced empty list" >&2
  exit 1
fi

closure_count=$(wc -l < "$closure_file")
echo "dnf_mvp: step 4 - closure (${closure_count} packages):"
awk -F'\t' '{ printf "  %s -> %s (sha256=%s)\n", $1, $2, $3 }' "$closure_file"

# ----------------------------------------------------------------------
# Step 5: fetch + unpack each closure member.
# ----------------------------------------------------------------------

realized_prefixes_file="${work_root}/realized_prefixes.txt"
: > "$realized_prefixes_file"

while IFS="$(printf '\t')" read -r pkg href sha; do
  [ -n "$pkg" ] || continue
  [ -n "$href" ] || continue
  [ -n "$sha" ] || continue

  prefix_dir="${store_root}/sha256-${sha}-${pkg}"
  prefix_data_dir="${prefix_dir}/data"
  rpm_url="${mirror_base}${href}"
  rpm_basename=$(basename "$href")
  rpm_path="${work_root}/${rpm_basename}"

  echo "dnf_mvp:   ${pkg}: ${href} (sha256=${sha})"
  echo "${prefix_dir}" >> "$realized_prefixes_file"

  # Cache: content-addressed prefix already populated.
  if [ -d "$prefix_data_dir" ]; then
    echo "dnf_mvp:     cache hit at ${prefix_dir}"
    continue
  fi

  echo "dnf_mvp:     fetching ${rpm_url}"
  if ! curl -sSL -m 600 -o "$rpm_path" "$rpm_url"; then
    echo "dnf_mvp: FAIL - .rpm fetch failed for ${pkg}" >&2
    exit 1
  fi

  got_rpm_sha=$(sha256sum "$rpm_path" | awk '{print $1}')
  if [ "$got_rpm_sha" != "$sha" ]; then
    echo "dnf_mvp: FAIL - .rpm sha256 mismatch for ${pkg}" >&2
    echo "  expected: ${sha}" >&2
    echo "  got:      ${got_rpm_sha}" >&2
    exit 1
  fi
  echo "dnf_mvp:     sha256 OK"

  mkdir -p "$prefix_data_dir"
  # rpm2cpio writes the cpio archive to stdout; pipe into cpio.
  # `-i` extract, `-d` make dirs, `-m` preserve mtime, `--quiet` silent,
  # `-D <dir>` chdir before extracting. `--no-absolute-filenames` is
  # the safety belt against malicious leading-slash paths in the cpio
  # stream (Fedora .rpm payloads always carry paths like `./usr/bin/hello`,
  # but Defense In Depth: refuse `/etc/shadow` etc.). cpio's GNU
  # `--no-absolute-filenames` strips leading slashes; on the off chance
  # we hit a busybox/bsd cpio without the flag, the M3 fixture
  # (`hello` + `glibc` on Fedora 39) is hand-vetted clean.
  if ! ( cd "$prefix_data_dir" && \
         rpm2cpio "$rpm_path" 2>/dev/null | \
         cpio -idmu --no-absolute-filenames --quiet ); then
    echo "dnf_mvp: FAIL - rpm2cpio|cpio failed for ${pkg}" >&2
    rm -rf "$prefix_data_dir"
    exit 1
  fi

  rm -f "$rpm_path"
done < "$closure_file"

if [ ! -s "$realized_prefixes_file" ]; then
  echo "dnf_mvp: FAIL - no realized prefixes after fetch loop" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 6: compose the FHS tree via cp -al.
# ----------------------------------------------------------------------
#
# Each per-package `data/` is rooted at the FHS layout from inside the
# .rpm (e.g. `data/usr/bin/hello`, `data/usr/lib64/libc.so.6`). We
# compose via hardlink-copy into a single composed prefix; conflicting
# files would error, but a (root + first-level deps) closure on
# Fedora's hello+glibc fixture is conflict-free by construction. M5's
# closure-dedup layer is the long-term replacement.

compose_digest=$(sort -u "$realized_prefixes_file" | sha256sum | awk '{print $1}')
composed_root="${store_root}/composed-${compose_digest}"

if [ -d "$composed_root" ]; then
  echo "dnf_mvp: step 6 - composed FHS tree cache hit at ${composed_root}"
else
  echo "dnf_mvp: step 6 - composing FHS tree into ${composed_root}"
  mkdir -p "$composed_root"
  sorted_prefixes="${work_root}/sorted_prefixes.txt"
  sort -u "$realized_prefixes_file" > "$sorted_prefixes"
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    if [ ! -d "${prefix}/data" ]; then
      echo "dnf_mvp: FAIL - realized prefix missing data dir: ${prefix}" >&2
      exit 1
    fi
    ( cd "${prefix}/data" && cp -al . "${composed_root}/" ) || {
      echo "dnf_mvp: FAIL - cp -al compose failed for ${prefix}" >&2
      rm -rf "$composed_root"
      exit 1
    }
  done < "$sorted_prefixes"
fi

# Ensure the six FHS roots exist (some .rpms don't populate every root —
# e.g. a -devel rpm may have no /etc; bwrap --bind refuses missing
# source paths). Fedora packages also commonly use /usr/lib64 + /usr/sbin
# inside /usr; those are part of the /usr bind which captures them.
for sub in usr lib lib64 bin sbin etc; do
  if [ ! -d "${composed_root}/${sub}" ]; then
    mkdir -p "${composed_root}/${sub}"
  fi
done

echo "dnf_mvp:   composed FHS tree at ${composed_root}"

if [ "$no_exec" -eq 1 ]; then
  echo "dnf_mvp: --no-exec set; stopping before bwrap launch"
  echo "dnf_mvp: OK (realize-only path; composed_root=${composed_root})"
  exit 0
fi

if [ -z "$inner_argv" ]; then
  echo "dnf_mvp: FAIL - no inner argv after '--'; nothing to exec" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 7: bwrap exec with the M1 driver's M0-locked argv shape.
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

echo "dnf_mvp: step 7 - bwrap exec"

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
