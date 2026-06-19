#!/usr/bin/env python3
"""M9.R.5b mechanical sweep: lift mesonOptions/cmakeFlags/configureFlags/
makeFlags blocks into config: + explicit build: blocks.

Per-recipe transformation:
  * Find the options block (one of mesonOptions/cmakeFlags/configureFlags/
    makeFlags), extract its string-literal flag list.
  * Identify the package name (first `package <name>:` head).
  * Identify declared executables and libraries (for the build: block to
    slice).
  * Replace the options block with a config: block containing one or more
    typed fields lifted from the flag set (lift `--prefix=...` as a
    `prefix: string` field; other flags stay inlined verbatim in the
    build block).
  * Append a build: block immediately before the `runtimeDeps:` block
    that calls the matching M9.R.2b constructor.

Output: rewrites each recipe in-place.
"""

from __future__ import annotations
import re
import sys
from pathlib import Path
from typing import List, Tuple, Optional

RECIPE_ROOT = Path("recipes/packages/source")

OPTION_BLOCKS = {
    "mesonOptions":   ("meson",     "meson_package",     "configureOptions"),
    "cmakeFlags":     ("cmake",     "cmake_package",     "cacheVars"),
    "configureFlags": ("autotools", "autotools_package", "configureOptions"),
    "makeFlags":      ("make",      "autotools_package", "configureOptions"),
}


def parse_package_name(text: str) -> Optional[str]:
    m = re.search(r"^package\s+([A-Za-z_][A-Za-z_0-9]*)\s*:\s*$", text,
                  re.MULTILINE)
    if not m:
        return None
    return m.group(1)


def find_options_block(text: str) -> Optional[Tuple[str, int, int, List[str]]]:
    """Find the recipe's options block. Returns (kind, start_line_idx,
    end_line_idx_exclusive, flag_literals). Returns None if no options
    block exists.

    The block looks like:

        <indent>kind:
        <indent>  ## comment lines
        <indent>  "flag1"
        <indent>  "flag2"

    We scan line-by-line. The block ends when the indent drops back to
    the kind's level or below (i.e. next sibling block).
    """
    lines = text.split("\n")
    for kind in OPTION_BLOCKS:
        head_re = re.compile(rf"^(\s+){re.escape(kind)}:\s*$")
        for idx, line in enumerate(lines):
            m = head_re.match(line)
            if not m:
                continue
            indent = m.group(1)
            # Walk forward, accumulating lines until indent <= kind indent
            # on a non-blank, non-comment line.
            end_idx = idx + 1
            flags: List[str] = []
            while end_idx < len(lines):
                line2 = lines[end_idx]
                stripped = line2.strip()
                if stripped == "" or stripped.startswith("##") or \
                        stripped.startswith("#"):
                    end_idx += 1
                    continue
                # Determine line indent (count leading whitespace)
                leading = len(line2) - len(line2.lstrip())
                if leading <= len(indent):
                    break
                # Inside the block — look for a string literal.
                flag_match = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*$', line2)
                if flag_match:
                    flags.append(flag_match.group(1))
                end_idx += 1
            return (kind, idx, end_idx, flags)
    return None


def parse_artifacts(text: str) -> List[Tuple[str, str]]:
    """Find `executable <name>:` and `library <name>:` declarations.
    Returns list of (kind, name) tuples in source order. The name may be
    a Nim identifier OR a quoted string literal (e.g. `executable "as":`).
    Returns the unquoted artifact name. Skips `files <name>:` entries.
    """
    out: List[Tuple[str, str]] = []
    pat = re.compile(
        r'^\s+(executable|library)\s+(?:"([^"]+)"|([A-Za-z_][A-Za-z_0-9]*))\s*:\s*$',
        re.MULTILINE)
    for m in pat.finditer(text):
        kind = m.group(1)
        name = m.group(2) if m.group(2) is not None else m.group(3)
        out.append((kind, name))
    return out


def parse_files_artifacts(text: str) -> List[str]:
    """Find `files <name>:` declarations."""
    out: List[str] = []
    pat = re.compile(
        r'^\s+files\s+(?:"([^"]+)"|([A-Za-z_][A-Za-z_0-9]*))\s*:\s*$',
        re.MULTILINE)
    for m in pat.finditer(text):
        name = m.group(1) if m.group(1) is not None else m.group(2)
        out.append(name)
    return out


def lift_prefix(flags: List[str]) -> Tuple[Optional[str], List[str]]:
    """If `--prefix=...` is among the flags, lift its value as the
    config-field default and return (prefix_default, remaining_flags).
    Otherwise return (None, flags)."""
    prefix_val: Optional[str] = None
    out: List[str] = []
    for f in flags:
        m = re.match(r"^--prefix=(.*)$", f)
        if m and prefix_val is None:
            prefix_val = m.group(1)
        else:
            out.append(f)
    return prefix_val, out


def nim_string_lit(s: str) -> str:
    """Return a Nim-syntax double-quoted string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def find_runtime_deps_line(text: str) -> Optional[int]:
    """Return the line index of the `<indent>runtimeDeps:` head, or None."""
    lines = text.split("\n")
    for idx, line in enumerate(lines):
        if re.match(r"^\s+runtimeDeps:\s*$", line):
            return idx
    return None


def package_uses_make(text: str) -> bool:
    """True if the recipe declares `make` (as build-system) but not meson/
    cmake/autoconf — used to decide between autotools_package and a
    custom make-only construct."""
    return bool(re.search(r'"make[\s">=<,]', text))


def find_options_block_indent(text: str, line_idx: int) -> str:
    """Return the leading indent of the line at `line_idx`."""
    line = text.split("\n")[line_idx]
    m = re.match(r"^(\s+)", line)
    return m.group(1) if m else "  "


def build_replacement(kind: str, package_name: str, indent: str,
                      flags: List[str], artifacts: List[Tuple[str, str]],
                      files_arts: List[str]) -> str:
    """Construct the replacement block (config: + the build: block to
    append before runtimeDeps:)."""
    _channel, ctor, ctor_arg = OPTION_BLOCKS[kind]
    prefix_default, remaining_flags = lift_prefix(flags)

    # config: block
    config_lines = [f"{indent}config:"]
    if prefix_default is not None:
        config_lines.append(
            f"{indent}  ## Install prefix passed to the upstream "
            f"build (lifted from `{kind}:`)."
        )
        config_lines.append(
            f"{indent}  prefix: string = {nim_string_lit(prefix_default)}")
    else:
        config_lines.append(
            f"{indent}  ## No prefix lifted from `{kind}:`; flags inlined "
            f"in the `build:` block."
        )
        config_lines.append(f"{indent}  discard")
    return "\n".join(config_lines)


def build_block_text(kind: str, package_name: str, indent: str,
                     flags: List[str],
                     artifacts: List[Tuple[str, str]],
                     files_arts: List[str]) -> str:
    """Render the trailing `build:` block that calls the M9.R.2b
    constructor and slices artifacts."""
    _channel, ctor, ctor_arg = OPTION_BLOCKS[kind]
    prefix_default, remaining_flags = lift_prefix(flags)

    lines: List[str] = []
    lines.append(f"{indent}build:")
    lines.append(
        f"{indent}  ## M9.R.5b — explicit `build:` block constructed from "
        f"the lifted `config:` values + the inlined verbatim flags. Calls "
        f"the M9.R.2b high-level `{ctor}(...)` constructor."
    )
    # Pin the per-edge owning-package override so the implicit-target-
    # name registry attributes the constructor's typed-tool actions to
    # THIS package (not the catalog package the typed-tool wrapper was
    # declared in — `meson` / `cmake` / `sh`). Without this, multiple
    # recipes calling `meson_package(...)` at module-init collide on
    # the implicit target name `build` within the `meson` catalog.
    lines.append(
        f"{indent}  setCurrentOwningPackageOverride("
        f"{nim_string_lit(package_name)})"
    )
    lines.append(f"{indent}  try:")
    inner = f"{indent}    "
    # Read prefix from configurable
    if prefix_default is not None:
        lines.append(
            f"{inner}let cfgPrefix = readConfigurable[string](")
        lines.append(
            f"{inner}  {nim_string_lit(package_name + '.prefix')}, "
            f"{nim_string_lit(prefix_default)})"
        )
    # Render flag list
    if remaining_flags:
        lines.append(f"{inner}let opts = @[")
        for f in remaining_flags:
            lines.append(f"{inner}  {nim_string_lit(f)},")
        lines.append(f"{inner}]")
    else:
        lines.append(f"{inner}let opts: seq[string] = @[]")
    # Constructor call
    if prefix_default is not None:
        ctor_call = (
            f"{inner}let pkg = {ctor}(srcDir = \"./src\","
            f" prefix = cfgPrefix, {ctor_arg} = opts)"
        )
    else:
        ctor_call = (
            f"{inner}let pkg = {ctor}(srcDir = \"./src\","
            f" {ctor_arg} = opts)"
        )
    lines.append(ctor_call)
    # Slice artifacts
    for kind2, name in artifacts:
        if kind2 == "executable":
            lines.append(
                f"{inner}discard pkg.executable({nim_string_lit(name)})"
            )
        else:
            lines.append(
                f"{inner}discard pkg.library({nim_string_lit(name)})"
            )
    for name in files_arts:
        lines.append(
            f"{inner}discard pkg.files({nim_string_lit(name)})"
        )
    lines.append(f"{indent}  finally:")
    lines.append(f"{indent}    clearCurrentOwningPackageOverride()")
    return "\n".join(lines)


STDLIB_IMPORT_MARK = "import repro_dsl_stdlib/constructors"
TYPES_IMPORT_MARK = "import repro_dsl_stdlib/types/package_result"


def ensure_imports(text: str) -> str:
    """Ensure the constructor + result-type imports are present (added
    right after the first `import repro_project_dsl` line)."""
    if STDLIB_IMPORT_MARK in text and TYPES_IMPORT_MARK in text:
        return text
    lines = text.split("\n")
    insert_at = None
    for idx, line in enumerate(lines):
        if line.strip() == "import repro_project_dsl":
            insert_at = idx + 1
            break
    if insert_at is None:
        return text
    new_imports: List[str] = []
    if STDLIB_IMPORT_MARK not in text:
        new_imports.append(STDLIB_IMPORT_MARK)
    if TYPES_IMPORT_MARK not in text:
        new_imports.append(TYPES_IMPORT_MARK)
    if not new_imports:
        return text
    new_lines = lines[:insert_at] + new_imports + lines[insert_at:]
    return "\n".join(new_lines)


def transform_recipe(path: Path) -> Tuple[bool, str]:
    """Transform a single recipe. Returns (changed, message)."""
    text = path.read_text(encoding="utf-8")
    block = find_options_block(text)
    if block is None:
        return False, f"  skip: {path.parent.name} (no options block)"

    kind, start_idx, end_idx, flags = block
    pkg_name = parse_package_name(text)
    if pkg_name is None:
        return False, f"  ERROR: {path.parent.name} — package head not found"

    artifacts = parse_artifacts(text)
    files_arts = parse_files_artifacts(text)
    indent = find_options_block_indent(text, start_idx)
    if "  " not in indent:
        indent = "  "  # safety fallback

    lines = text.split("\n")
    # Replace options block with config: block
    config_block = build_replacement(kind, pkg_name, indent, flags,
                                     artifacts, files_arts)
    new_lines = lines[:start_idx] + config_block.split("\n") + lines[end_idx:]

    # Insert build: block before runtimeDeps:
    new_text = "\n".join(new_lines)
    rt_idx = find_runtime_deps_line(new_text)
    if rt_idx is None:
        # No runtimeDeps: — append at end of file (rare).
        build_block = build_block_text(kind, pkg_name, indent, flags,
                                       artifacts, files_arts)
        new_text = new_text.rstrip() + "\n\n" + build_block + "\n"
    else:
        new_lines2 = new_text.split("\n")
        # Insert a blank line + the build: block before the runtimeDeps:
        # head.
        build_block = build_block_text(kind, pkg_name, indent, flags,
                                       artifacts, files_arts)
        prefix_lines = new_lines2[:rt_idx]
        suffix_lines = new_lines2[rt_idx:]
        new_text = ("\n".join(prefix_lines) + "\n" + build_block + "\n\n"
                    + "\n".join(suffix_lines))

    # Ensure constructor imports are present.
    new_text = ensure_imports(new_text)
    # IMPORTANT: write with LF line endings (not platform default). The
    # reprobuild repo has ``core.autocrlf=false`` and the upstream
    # recipe files are LF-terminated; Python's default ``write_text``
    # on Windows would emit CRLF and the entire file would surface as
    # changed in ``git diff``.
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(new_text)
    n_artifacts = len(artifacts) + len(files_arts)
    return True, (
        f"  swept: {path.parent.name} (kind={kind}, "
        f"flags={len(flags)}, artifacts={n_artifacts})"
    )


def main() -> int:
    root = Path(".") / RECIPE_ROOT
    if not root.is_dir():
        print(f"ERROR: {root} not found; cwd={Path.cwd()}",
              file=sys.stderr)
        return 1
    recipes = sorted(p for p in root.glob("*/repro.nim"))
    print(f"M9.R.5b sweep: {len(recipes)} recipes")
    n_swept = 0
    n_skipped = 0
    n_errors = 0
    for path in recipes:
        try:
            changed, msg = transform_recipe(path)
            print(msg)
            if changed:
                n_swept += 1
            else:
                if "ERROR" in msg:
                    n_errors += 1
                else:
                    n_skipped += 1
        except Exception as e:  # pylint: disable=broad-except
            print(f"  ERROR: {path.parent.name} — {e}")
            n_errors += 1
    print()
    print(f"Summary: swept={n_swept}, skipped={n_skipped}, errors={n_errors}")
    return 0 if n_errors == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
