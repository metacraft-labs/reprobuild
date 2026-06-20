#!/usr/bin/env python3
"""M9.R.14d.2 — bulk-replace ``url: "file:///..."`` lines in source
recipes with the upstream URL recorded in the ``versions:`` block's
``sourceUrl`` field.

The transform:
    1. Reads each recipe with `file:///` in its fetch block.
    2. Extracts the FIRST ``sourceUrl = "..."`` from the versions:
       block (recipes pin a single version so there's exactly one).
    3. Replaces the ``url: "file:///..."`` line with
       ``url: "<sourceUrl>"``.
    4. Preserves the existing line-ending convention so we don't
       flip LF→CRLF on Windows.
    5. Does NOT touch sha256 or any other field.
"""

import sys
import re
import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parent
RECIPE_GLOB = REPO_ROOT / "recipes" / "packages" / "source"

URL_LINE = re.compile(r'^(\s*)url:\s*"file://[^"]*"\s*$', re.MULTILINE)
SOURCE_URL_LINE = re.compile(r'sourceUrl\s*=\s*"([^"]+)"')


def detect_eol(text: str) -> str:
    """Return the dominant line-ending sequence in `text`."""
    if "\r\n" in text:
        return "\r\n"
    return "\n"


def transform_one(path: pathlib.Path) -> tuple[bool, str]:
    """Return (modified, reason) tuple."""
    raw = path.read_bytes()
    text = raw.decode("utf-8")

    eol = detect_eol(text)

    # Find ALL sourceUrl entries (multi-version recipes have multiple).
    source_urls = SOURCE_URL_LINE.findall(text)
    if not source_urls:
        return False, "no sourceUrl found"
    # The FIRST sourceUrl is the active version (recipes pin one
    # version at a time). Multi-version recipes (e.g. binutils 2.42 +
    # 2.43 entries) keep their ordering with the active version first.
    upstream_url = source_urls[0]

    if not URL_LINE.search(text):
        return False, "no file:/// url found"

    new_text = URL_LINE.sub(
        lambda m: f'{m.group(1)}url: "{upstream_url}"',
        text,
        count=1,
    )

    if new_text == text:
        return False, "no change"

    # Preserve EOL.
    if eol == "\r\n":
        # text was already CRLF — re.sub preserved it.
        pass

    path.write_bytes(new_text.encode("utf-8"))
    return True, f"replaced with {upstream_url}"


def main() -> int:
    failures = []
    for repro_nim in sorted(RECIPE_GLOB.glob("*/repro.nim")):
        content = repro_nim.read_bytes().decode("utf-8")
        if "file:///" not in content:
            continue
        modified, reason = transform_one(repro_nim)
        rel = repro_nim.relative_to(REPO_ROOT)
        if modified:
            print(f"  fixed: {rel} ({reason})")
        else:
            print(f"  SKIP : {rel} ({reason})", file=sys.stderr)
            failures.append((rel, reason))
    if failures:
        print(
            f"\n{len(failures)} recipe(s) could not be transformed:",
            file=sys.stderr,
        )
        for rel, reason in failures:
            print(f"  {rel}: {reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
