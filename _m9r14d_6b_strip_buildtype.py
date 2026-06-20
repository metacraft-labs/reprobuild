#!/usr/bin/env python3
"""M9.R.14d.6b — drop ``"--buildtype=release",`` lines from
meson_package option seqs.

The ``meson_package`` constructor already passes
``buildtype = "release"`` as a parameter default; the
``--buildtype`` flag is handled by the typed tool's dedicated
``buildtype:`` flag, NOT the ``options`` seq. Recipes that include
``"--buildtype=release"`` in the opts seq invoke meson with
``-D--buildtype=release``, which is rejected.
"""

import re
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent
RECIPE_GLOB = REPO_ROOT / "recipes" / "packages" / "source"

BUILDTYPE_LINE = re.compile(
    r'^\s*"--buildtype=[^"]*",\s*\n', re.MULTILINE
)


def transform_one(path: pathlib.Path) -> int:
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    new_text, n = BUILDTYPE_LINE.subn("", text)
    if n > 0 and new_text != text:
        path.write_bytes(new_text.encode("utf-8"))
    return n


def main() -> int:
    total = 0
    for repro_nim in sorted(RECIPE_GLOB.glob("*/repro.nim")):
        content = repro_nim.read_bytes().decode("utf-8")
        if "--buildtype" not in content:
            continue
        n = transform_one(repro_nim)
        if n > 0:
            rel = repro_nim.relative_to(REPO_ROOT)
            print(f"  dropped {n} line(s): {rel}")
            total += n
    print(f"\nTotal: {total} lines dropped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
