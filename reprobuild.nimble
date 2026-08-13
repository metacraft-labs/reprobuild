# This file is also the repository's package-root anchor: `canonicalImportAux`
# walks up from each compiled source looking for the nearest `.nimble`, and
# that root is what keeps the location literal inside every `check` / `assert`
# — and therefore every test's `--list-json` `bodyHash` — both machine-
# independent and directory-bearing. Losing it degrades those locations to
# bare basenames silently. See the matching note beside `switch("path", ".")`
# in `config.nims`, and `tests/unit/test_package_root_anchor.py`.

version = "0.1.3"
author = "Metacraft Labs"
description = "Reprobuild build system"
license = "MIT"
requires "nim >= 2.2.0"

task build, "Build all M0 application entry points":
  exec "just build"

task test, "Run the M0 test suite":
  exec "just test"
