#!/usr/bin/env python3
"""Check the optional HCR environment using the drivers' actual discovery rules."""

import os
from pathlib import Path
import sys

if sys.platform != "win32":
    raise SystemExit("The Windows HCR environment must be checked on Windows")

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests" / "windows"))
from hx_w0_windows_publication_decision_is_recorded_and_measured import (  # noqa: E402
    required_tool,
    visual_studio_environment,
)
from hx_w6_windbg_resolves_source_lines_inside_a_patched_windows_function import (  # noqa: E402
    find_cdb,
)


def main() -> None:
    env = visual_studio_environment()
    for name in ("cl", "link", "dumpbin", "ml64", "nim", "gcc", "clang", "clang-cl"):
        resolved = Path(required_tool(name + ".exe", env))
        if name in ("clang", "clang-cl"):
            expected = Path(os.environ["REPRO_WINDOWS_LLVM_DIR"]) / "bin" / (name + ".exe")
            if not resolved.samefile(expected):
                raise AssertionError(f"{name} resolves to {resolved}, not the declared LLVM: {expected}")
        print(f"{name}: {resolved}")
    print(f"cdb: {find_cdb(env)}")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, OSError) as error:
        raise SystemExit(f"Windows HCR prerequisite check failed: {error}") from error
