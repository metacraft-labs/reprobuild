#!/usr/bin/env python3
"""Mark Nix wrapper defaults as private bootstrap additions before dispatch.

makeWrapper's --set-default assignments are kept verbatim. A shell-side
presence check records only defaults the wrapper actually adds, using the same
hex transport as seedSourcePackageEnvironment. Introspection can then remove
unchanged additions without discarding explicit caller overrides.
"""
import pathlib
import re
import shlex
import sys


def mark_defaults(source: str) -> str:
    if "# repro bootstrap default provenance" in source:
        raise ValueError("wrapper defaults already marked")
    result = []
    count = 0
    for line in source.splitlines(keepends=True):
        match = re.fullmatch(r"export ([A-Za-z_][A-Za-z_0-9]*)=\$\{\1-(.*)\}\n?", line)
        if match:
            name, expression = match.groups()
            # Nix's generated default is a shell-quoted literal, not code.
            values = shlex.split(expression)
            if len(values) != 1 or not expression.startswith("'"):
                raise ValueError(f"unsupported makeWrapper default for {name}")
            encoded = values[0].encode().hex()
            result.append("# repro bootstrap default provenance\n")
            result.append(f'if [ "${{{name}+x}}" != x ]; then\n')
            result.append('  export REPRO_BOOTSTRAP_SOURCE_ENV="${REPRO_BOOTSTRAP_SOURCE_ENV-}\n'
                          + name + '=' + encoded + '"\nfi\n')
            count += 1
        result.append(line)
    if count == 0:
        raise ValueError("no makeWrapper --set-default assignments found")
    return "".join(result)


if __name__ == "__main__":
    for name in sys.argv[1:]:
        path = pathlib.Path(name)
        path.write_text(mark_defaults(path.read_text()))
