## DIRECTORY TRUST MUST FOLLOW THE RECIPE, NOT JUST THE PATH.
##
## `issues/2026-11-12-directory-trust-is-keyed-on-the-path-alone-and-gates-
## only-the-hook.md` (reprobuild-pm): an allow record was keyed on the project
## root path alone, so a later `git pull` that rewrote `repro.nim` (or a
## module it imports) ran attacker-controlled recipe code on the next `cd`
## with no new consent. direnv blocks a changed `.envrc`; so must we.
##
## Attack-shaped: each case allows a directory, then changes the recipe the
## way a hostile pull would, and asserts the directory is no longer trusted.
## No mocks: real files under a temp project root and a temp XDG config dir.

import std/[os, tempfiles, unittest]

import repro_dev_env_engine/directory_trust

suite "dev-env directory trust binds the recipe closure":
  let root = createTempDir("t_dev_env_directory_trust", "")
  putEnv("XDG_CONFIG_HOME", root / "xdg")
  let project = root / "proj"

  proc fresh() =
    removeDir(project)
    removeDir(root / "xdg")
    createDir(project / ".repro")
    createDir(project / "recipes")
    writeFile(project / "repro.nim",
      "import recipes/tools, \"helper\"\nimport std/os\n")
    writeFile(project / "recipes" / "tools.nim", "# tools v1\n")
    writeFile(project / "helper.nim", "# helper v1\n")

  test "an unallowed directory is untrusted":
    fresh()
    check directoryTrustState(project) == dtUntrusted

  test "an allowed, unchanged directory is trusted":
    fresh()
    writeAllowRecord(project)
    check directoryTrustState(project) == dtTrusted

  test "editing the project file revokes trust":
    fresh()
    writeAllowRecord(project)
    writeFile(project / "repro.nim", readFile(project / "repro.nim") &
      "discard staticExec(\"touch pwned\")\n")
    check directoryTrustState(project) == dtRecipeChanged

  test "editing an imported local module revokes trust":
    fresh()
    writeAllowRecord(project)
    writeFile(project / "recipes" / "tools.nim", "# tools v2 hostile\n")
    check directoryTrustState(project) == dtRecipeChanged

  test "editing a quoted-import module revokes trust":
    fresh()
    writeAllowRecord(project)
    writeFile(project / "helper.nim", "# helper v2 hostile\n")
    check directoryTrustState(project) == dtRecipeChanged

  test "editing the dev-env lock slice revokes trust":
    fresh()
    writeAllowRecord(project)
    writeFile(project / ".repro" / "dev-env.lock", "swapped\n")
    check directoryTrustState(project) == dtRecipeChanged

  test "re-allowing after a change restores trust":
    fresh()
    writeAllowRecord(project)
    writeFile(project / "helper.nim", "# helper v2\n")
    writeAllowRecord(project)
    check directoryTrustState(project) == dtTrusted

  test "a legacy path-only record trusts nothing":
    fresh()
    let rec = allowRecordPath(project)
    createDir(parentDir(rec))
    writeFile(rec, project)
    check directoryTrustState(project) == dtUntrusted

  test "a module hidden behind a multi-line import revokes trust":
    fresh()
    writeFile(project / "hidden.nim", "# hidden v1\n")
    writeFile(project / "repro.nim",
      "import\n  std/os,\n  hidden\nimport recipes/[tools,\n  helper]\n")
    writeAllowRecord(project)
    writeFile(project / "hidden.nim", "# hidden v2 hostile\n")
    check directoryTrustState(project) == dtRecipeChanged

  test "a transitive import revokes trust":
    fresh()
    writeFile(project / "recipes" / "tools.nim", "import ../helper\n")
    writeAllowRecord(project)
    writeFile(project / "helper.nim", "# helper hostile\n")
    check directoryTrustState(project) == dtRecipeChanged

  test "editing config.nims revokes trust":
    fresh()
    writeAllowRecord(project)
    writeFile(project / "config.nims", "exec \"touch pwned\"\n")
    check directoryTrustState(project) == dtRecipeChanged

  test "an unrelated file does not revoke trust":
    fresh()
    writeAllowRecord(project)
    writeFile(project / "README.md", "docs\n")
    check directoryTrustState(project) == dtTrusted
  removeDir(root)
