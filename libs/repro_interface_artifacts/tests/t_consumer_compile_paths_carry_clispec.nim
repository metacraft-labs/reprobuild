## A foreign project's DSL compile finds `clispec`.
##
## WHY. `repro_project_dsl` builds every `cli:` block on the clispec library
## (`import clispec/[model, dsl]`), so every compile of a project's
## `repro.nim` reaches it. Such a compile runs outside reprobuild's tree,
## where `config.nims` is not evaluated, and `consumerCompilePathFlags`
## replays its package paths; a package missing from that replay fails the
## compile with `cannot open file: clispec/model` as soon as the environment
## is allowlisted and no `../nim-cli-spec` sibling exists. This is the same
## shape as `t_consumer_compile_paths_carry_the_shm_packages.nim`.
##
## HOW. Both arms drive the real `consumerCompilePathFlags`. The first points
## `CLI_SPEC_SRC` at a real marker tree and expects exactly that directory.
## The second removes the variable and uses a work dir with no sibling, and
## expects the source root captured when this library was built.
##
## Falsifiability: without the `CLI_SPEC_SRC` entry in
## `consumerCompilePathFlags` neither arm finds a `--path` holding
## `clispec.nim`.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts

proc pathsWithMarker(flags: seq[string]; marker: string): seq[string] =
  for flag in flags:
    if flag.startsWith("--path:"):
      let dir = flag["--path:".len .. ^1]
      if fileExists(dir / marker):
        result.add(dir)

const builtCliSpec = static(getEnv("CLI_SPEC_SRC"))

suite "consumer compile paths carry clispec":
  test "the environment variable is honoured":
    let root = createTempDir("cli-spec-paths-", "")
    defer: removeDir(root)
    let cliSpec = root / "clispec"
    createDir(cliSpec)
    writeFile(cliSpec / "clispec.nim", "")
    let saved = getEnv("CLI_SPEC_SRC")
    putEnv("CLI_SPEC_SRC", cliSpec)
    defer: putEnv("CLI_SPEC_SRC", saved)
    let flags = consumerCompilePathFlags(root / "work")
    check cliSpec in pathsWithMarker(flags, "clispec.nim")

  test "a scrubbed environment beside no sibling falls back to the build pin":
    # Not a skip: reprobuild's build always exports CLI_SPEC_SRC
    # (scripts/source_paths.sh refuses to build without it), so an empty
    # build pin here means this library was built wrong.
    check builtCliSpec.len > 0
    let root = createTempDir("cli-spec-paths-", "")
    defer: removeDir(root)
    let saved = getEnv("CLI_SPEC_SRC")
    delEnv("CLI_SPEC_SRC")
    defer: putEnv("CLI_SPEC_SRC", saved)
    let flags = consumerCompilePathFlags(root / "work")
    check pathsWithMarker(flags, "clispec.nim").len > 0
