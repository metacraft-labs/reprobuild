#!/usr/bin/env python3
"""wire-cache-into-build-scripts.py — A3 P5 wiring tool.

Injects the cache-helper prelude + postlude into each R4-R9 build-*.sh
script. The injection points are:

  PRELUDE: right after the last ``OUT_ABS="$(cd "$OUT" && pwd)"`` (or
           equivalent) assignment so $OUT_ABS is set when the cache
           prelude runs.

  POSTLUDE: at end-of-file, after the last meaningful line.

The injection is idempotent: a marker line ``# A3 P5 cache wiring``
brackets the inserted block; a second invocation detects the marker
and skips. Run this once per repo checkout to refresh all scripts.

Inputs:
  Each invocation handles one build-*.sh path. Pass --dry-run to
  preview the diff without writing.

Per-script knobs are embedded in this file (see PHASE_TABLE). Each
script needs:
  - the package-name + version,
  - the toolchain-name + version,
  - the list of "<UPPER_VAR>_ABS" paths that point at prior phases
    (for dep tracking),
  - whether the script writes a single output file (like build-hex0.sh)
    or a directory (everything else).
"""

import argparse
import os
import sys
from pathlib import Path

PHASE_TABLE = {
    # R4 scripts — already manually wired but kept here for completeness.
    "build-hex0.sh": ("hex0", "stage0-posix-Release_1.9.1",
                      "stage0-posix", "Release_1.9.1", [], "single-file"),
    "build-stage0-posix.sh": ("stage0-posix", "Release_1.9.1",
                              "stage0-posix", "Release_1.9.1",
                              [("HEX0", "binary")], "dir"),
    "build-mescc-tools.sh": ("mescc-tools", "Release_1.9.1",
                             "stage0-posix", "Release_1.9.1",
                             [("STAGE0_ABS", "dir")], "dir"),
    "build-mes.sh": ("mes", "0.27.1", "mescc-tools", "Release_1.9.1",
                     [("MESCC_TOOLS_ABS", "dir")], "dir"),
    "build-tcc.sh": ("tinycc-bootstrappable", "ea3900f6",
                     "mes", "0.27.1",
                     [("MES_ABS", "dir"), ("MESCC_TOOLS_ABS", "dir")], "dir"),

    # R5 scripts.
    "build-tcc-shim.sh": ("tcc-shim", "0.1", "tcc", "boot",
                          [("BUILD_ABS", "dir")], "dir-shim"),
    "build-tinycc-mes.sh": ("tinycc-mes", "0.9.27", "mes", "0.27.1",
                            [("MES_ABS", "dir"), ("TCC_ABS", "dir")], "dir"),
    "build-tinycc-musl.sh": ("tinycc-musl", "0.9.27", "tinycc", "musl",
                             [("TINYCC_MES_ABS", "dir")], "dir"),
    "build-binutils-tcc.sh": ("binutils", "2.46.0", "tinycc-musl", "0.9.27",
                              [("TINYCC_MUSL_ABS", "dir")], "dir"),
    "build-gcc-4.6.sh": ("gcc", "4.6.4", "tinycc-musl-binutils", "1",
                         [("BINUTILS_ABS", "dir"),
                          ("TINYCC_MUSL_ABS", "dir")], "dir"),
    "build-gcc-4.6-cxx.sh": ("gcc-cxx", "4.6.4", "gcc", "4.6.4",
                             [("GCC_4_6_ABS", "dir")], "dir"),
    "build-musl-tcc.sh": ("musl", "1.2.5", "tinycc-musl", "0.9.27",
                          [("TINYCC_MUSL_ABS", "dir")], "dir"),
    "build-musl-gcc.sh": ("musl-gcc", "1.2.5", "gcc", "4.6.4",
                          [("GCC_4_6_ABS", "dir"), ("MUSL_ABS", "dir")], "dir"),
    "build-gcc-10.4.sh": ("gcc", "10.4.0", "gcc-4.6-cxx", "4.6.4",
                          [("GCC_4_6_CXX_ABS", "dir")], "dir"),
    "build-gcc-15.2.sh": ("gcc", "15.2.0", "gcc-10.4", "10.4.0",
                          [("GCC_10_4_ABS", "dir")], "dir"),

    # R6 scripts.
    "build-linux-headers.sh": ("linux-headers", "6.6.142", "gcc", "10.4.0",
                               [("GCC_10_4_ABS", "dir")], "dir"),
    "build-glibc.sh": ("glibc", "2.42", "gcc-10.4", "10.4.0",
                       [("GCC_10_4_ABS", "dir"),
                        ("LINUX_HEADERS_ABS", "dir")], "dir"),
    "build-cc-wrapper-glibc.sh": ("gcc-wrapper-glibc", "1.0",
                                  "gcc-15.2", "15.2.0",
                                  [("GCC_15_2_ABS", "dir"),
                                   ("GLIBC_ABS", "dir")], "dir"),

    # R7 scripts.
    "build-ncurses.sh": ("ncurses", "6.5", "gcc-wrapper", "1.0",
                         [("CC_WRAPPER_ABS", "dir")], "dir"),
    "build-libxcrypt.sh": ("libxcrypt", "4.4.36", "gcc-wrapper", "1.0",
                           [("CC_WRAPPER_ABS", "dir")], "dir"),
    "build-bash.sh": ("bash", "5.2", "gcc-wrapper", "1.0",
                      [("CC_WRAPPER_ABS", "dir")], "dir"),
    "build-coreutils.sh": ("coreutils", "9.5", "gcc-wrapper", "1.0",
                           [("CC_WRAPPER_ABS", "dir")], "dir"),
    "build-util-linux.sh": ("util-linux", "2.41", "gcc-wrapper", "1.0",
                            [("CC_WRAPPER_ABS", "dir")], "dir"),
    "build-linux-pam.sh": ("linux-pam", "1.6", "gcc-wrapper", "1.0",
                           [("CC_WRAPPER_ABS", "dir")], "dir"),
    "build-shadow.sh": ("shadow", "4.16", "gcc-wrapper", "1.0",
                        [("CC_WRAPPER_ABS", "dir")], "dir"),

    # R8 scripts.
    "build-linux-kernel.sh": ("linux-kernel", "6.6.142", "gcc-wrapper", "1.0",
                              [("CC_WRAPPER_ABS", "dir")], "dir"),

    # R9 scripts.
    "build-systemd.sh": ("systemd", "257.9", "gcc-wrapper", "1.0",
                         [("CC_WRAPPER_ABS", "dir")], "dir"),
    "build-initramfs.sh": ("initramfs", "1.0", "userspace-chain", "1.0",
                           [("ROOTFS_ABS", "dir")], "dir"),
    "build-minimal-initramfs.sh": ("minimal-initramfs", "1.0",
                                   "userspace-chain", "1.0",
                                   [("ROOTFS_ABS", "dir")], "dir"),
}

PRELUDE_MARKER_START = "# ---- A3 P5 cache prelude (auto-wired) ----"
PRELUDE_MARKER_END = "# ---- /A3 P5 cache prelude --------------------"
POSTLUDE_MARKER_START = "# ---- A3 P5 cache postlude (auto-wired) ----"
POSTLUDE_MARKER_END = "# ---- /A3 P5 cache postlude -------------------"


def render_prelude(spec):
    (pkg_name, pkg_version, tool_name, tool_version, dep_vars, shape) = spec
    # ``dir-shim`` scripts (e.g. build-tcc-shim.sh) use ``SHIM_ABS`` instead
    # of ``OUT_ABS``. Alias upfront so the cache-helper sees what it expects.
    alias_block = ""
    if shape == "dir-shim":
        alias_block = 'OUT_ABS="${SHIM_ABS:-${OUT_ABS:-}}"\n'

    deps_block = ""
    for var, kind in dep_vars:
        deps_block += f'  _depfile="${{{var}%/bin}}/.cache-key.hex"\n'
        deps_block += '  if [[ -f "${_depfile}" ]]; then\n'
        deps_block += '    _phase_deps+=( --dep="$(cat "${_depfile}")" )\n'
        deps_block += '  fi\n'
        # If the var points at a single binary path (e.g. HEX0), also try
        # the parent dir for the keyfile.
        if kind == "binary":
            deps_block += '  _depfile="$(dirname "${' + var + '}")/.cache-key.hex"\n'
            deps_block += '  if [[ -f "${_depfile}" ]]; then\n'
            deps_block += '    _phase_deps+=( --dep="$(cat "${_depfile}")" )\n'
            deps_block += '  fi\n'

    block = f'''{PRELUDE_MARKER_START}
{alias_block}
_script_dir="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
_repo_root="$(cd "${{_script_dir}}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${{_repo_root}}/recipes/cache/scripts/cache-helper.sh"

if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
  _phase_deps=()
{deps_block}  cache_phase_prepare "${{BASH_SOURCE[0]}}" "${{OUT_ABS}}" \\
    --package-name={pkg_name} \\
    --package-version={pkg_version} \\
    --toolchain-name={tool_name} \\
    --toolchain-version={tool_version} \\
    "${{_phase_deps[@]}}"
  echo "[cache] {pkg_name} cache-entry-key=${{CACHE_KEY_HEX}}"
  echo "${{CACHE_KEY_HEX}}" > "${{OUT_ABS}}/.cache-key.hex"
  if [[ "${{CACHE_HIT}}" == "1" ]]; then
    if [[ -d "${{OUT_ABS}}/prefix" ]]; then
      cp -a "${{OUT_ABS}}/prefix/." "${{OUT_ABS}}/"
      rm -rf "${{OUT_ABS}}/prefix"
      echo "[cache hit] {pkg_name} from cache"
      exit 0
    fi
    rm -rf "${{OUT_ABS}}/prefix"
  elif [[ "${{CACHE_HIT}}" == "2" ]]; then
    echo "[cache] {pkg_name}: REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
fi
{PRELUDE_MARKER_END}
'''
    return block


def render_postlude(spec):
    return f'''
{POSTLUDE_MARKER_START}
if [[ -n "${{CACHE_KEY_HEX:-}}" ]]; then
  cache_phase_publish "${{OUT_ABS}}"
fi
{POSTLUDE_MARKER_END}
'''


def find_prelude_insert_pos(lines):
    """Return the line index AFTER which the prelude should be inserted.

    Looks for ``OUT_ABS=`` (or ``SHIM_ABS=``) assignment near the top.
    Falls back to ``mkdir -p "$OUT"`` or ``mkdir -p "$SHIM_OUT"``."""
    last_out_abs = -1
    last_mkdir_out = -1
    for i, line in enumerate(lines):
        if (line.startswith("OUT_ABS=") or line.startswith("SHIM_ABS=")) \
                and i < 80:
            last_out_abs = i
        if ('mkdir -p "$OUT"' in line or
            'mkdir -p "$SHIM_OUT"' in line) and i < 80:
            last_mkdir_out = i
    if last_out_abs >= 0:
        return last_out_abs + 1
    if last_mkdir_out >= 0:
        return last_mkdir_out + 1
    return -1


def find_r7_prefix(lines):
    """Hardcoded-prefix scripts (R7+) use ``--prefix=/tmp/r7-build/<pkg>``.

    Returns the prefix path string, or None if not found."""
    import re
    for line in lines:
        m = re.search(r'--prefix=(/tmp/r\d+-build/\S+)', line)
        if m:
            return m.group(1).rstrip('"\'\\')
    return None


def render_prelude_r7(spec, prefix_path):
    (pkg_name, pkg_version, tool_name, tool_version, dep_vars, shape) = spec
    block = f'''{PRELUDE_MARKER_START}
# Hardcoded-prefix R7+ wiring: prefix derived from --prefix= line.
__R7_OUT_ABS="{prefix_path}"
__R7_REPO_ROOT="$(cd "$(dirname "${{BASH_SOURCE[0]}}")/../../../.." && pwd 2>/dev/null || echo "")"
if [ -n "$__R7_REPO_ROOT" ] && [ -f "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh" ]; then
  # shellcheck source=/dev/null
  . "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh"
  if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
    OUT_ABS="$__R7_OUT_ABS"
    mkdir -p "$OUT_ABS"
    cache_phase_prepare "${{BASH_SOURCE[0]}}" "$OUT_ABS" \\
      --package-name={pkg_name} \\
      --package-version={pkg_version} \\
      --toolchain-name={tool_name} \\
      --toolchain-version={tool_version}
    echo "[cache] {pkg_name} cache-entry-key=${{CACHE_KEY_HEX}}"
    echo "${{CACHE_KEY_HEX}}" > "$OUT_ABS/.cache-key.hex"
    if [ "${{CACHE_HIT}}" = "1" ]; then
      if [ -d "$OUT_ABS/prefix" ]; then
        cp -a "$OUT_ABS/prefix/." "$OUT_ABS/"
        rm -rf "$OUT_ABS/prefix"
        echo "[cache hit] {pkg_name} from cache"
        exit 0
      fi
      rm -rf "$OUT_ABS/prefix"
    elif [ "${{CACHE_HIT}}" = "2" ]; then
      echo "[cache] {pkg_name}: REPRO_CACHE_DRY_RUN=1; skipping build."
      exit 0
    fi
  fi
fi
{PRELUDE_MARKER_END}
'''
    return block


def render_postlude_r7():
    return f'''
{POSTLUDE_MARKER_START}
if [ -n "${{CACHE_KEY_HEX:-}}" ]; then
  cache_phase_publish "${{OUT_ABS}}" || true
fi
{POSTLUDE_MARKER_END}
'''


def find_r7_prelude_insert_pos(lines):
    """For R7+ scripts: insert right after the ``set -e`` line near top."""
    for i, line in enumerate(lines):
        if line.strip().startswith("set -e") and i < 5:
            return i + 1
    # Fallback: after shebang
    return 1


def already_wired(content):
    return (PRELUDE_MARKER_START in content) or \
           ("cache_phase_prepare " in content)


def wire_one(path, spec, dry_run):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if already_wired(content):
        return ("skipped", "already wired")
    lines = content.splitlines(keepends=True)
    pos = find_prelude_insert_pos(lines)
    if pos >= 0:
        prelude = render_prelude(spec)
        postlude = render_postlude(spec)
        new_lines = lines[:pos] + [prelude] + lines[pos:] + [postlude]
        new_content = "".join(new_lines)
        if dry_run:
            return ("would-wire", f"OUT_ABS hook (+{prelude.count(chr(10))} prelude, "
                                  f"+{postlude.count(chr(10))} postlude lines)")
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
        return ("wired", "OUT_ABS hook")

    # R7+ hardcoded-prefix shape.
    prefix = find_r7_prefix(lines)
    if prefix:
        r7_pos = find_r7_prelude_insert_pos(lines)
        prelude = render_prelude_r7(spec, prefix)
        postlude = render_postlude_r7()
        new_lines = lines[:r7_pos] + [prelude] + lines[r7_pos:] + [postlude]
        new_content = "".join(new_lines)
        if dry_run:
            return ("would-wire", f"R7-prefix hook (prefix={prefix})")
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
        return ("wired", f"R7-prefix hook ({prefix})")

    return ("error", "could not find $OUT_ABS / mkdir / --prefix= hook point")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--only", action="append", default=[],
                        help="restrict to listed scripts (basename)")
    args = parser.parse_args()
    repo_root = Path(args.repo_root)
    search_dirs = [
        repo_root / "recipes" / "bootstrap" / "tcc-chain" / "scripts",
        repo_root / "recipes" / "bootstrap" / "kernel" / "scripts",
        repo_root / "recipes" / "bootstrap" / "systemd" / "scripts",
    ]
    total = 0
    wired = 0
    skipped = 0
    errors = 0
    for d in search_dirs:
        if not d.is_dir():
            continue
        for path in sorted(d.glob("build-*.sh")):
            name = path.name
            if args.only and name not in args.only:
                continue
            if name not in PHASE_TABLE:
                print(f"SKIP {name}: no PHASE_TABLE entry")
                continue
            total += 1
            status, note = wire_one(path, PHASE_TABLE[name], args.dry_run)
            print(f"{status:>12} {name}: {note}")
            if status in ("wired", "would-wire"):
                wired += 1
            elif status == "skipped":
                skipped += 1
            elif status == "error":
                errors += 1
    print(f"\nTotal: {total}; wired: {wired}; skipped: {skipped}; "
          f"errors: {errors}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
