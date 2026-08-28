## DS-1 compatibility contract (CLI/develop.md §"Composing the lock set") —
## **a public-only workspace must come out byte-identical.**
##
##   > A workspace with no routing config resolves to the built-in public
##   > default alone (Unified-Locking-And-Hooks.md §4.1 layer 1), so its lock
##   > set *is* the committed lock and `--all` selects exactly what it selects
##   > today.
##
## The lock-set composer is a strict superset of the pre-DS-1 single-backend
## read. That claim is only worth anything if it is *tested*, not asserted: a
## composer that folded a spurious extra backend, emitted an extra report line,
## or reordered the selection would still "work" while silently changing what
## every existing public-only consumer sees.
##
## So this test pins the WHOLE observable surface of a public-only run:
##
##   1. the combined stdout+stderr is EXACTLY the two per-node lines, in
##      name-sorted order, and nothing else — no backend inventory, no notice,
##      no warning;
##   2. the selected set is EXACTLY the committed lock's deps minus the root
##      ``.`` consumer, at the lock's exact revisions (checked through `--json`
##      on a second, untouched copy of the same fixture);
##   3. adding a ``.repro-workspace.toml`` that carries NO ``[locking]`` table
##      changes nothing — the built-in public default is still the only tier.
##
## Falsifiability: any extra emitted line breaks (1) by exact string equality;
## any extra or missing node breaks (2); a bootstrap config that accidentally
## activated a routed read breaks (3). Confirmed by mutating the composer to
## emit its per-backend inventory unconditionally — (1) then fails.
##
## Also asserts (4) that the DS-7 `--tag` selector works in THIS shape: its
## tag attribution comes from the resolved manifest membership, which a
## workspace with no routing config never reaches, so `--tag=<a tag the
## committed lock itself declares>` refused with "the declared tags are:
## (none)" -- a false answer, not a narrow one.
##
## Mocks: NONE. Real git repos on the real filesystem and the real ``repro``
## binary.
##
## Hermetic: fresh tempdir; the other config layers are silenced. Skip: ``git``
## missing or repro unbuilt.

import std/[algorithm, json, os, osproc, strutils, tempfiles, unittest]
from repro_test_support import fileUrl

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, resolved from THIS SOURCE FILE's path
  ## rather than from the process working directory.
  ##
  ## The previous spelling (``"./build/bin/" & addFileExt("repro", ExeExt)``)
  ## made the working directory an unstated fixture input: from the repo root
  ## the case ran, from any other directory ``fileExists`` was false and it
  ## SKIPPED, and from a scratch directory that happened to carry a staged
  ## ``build/bin/repro`` it ran against THAT binary and reported failures that
  ## read as product refusals. ``currentSourcePath()`` is absolute on both
  ## platforms, so this constant is the same from every cwd.
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  ## `doAssert`, not `check` or `quit`: this is a HELPER, outside any
  ## `test` body. `unittest.check` there cannot see the `testStatusIMPL`
  ## the `test` template injects, so it prints "Check failed" and the case
  ## still reports `[OK]`; `quit 1` tears the process down mid-case, so
  ## `unittest` emits no `[FAILED]` marker and every later case in the file
  ## silently never runs. `doAssert` raises an `AssertionDefect`, which the
  ## `test` template's own `except Exception` catches and reports as a
  ## failure from any call depth.
  let res = run(command, cwd)
  doAssert res.code == 0, "command failed: " & command & "\nexit=" &
    $res.code & "\n" & res.output
  res.output

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  createDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Public Only Tester\"")
  writeFile(workPath / "seed.txt", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc depInline(name, path, url, sha, depends: string;
               tags = ""): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"" & depends & "\", tags = \"" & tags & "\" }"

proc committedLock(deps: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds1-public-only\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & deps & "]\n"

suite "DS-1: a public-only workspace is unchanged by the lock-set composer":

  test "t_develop_public_only_unchanged":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds1-public-only-", "")
      defer: removeDir(scratch)

      let libaOrigin = scratch / "origin-liba.git"
      let libbOrigin = scratch / "origin-libb.git"
      let libaSha = seedGitOrigin(gitBin, libaOrigin, scratch / "seed-liba")
      let libbSha = seedGitOrigin(gitBin, libbOrigin, scratch / "seed-libb")
      let appOrigin = scratch / "origin-app.git"
      let appSha = seedGitOrigin(gitBin, appOrigin, scratch / "seed-app")

      let lockBody = committedLock(
        depInline("app", ".", fileUrl(appOrigin), appSha, "liba,libb") &
        ", " & depInline("liba", "liba", fileUrl(libaOrigin), libaSha, "") &
        ", " & depInline("libb", "libb", fileUrl(libbOrigin), libbSha, ""))

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1) the WHOLE observable output of a public-only run. ---------
      let ws1 = scratch / "ws-text"
      createDir(ws1)
      writeFile(ws1 / "repro.lock", lockBody)
      let deps1 = scratch / "deps-text"
      let res1 = run(repro & " develop --all --into=" & q(deps1) &
        " --tool-provisioning=path", cwd = ws1)
      if res1.code != 0:
        checkpoint("develop --all output: " & res1.output)
      check res1.code == 0
      let expected =
        "repro develop --all: cloned liba @ " & libaSha & " -> " &
          (deps1 / "liba") & "\n" &
        "repro develop --all: cloned libb @ " & libbSha & " -> " &
          (deps1 / "libb") & "\n"
      if res1.output != expected:
        checkpoint("expected:\n" & expected & "\nactual:\n" & res1.output)
      check res1.output == expected

      # ---- (2) the selected set IS the committed lock's deps minus root. -
      let ws2 = scratch / "ws-json"
      createDir(ws2)
      writeFile(ws2 / "repro.lock", lockBody)
      let deps2 = scratch / "deps-json"
      let res2 = run(repro & " develop --all --json --into=" & q(deps2) &
        " --tool-provisioning=path", cwd = ws2)
      check res2.code == 0
      let report = parseJson(res2.output)
      check report["exitCode"].getInt() == 0
      var got: seq[string]
      for node in report["nodes"]:
        check node["ok"].getBool()
        got.add(node["node"].getStr() & "@" & node["revision"].getStr())
      got.sort()
      check got == @["liba@" & libaSha, "libb@" & libbSha]
      # The root `.` consumer is never selected.
      check "\"node\": \"app\"" notin res2.output

      # ---- (3) a bootstrap config with NO [locking] table changes nothing.
      let ws3 = scratch / "ws-nolocking"
      createDir(ws3)
      writeFile(ws3 / "repro.lock", lockBody)
      writeFile(ws3 / ".repro-workspace.toml",
        "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
        "[manifest]\n" &
        "url = \"https://example.invalid/manifests.git\"\n")
      let deps3 = scratch / "deps-nolocking"
      let res3 = run(repro & " develop --all --into=" & q(deps3) &
        " --tool-provisioning=path", cwd = ws3)
      check res3.code == 0
      check res3.output ==
        "repro develop --all: cloned liba @ " & libaSha & " -> " &
          (deps3 / "liba") & "\n" &
        "repro develop --all: cloned libb @ " & libbSha & " -> " &
          (deps3 / "libb") & "\n"

      # ---- (4) `--tag` works HERE too, on the committed lock's own
      #          `tags`, and does not claim the workspace has none. -------
      #
      # DS-7's tag attribution is read from the resolved MANIFEST membership,
      # which the composer only reaches when a configuration layer declares a
      # route. This workspace shape — "a workspace with no routing config
      # resolves to the built-in public default alone" (CLI/develop.md
      # §"Composing the lock set") — is precisely the one where it does not,
      # and `--tag=libs` refused with
      #
      #   '--tag=libs' names no manifest tag in this workspace (names are
      #   matched EXACTLY; the declared tags are: (none))
      #
      # for a tag the committed lock ITSELF declares on both repos. That is
      # not a narrower answer, it is a false one — the exact failure mode the
      # exact-name loudness rule exists to produce truthfully.
      let taggedLock = committedLock(
        depInline("app", ".", fileUrl(appOrigin), appSha, "liba,libb") &
        ", " & depInline("liba", "liba", fileUrl(libaOrigin), libaSha, "",
                         tags = "libs") &
        ", " & depInline("libb", "libb", fileUrl(libbOrigin), libbSha, "",
                         tags = "tools"))
      let ws4 = scratch / "ws-tags"
      createDir(ws4)
      writeFile(ws4 / "repro.lock", taggedLock)
      proc list4(flags: string): tuple[code: int; output: string] =
        run(repro & " develop --list --tool-provisioning=path " & flags,
          cwd = ws4)
      let libsOnly = list4("--tag=libs")
      if libsOnly.code != 0:
        checkpoint("develop --list --tag=libs output: " & libsOnly.output)
      check libsOnly.code == 0
      check "liba" in libsOnly.output
      check "libb" notin libsOnly.output
      check "selection: tag --tag=libs -> 1 repo(s)" in libsOnly.output
      # …and an unknown tag is still the loud refusal, now NAMING the tags
      # the lock actually declares rather than "(none)".
      let badTag = list4("--tag=nope")
      check badTag.code == 2
      check "'--tag=nope' names no manifest tag in this workspace" in
        badTag.output
      # `app` declares no tags, so it is in the implicit `default` one.
      check "the declared tags are: default, libs, tools" in badTag.output
