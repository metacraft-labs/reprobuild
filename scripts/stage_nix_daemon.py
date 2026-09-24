"""Stage the Nix helper with the build environment's Python interpreter."""

import pathlib
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
interpreter = str(pathlib.Path(sys.executable).resolve())
if any(char.isspace() for char in interpreter):
    raise SystemExit("Cannot use a Python interpreter path containing whitespace in a shebang")
body = source.read_bytes().split(b"\n", 1)[1]
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(b"#!" + interpreter.encode() + b"\n" + body)
destination.chmod(0o755)
