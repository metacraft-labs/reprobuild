"""Bundle the build environment's Python for the release's Nix helper.

The POSIX relocator subsequently copies and rewrites the native library
closure. Extension modules live in the same flat lib directory as that closure
so its existing loader paths apply to Python extensions as well.
"""

from pathlib import Path
import shutil
import sys
import sysconfig


def stage(package: Path) -> None:
    helper = package / "bin/reprobuild-nix-daemon"
    if not helper.is_file():
        raise SystemExit(f"Missing release Nix helper: {helper}")
    source = helper.read_bytes()
    if not source.startswith(b"#!") or b"import argparse" not in source:
        raise SystemExit(f"Expected the Python Nix helper before relocation: {helper}")

    library = package / "lib"
    stdlib_source = Path(sysconfig.get_path("stdlib"))
    stdlib = library / stdlib_source.name
    shutil.copytree(
        stdlib_source,
        stdlib,
        ignore=shutil.ignore_patterns(
            "__pycache__", "site-packages", "lib-dynload", "test", "tests",
            "config-*", "idlelib", "ensurepip",
        ),
    )
    extensions = Path(sysconfig.get_config_var("DESTSHARED"))
    for extension in extensions.glob("*.so"):
        target = library / extension.name
        if target.exists():
            raise SystemExit(f"Conflicting Python extension in release: {target}")
        shutil.copy2(extension, target)
    shutil.copy2(Path(sys.executable).resolve(), package / "bin/repro-python")

    script = package / "share/repro/nix-daemon.py"
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_bytes(source.split(b"\n", 1)[1])
    license_source = stdlib_source / "LICENSE.txt"
    license_dir = package / "share/licenses/python"
    license_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(license_source, license_dir / "LICENSE.txt")
    helper.chmod(0o755)
    helper.write_text('''#!/bin/sh
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PYTHONHOME="$here/.."
export PYTHONPATH="$here/../lib"
export PYTHONNOUSERSITE=1
exec "$here/repro-python" -P -S "$here/../share/repro/nix-daemon.py" "$@"
''')


if __name__ == "__main__":
    stage(Path(sys.argv[1]))
