## RA-6 — `repro workspace bootstrap` scaffolds host ergonomics files.
##
## `repro workspace bootstrap [<dir>]` writes the host files a workspace
## checkout expects onto an EMPTY host directory:
##
##   * `.envrc`               — direnv entry point
##   * `AGENTS.md`            — agent guidance pointing at the project index
##   * `workspace-projects.md` — generated project index
##
## The command is IDEMPOTENT: re-running it never clobbers an existing file —
## each is reported as `skipped` and left byte-for-byte untouched.
##
## Falsifiability:
##   * If bootstrap stopped writing any of the three files, the existence /
##     content assertions fail.
##   * If a re-run clobbered an existing file (or duplicated content), the
##     byte-equality assertion after the second run fails.
##
## Hermetic: operates entirely on a tempdir; no network, no git required.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const expectedFiles = [".envrc", "AGENTS.md", "workspace-projects.md"]

proc invokeBootstrap(reproBin, hostDir: string): CmdResult =
  runShell(shellCommand(@[reproBin, "workspace", "bootstrap", hostDir]))

suite "RA-6 — repro workspace bootstrap (scaffolds host files)":

  test "test_ra6_bootstrap_writes_expected_host_files":
    let scratch = createTempDir("repro-ra6-bootstrap-", "")
    defer: removeDir(scratch)
    let reproBin = reproBinary()
    let hostDir = scratch / "host"
    createDir(hostDir)

    let res = invokeBootstrap(reproBin, hostDir)
    if res.code != 0:
      checkpoint("output: " & res.output)
    check res.code == 0

    # Each expected file exists with sensible, non-empty content.
    for name in expectedFiles:
      let path = hostDir / name
      check fileExists(path)
      let content = readFile(path)
      check content.len > 0

    # Content spot-checks: the files reference the workspace conventions.
    check readFile(hostDir / ".envrc").contains("direnv")
    check readFile(hostDir / "AGENTS.md").contains("workspace-projects.md")
    check readFile(hostDir / "workspace-projects.md").contains("Workspace Projects")

    # The command reports each file it wrote.
    for name in expectedFiles:
      check res.output.contains("wrote " & name)

  test "test_ra6_bootstrap_is_idempotent_on_rerun":
    let scratch = createTempDir("repro-ra6-bootstrap-idem-", "")
    defer: removeDir(scratch)
    let reproBin = reproBinary()
    let hostDir = scratch / "host"
    createDir(hostDir)

    # First run writes the files.
    let first = invokeBootstrap(reproBin, hostDir)
    check first.code == 0

    # Capture the byte content after the first run.
    var before: array[3, string]
    for i, name in expectedFiles:
      before[i] = readFile(hostDir / name)

    # Re-run: must succeed, NOT clobber, NOT duplicate, and report skipped.
    let second = invokeBootstrap(reproBin, hostDir)
    if second.code != 0:
      checkpoint("rerun output: " & second.output)
    check second.code == 0
    for name in expectedFiles:
      check second.output.contains("skipped " & name)

    # Byte-identical after the re-run (no clobber, no duplication).
    for i, name in expectedFiles:
      check readFile(hostDir / name) == before[i]

  test "test_ra6_bootstrap_preserves_user_edited_file":
    # An existing, user-edited file must survive a bootstrap run untouched —
    # this is the core idempotency contract: bootstrap never overwrites.
    let scratch = createTempDir("repro-ra6-bootstrap-edit-", "")
    defer: removeDir(scratch)
    let reproBin = reproBinary()
    let hostDir = scratch / "host"
    createDir(hostDir)
    let sentinel = "# user-customized envrc — DO NOT TOUCH\n"
    writeFile(hostDir / ".envrc", sentinel)

    let res = invokeBootstrap(reproBin, hostDir)
    check res.code == 0
    # The user's .envrc is preserved verbatim; the other two are created.
    check readFile(hostDir / ".envrc") == sentinel
    check res.output.contains("skipped .envrc")
    check fileExists(hostDir / "AGENTS.md")
    check fileExists(hostDir / "workspace-projects.md")
