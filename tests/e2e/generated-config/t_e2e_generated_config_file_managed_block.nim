## M59 gate: `e2e_generated_config_file_managed_block`.
##
## Normative description:
##
##   Writes a managed block into a fixture .bashrc; second apply with
##   no changes is a no-op; user edits around the block are preserved;
##   removing the block deletes only the sentinels and managed content;
##   updating the block leaves the rest of the file intact.

import std/[os, strutils, unittest]

import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/generated_config
import repro_local_store

proc setupScope(tmpRoot: string): HomeScope =
  putEnv("REPRO_HOME_PROFILE_TARGET", tmpRoot)
  result = resolveHomeScope()

suite "M59 managed-block gate":

  test "writes; second apply is cache hit; surrounding edits preserved":
    let tmpRoot = getTempDir() / "repro-m59-mb-1"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()
    let bashrc = scope.home / ".bashrc"

    # Seed the fixture rc file with user-owned bytes around where the
    # managed block will go.
    writeFile(bashrc, "# user comment\nalias ll='ls -la'\n# end user\n")

    var editor: Configurable[string]
    let ctx = evalConfig:
      let e = configurable "vi"
      e.override "nvim"
      editor = e
    let editorV = ctx.read(editor)
    let blockBody = "export EDITOR='" & editorV & "'\nexport PAGER=less"
    let r1 = managedBlockAction(state, store, scope, "~/.bashrc",
      "repro-home-environment", blockBody,
      @[ResolvedInput(name: "editor", value: cvString(editorV))])
    check r1.outcome == maInserted
    check r1.rewroteHostFile
    let written = readFile(bashrc)
    check "alias ll=" in written
    check "# user comment" in written
    check "export EDITOR='nvim'" in written
    check ">>> repro:home:repro-home-environment >>>" in written
    check "<<< repro:home:repro-home-environment <<<" in written

    # Second apply with identical inputs -> cache hit, no rewrite.
    let r2 = managedBlockAction(state, store, scope, "~/.bashrc",
      "repro-home-environment", blockBody,
      @[ResolvedInput(name: "editor", value: cvString(editorV))])
    check r2.outcome == maCacheHit
    check not r2.rewroteHostFile
    check readFile(bashrc) == written

    # User edits around the block (outside sentinels) MUST survive.
    let userEdited = written.replace("# user comment",
      "# user comment\n# new user line")
    writeFile(bashrc, userEdited)
    let r3 = managedBlockAction(state, store, scope, "~/.bashrc",
      "repro-home-environment", blockBody,
      @[ResolvedInput(name: "editor", value: cvString(editorV))])
    check r3.outcome == maCacheHit
    # The user's surrounding edits are still on disk.
    let onDisk = readFile(bashrc)
    check "# new user line" in onDisk
    check "export EDITOR='nvim'" in onDisk

  test "updating the block leaves the rest of the file intact":
    let tmpRoot = getTempDir() / "repro-m59-mb-2"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()
    let bashrc = scope.home / ".bashrc"
    writeFile(bashrc, "alias ll='ls -la'\n# preserve-me\n")

    discard managedBlockAction(state, store, scope, "~/.bashrc", "envblock",
      "export EDITOR='vi'", @[])

    discard managedBlockAction(state, store, scope, "~/.bashrc", "envblock",
      "export EDITOR='nvim'", @[])
    let after = readFile(bashrc)
    check "export EDITOR='nvim'" in after
    check "export EDITOR='vi'" notin after
    check "alias ll=" in after
    check "# preserve-me" in after

  test "removing the block deletes only sentinels + managed content":
    let tmpRoot = getTempDir() / "repro-m59-mb-3"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()
    let bashrc = scope.home / ".bashrc"
    writeFile(bashrc, "alias ll='ls -la'\n# tail comment\n")

    discard managedBlockAction(state, store, scope, "~/.bashrc",
      "envblock", "export EDITOR='vi'", @[])
    let withBlock = readFile(bashrc)
    check ">>> repro:home:envblock >>>" in withBlock

    let removed = removeManagedBlockAction(state, scope,
      "~/.bashrc", "envblock")
    check removed.outcome == maRemoved
    let afterRemoval = readFile(bashrc)
    check ">>> repro:home:envblock >>>" notin afterRemoval
    check "<<< repro:home:envblock <<<" notin afterRemoval
    check "export EDITOR='vi'" notin afterRemoval
    check "alias ll=" in afterRemoval
    check "# tail comment" in afterRemoval

  test "shellExports: block macro lowers through managed block":
    let tmpRoot = getTempDir() / "repro-m59-mb-4"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()
    let bashrc = scope.home / ".bashrc"
    writeFile(bashrc, "# rc head\n")

    var editorH: Configurable[string]
    var pagerH: Configurable[string]
    let ctx = evalConfig:
      let e = configurable "vi"
      let p = configurable "less"
      e.override "nvim"
      p.override "moar"
      editorH = e; pagerH = p

    let rendered = shellExports(ctx):
      EDITOR = editorH
      PAGER = pagerH

    let result = managedBlockAction(state, store, scope,
      "~/.bashrc", "repro-home-env", rendered)
    check result.outcome == maInserted
    let body = readFile(bashrc)
    check "export EDITOR='nvim'" in body
    check "export PAGER='moar'" in body
    check "# rc head" in body
