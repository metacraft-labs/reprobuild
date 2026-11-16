## Environment tables built from the inherited environment keep ONE search
## path under Windows name semantics.
##
## Windows variable names are case-insensitive and the inherited search path
## is spelled ``Path``
## (https://learn.microsoft.com/en-us/windows/win32/procthread/environment-variables).
## Copying it into a case-sensitive table and then setting ``PATH`` gives the
## child two entries for one variable, and which one it reads depends on the
## order of its environment block. Issue
## ``reprobuild-pm/issues/2026-11-15-windows-shared-pool-retention-discovery-hands-sh-both-path-and-path.md``
## found the defect in three places; each is pinned here:
##
##   - ``retentionDiscoveryEnv`` / ``scrubbedGitRepositoryEnvFrom`` (the
##     shared-pool ``--discover`` pass, Shared-Clone-Pool-Integrity §3.2);
##   - ``cmdEnvTable`` (``runShell`` / ``runShellSplit`` in
##     ``repro_test_support``);
##   - ``buildRollbackVars`` (the dev-env rollback manifest), where a ``PATH``
##     op looked up in a case-sensitive snapshot found no ``Path`` and
##     recorded the search path as unset, so deactivation deleted it.
##
## Two kinds of case. The ``windows_semantics_*`` cases pass an explicit
## ``caseInsensitive = true`` and a synthetic environment containing ``Path``,
## so they exercise the Windows behaviour on every host; each one also states
## the case-sensitive result, which is the defect, so the mechanism stays
## visible. The ``host_*`` cases start a real child with the table the code
## under test builds, on this host's default semantics, and count the search
## path entries the child actually received. On Windows those are the
## end-to-end check; on POSIX the inherited name is ``PATH`` already and they
## check that the change kept the prepend and the override working.
##
## The ``host_pool_retention_discovery_*`` cases drive the product path
## itself, ``poolRetentionReady``, on a real pool: with the environment as
## inherited, and with a ``git`` that fails put first on the inherited search
## path, where the discovery pass must still run the pool's Git
## (Shared-Clone-Pool-Integrity §3.2). The second case skips, with the
## measured reason, on a host whose first ``sh`` is Git for Windows'
## launcher: it rewrites the search path itself, so the stub cannot be
## observed through it.
## It lives here rather than in ``t_spi_pool_retains_registered_leaf_objects``
## because that file's fixture runs ``VAR=value git …`` command lines, which
## do not start on Windows.
##
## One stand-in: the failing ``git`` is a two-line ``sh`` script that records
## that it ran. It stands for "some other Git first on the inherited search
## path", which a test host cannot be expected to have installed; the Git the
## pool uses and the discovery hook are real. Otherwise no mocks: every table
## is the one the production proc returns, and the child processes are real
## (``cmd.exe /d /c set`` on Windows, ``env`` on POSIX).

import std/[os, osproc, strtabs, strutils, tables, tempfiles, unittest]

import repro_core/process_env
import git_tool
import shared_clones
import repro_test_support
import repro_test_support/reasoned_skip
import repro_cli_support/dev_env_shell_export
import repro_cli_support/dev_env_rollback_manifest

proc searchPathKeys(env: StringTableRef): seq[string] =
  ## Every key of ``env`` that names the search path in either spelling.
  for key, _ in env:
    if cmpIgnoreCase(key, "PATH") == 0:
      result.add(key)

proc childSearchPathLines(env: StringTableRef): seq[string] =
  ## The search-path lines of the environment a real child started with
  ## ``env`` reports, compared with the host's name semantics.
  let (exe, args) =
    when defined(windows):
      (getEnv("ComSpec", "cmd.exe"), @["/d", "/c", "set"])
    else:
      # Not followed through symlinks: a multi-call coreutils dispatches on
      # the name it was run as.
      # `-0`: one NUL-terminated record per variable, so a value that spans
      # lines (a dev shell's exported functions) is not read as more entries.
      (findExe("env", followSymlinks = false), @["-0"])
  doAssert exe.len > 0, "no program to print the environment with"
  let res = runProgramSplit(exe, args, env = env, timeoutMs = 60_000)
  doAssert res.code == 0, res.stdout & res.stderr
  let records =
    when defined(windows): res.stdout.splitLines()
    else: res.stdout.split('\0')
  for line in records:
    let eq = line.find('=')
    if eq > 0 and sameEnvName(line[0 ..< eq], "PATH"):
      result.add(line)

proc runChild(exe: string; args: openArray[string]): int =
  let p = startProcess(exe, args = args, options = {poParentStreams})
  result = p.waitForExit()
  p.close()

type PoolFixture = object
  root, pool, gitBin, pathName, savedPath, savedGlobal: string
  hadGlobal: bool

proc setUpPool(prefix: string): PoolFixture =
  ## A real pool with the retention hook and one registered borrower whose
  ## alternates name the pool, as ``wireAlternates`` leaves it, under a
  ## private empty ``GIT_CONFIG_GLOBAL``. Git >= 2.42 (gc.recentObjectsHook)
  ## is a prerequisite of every host this suite runs on; its absence fails
  ## the case rather than skipping it.
  result.gitBin = findExe("git")
  doAssert result.gitBin.len > 0, "git is not on PATH"
  doAssert gitSupportsRetentionHook(result.gitBin),
    "git older than 2.42: " & result.gitBin
  result.root = createTempDir(prefix, "")
  result.hadGlobal = existsEnv("GIT_CONFIG_GLOBAL")
  result.savedGlobal = getEnv("GIT_CONFIG_GLOBAL")
  # The search path under the spelling this host's environment uses.
  result.pathName = "PATH"
  for name, _ in envPairs():
    if cmpIgnoreCase(name, "PATH") == 0:
      result.pathName = name
  result.savedPath = getEnv(result.pathName)
  writeFile(result.root / "gitconfig", "")
  putEnv("GIT_CONFIG_GLOBAL", result.root / "gitconfig")
  result.pool = result.root / "cache" / "pool.git"
  let leaf = result.root / "ws" / "leaf"
  createDir(result.pool.parentDir)
  createDir(leaf.parentDir)
  doAssert runChild(result.gitBin, ["init", "-q", "--bare", result.pool]) == 0
  doAssert runChild(result.gitBin, ["init", "-q", leaf]) == 0
  writeFile(leaf / ".git" / "objects" / "info" / "alternates",
    (result.pool / "objects").replace('\\', '/') & "\n")
  doAssert ensureRetentionHook(result.pool)
  createDir(borrowersPath(result.pool).parentDir)
  writeFile(borrowersPath(result.pool), leaf & "\n")

proc tearDownPool(f: PoolFixture) =
  putEnv(f.pathName, f.savedPath)
  if f.hadGlobal: putEnv("GIT_CONFIG_GLOBAL", f.savedGlobal)
  else: delEnv("GIT_CONFIG_GLOBAL")
  removeDir(f.root)

suite "env tables keep one search path under Windows name semantics":

  test "windows_semantics_prepend_extends_the_inherited_Path":
    let inherited = [("Path", r"C:\Windows\System32"), ("HOME", "h")]
    let env = envTableFrom(inherited, caseInsensitive = true)
    env.prependPathEntry(r"C:\Git\cmd")
    check env.searchPathKeys == @["Path"]
    check env["PATH"] == r"C:\Git\cmd" & $PathSep & r"C:\Windows\System32"
    check env["Path"] == env["PATH"]
    # A block that already carries both spellings: the earlier entry wins,
    # as a lookup in the block itself does, so the table agrees with what
    # `getEnv` reports in the parent.
    let both = envTableFrom([("Path", "first"), ("PATH", "second")],
      caseInsensitive = true)
    check both.searchPathKeys == @["Path"]
    check both["PATH"] == "first"
    # The defect: a case-sensitive copy keeps the inherited entry beside the
    # new one, and the prepend no longer sees the inherited value.
    let sensitive = envTableFrom(inherited, caseInsensitive = false)
    sensitive.prependPathEntry(r"C:\Git\cmd")
    check sensitive.searchPathKeys.len == 2
    check sensitive["PATH"] == r"C:\Git\cmd"

  test "windows_semantics_retention_discovery_env_has_one_path":
    let inherited = [("Path", r"C:\inherited"), ("GIT_DIR", r"C:\pool"),
      ("GIT_WORK_TREE", r"C:\w"), ("SystemRoot", r"C:\Windows")]
    let base = scrubbedGitRepositoryEnvFrom(inherited,
      caseInsensitive = true)
    let gitBin = r"C:\Program Files\Git\cmd\git.exe"
    let env = retentionDiscoveryEnv(gitBin, base)
    check env.searchPathKeys.len == 1
    check env["PATH"] == gitBin.parentDir & $PathSep & r"C:\inherited"
    # Git's repository-local bindings are still scrubbed, other variables
    # still kept.
    check not env.hasKey("GIT_DIR")
    check not env.hasKey("GIT_WORK_TREE")
    check env["SystemRoot"] == r"C:\Windows"
    # The defect, as poolRetentionReady built it before: a case-sensitive
    # scrub plus PATH set by name.
    let old = scrubbedGitRepositoryEnvFrom(inherited,
      caseInsensitive = false)
    old["PATH"] = gitBin.parentDir & $PathSep & r"C:\inherited"
    check old.searchPathKeys.len == 2

  test "windows_semantics_run_shell_override_replaces_the_inherited_Path":
    let inherited = [("Path", r"C:\inherited"), ("TEMP", r"C:\t")]
    let cmd = shellCommand(["prog"], [("PATH", r"C:\spy;C:\inherited")])
    let env = cmdEnvTable(cmd, inherited, caseInsensitive = true)
    check env.searchPathKeys.len == 1
    check env["PATH"] == r"C:\spy;C:\inherited"
    check env["TEMP"] == r"C:\t"
    check cmdEnvTable(cmd, inherited,
      caseInsensitive = false).searchPathKeys.len == 2

  test "windows_semantics_rollback_restores_the_inherited_Path":
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opPrependPath, pathName: "PATH",
      segment: r"C:\proj\bin", separator: ";"))
    plan.add(ExportOp(kind: opSet, name: "FIXTURE_MODE", value: "dev"))
    var preEnv = initPreActivationEnv()
    preEnv.table["Path"] = r"C:\Windows\System32"
    let vars = buildRollbackVars(plan, preEnv, caseInsensitive = true)
    check vars[0].name == "PATH"
    check vars[0].wasSet
    check vars[0].previous == r"C:\Windows\System32"
    check not vars[1].wasSet
    # Deactivation then restores the search path instead of deleting it.
    let manifest = buildRollbackManifest(plan, preEnv, "deadbeef",
      formatExportPlan(plan, skPwsh), skPwsh, caseInsensitive = true)
    let deact = formatDeactivate(manifest, skPwsh)
    checkpoint(deact)
    check r"C:\Windows\System32" in deact
    # The defect: a case-sensitive lookup records PATH as unset.
    let old = buildRollbackVars(plan, preEnv, caseInsensitive = false)
    check not old[0].wasSet
    check old[0].previous == ""

  test "windows_semantics_rollback_prefers_the_exact_spelling":
    var plan: ExportPlan = @[]
    plan.add(ExportOp(kind: opPrependPath, pathName: "PATH",
      segment: "/p", separator: ":"))
    var preEnv = initPreActivationEnv()
    preEnv.table["Path"] = "mixed"
    preEnv.table["PATH"] = "exact"
    preEnv.table["path"] = "lower"
    check buildRollbackVars(plan, preEnv,
      caseInsensitive = true)[0].previous == "exact"
    preEnv.table.del("PATH")
    # Without the exact spelling the choice does not depend on iteration
    # order: the smallest name ("Path" < "path") wins.
    check buildRollbackVars(plan, preEnv,
      caseInsensitive = true)[0].previous == "mixed"

  test "posix_semantics_keep_distinct_names":
    # POSIX names are case-sensitive: `Path` and `PATH` are two variables and
    # must both survive.
    let env = envTableFrom([("Path", "a"), ("PATH", "b")],
      caseInsensitive = false)
    check env.searchPathKeys.len == 2
    check not sameEnvName("Path", "PATH", caseInsensitive = false)
    check sameEnvName("Path", "PATH", caseInsensitive = true)

  test "host_retention_discovery_child_sees_one_search_path_led_by_git":
    # Git is a prerequisite of every host this suite runs on (the shared
    # pool is a git feature); its absence is a broken host, not a skip.
    let gitBin = findExe("git")
    require gitBin.len > 0
    let lines = childSearchPathLines(retentionDiscoveryEnv(gitBin))
    checkpoint(lines.join("\n"))
    check lines.len == 1
    if lines.len == 1:
      let value = lines[0][lines[0].find('=') + 1 .. ^1]
      check value.startsWith(gitBin.parentDir & $PathSep)

  test "host_run_shell_path_override_reaches_the_child_alone":
    let marker = getTempDir() / "repro-env-tables-spy-dir"
    let wanted = marker & $PathSep & getEnv("PATH")
    let env = cmdEnvTable(shellCommand(["prog"], [("PATH", wanted)]))
    let lines = childSearchPathLines(env)
    checkpoint(lines.join("\n"))
    check lines.len == 1
    if lines.len == 1:
      check lines[0][lines[0].find('=') + 1 .. ^1] == wanted

  test "host_pool_retention_discovery_passes_on_the_inherited_environment":
    # The product path itself, unmodified environment. On Windows the pass
    # got both `Path` and `PATH` and failed (measured on eli-pc), so the pool
    # kept `gc.pruneExpire=never` for good.
    let f = setUpPool("repro-env-tables-pool-")
    defer: tearDownPool(f)
    check poolRetentionReady(f.gitBin, f.pool)

  test "host_pool_retention_discovery_runs_the_pools_git_first":
    # A `git` that fails, put first on this process's inherited search path,
    # must not be the one the `--discover` pass runs (§3.2).
    let f = setUpPool("repro-env-tables-pool-stub-")
    defer: tearDownPool(f)
    let stubDir = f.root / "stub-bin"
    let marker = f.root / "stub-ran"
    createDir(stubDir)
    writeFile(stubDir / "git", "#!/bin/sh\n" &
      "echo ran >> " & quoteShellPosix(marker.replace('\\', '/')) & "\n" &
      "exit 1\n")
    setFilePermissions(stubDir / "git", {fpUserRead, fpUserWrite,
      fpUserExec})
    putEnv(f.pathName, stubDir & $PathSep & f.savedPath)
    # Positive control: the `sh` the pass is started through finds the stub
    # as `git` on the inherited search path.
    let sh = findExe("sh")
    doAssert sh.len > 0, "sh is not on PATH"
    discard runChild(sh, ["-c", "git version"])
    if not fileExists(marker):
      # Measured on eli-pc: the first `sh` is Git for Windows' launcher
      # (`bin\sh.exe` or a Scoop shim of it), which puts its own
      # `/ucrt64/bin:/usr/bin` in front of the search path it is given, so
      # no `git` placed on that search path can be observed through it.
      skip("the first sh on this host's PATH (" & sh & ") does not look " &
        "commands up on the search path it is given first, so a git " &
        "placed there cannot be observed; product defect reprobuild-pm " &
        "issues/2026-11-16-windows-shared-pool-retention-discovery-" &
        "depends-on-which-sh-is-first-on-path.md, Windows leg tracked " &
        "for eli-pc in the GNM milestone (GM1w)")
    else:
      removeFile(marker)
      check poolRetentionReady(f.gitBin, f.pool)
      check not fileExists(marker)
