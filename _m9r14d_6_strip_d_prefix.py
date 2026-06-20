#!/usr/bin/env python3
"""M9.R.14d.6 — strip the literal ``-D`` prefix from meson_package
option strings in source recipes.

The ``meson.setup`` typed-tool's ``options`` flag carries
``alias = "-D"`` + ``format = concat`` (see
``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/meson.nim``),
so the wrapper prepends ``-D`` to each element of the seq at emit
time. Recipes that pre-prefix their options with ``-D`` end up
invoking meson with ``-D-Dfoo=bar``, which meson rejects with
``Unknown option: "-Dfoo"``.

This transform finds every line inside a ``let opts = @[...]``
block that reads ``"-D<X>=...",`` and rewrites it to ``"<X>=..."``.
It is conservative: only touches lines that match the exact
``-D<word>=`` shape and leaves everything else (including
``--buildtype=...``, ``--cross-file=...``, comments) alone.
"""

import re
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent
RECIPE_GLOB = REPO_ROOT / "recipes" / "packages" / "source"

# Captures: leading whitespace + `"-D` + the rest of the option
# (e.g. `foo=bar"`). Used in re.sub to rebuild the line without the
# `-D` prefix.
D_PREFIX_RE = re.compile(r'^(\s*)"-D([A-Za-z0-9_-][^"]*?)"(\s*,?\s*(?:#.*)?)$',
                         re.MULTILINE)


def transform_one(path: pathlib.Path) -> int:
    """Return the number of replacements made."""
    raw = path.read_bytes()
    text = raw.decode("utf-8")

    new_text, n = D_PREFIX_RE.subn(
        lambda m: f'{m.group(1)}"{m.group(2)}"{m.group(3)}',
        text,
    )

    if n == 0:
        return 0

    if new_text != text:
        path.write_bytes(new_text.encode("utf-8"))
    return n


def main() -> int:
    total = 0
    for repro_nim in sorted(RECIPE_GLOB.glob("*/repro.nim")):
        content = repro_nim.read_bytes().decode("utf-8")
        if '"-D' not in content:
            continue
        n = transform_one(repro_nim)
        if n > 0:
            rel = repro_nim.relative_to(REPO_ROOT)
            print(f"  fixed {n} option(s): {rel}")
            total += n
    print(f"\nTotal: {total} option strings stripped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
