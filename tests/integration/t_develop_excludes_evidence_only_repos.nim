## DS-4 (CLI/develop.md §"Evidence-only repos"; Unified-Locking-And-Hooks.md
## §7) — an evidence-only repo is NEVER placed into develop mode.
##
##   > An evidence-only repo participates by publishing a source-free evidence
##   > triple and never its source. It is therefore **never** placed into
##   > develop mode. It appears in `--list` output with state `evidence-only`,
##   > and naming one explicitly (`--only=<repo>`) is a loud error that explains
##   > why, rather than a silent omission.
##
## The distinction that matters: the repo is a MEMBER of the workspace lock set
## (its backend holds membership plus the evidence triple) but has no obtainable
## source by construction. Dropping it quietly would be indistinguishable from
## it not being in the workspace at all.
##
## Fixture: a manifest workspace with a reachable team backend and two repos —
## `core` (ordinary, pinned by the committed lock) and `secret-lib`
## (``participation = "evidence-only"`` in its manifest fragment, routed to the
## team backend).
##
## Asserts:
##   1. ``--all`` exits 0, clones `core`, and does NOT clone `secret-lib`;
##   2. the exclusion is NAMED, with the state and the reason — never silent;
##   3. ``--only=secret-lib`` is a LOUD error (exit 2) that explains why an
##      evidence-only repo can never be developed;
##   4. ``--only`` is not merely always-fatal: ``--only=core`` selects exactly
##      `core`, and ``--only=<unknown>`` is a loud exact-name error.
##
## Falsifiability: making the exclusion silent (drop the notice) fails (2);
## letting ``--only`` fall through to an empty selection instead of erroring
## fails (3); dropping evidence-only repos from the composed lock set entirely
## fails (2) AND (3) — the repo would be reported as "names no repo", which is
## the silent-omission failure mode itself.
##
## Mocks: NONE. A real manifest checkout with a real ``participation =
## "evidence-only"`` fragment, a real git-checkout backend, and the real
## ``repro`` binary.
##
## Hermetic: fresh tempdir; the other config layers are silenced. Skip: ``git``
## missing or repro unbuilt.

import std/[os, osproc, strutils, tempfiles, unittest]
from repro_test_support import fileUrl

import repro_workspace_manifests

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

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"Evidence Only Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  initGitRepo(gitBin, workPath)
  writeFile(workPath / "seed.txt", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))

proc projectToml(coreUrl, secretUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"mix\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"core-origin\"\nfetch = \"" & coreUrl & "\"\n\n" &
  "[[remote]]\nname = \"secret-origin\"\nfetch = \"" & secretUrl & "\"\n\n" &
  "includes = [\n  \"repos/core.toml\",\n  \"repos/secret-lib.toml\",\n]\n"

proc repoFragment(name, remote: string; participation = ""): string =
  result =
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\n" &
    "name = \"" & name & "\"\n" &
    "path = \"" & name & "\"\n" &
    "remote = \"" & remote & "\"\n" &
    "revision = \"main\"\n"
  if participation.len > 0:
    result.add("participation = \"" & participation & "\"\n")

proc depInline(name, path, url, sha: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & url & "\", ref = \"main\"" &
    ", revision = \"" & sha & "\", integrity = \"git-sha1:" & sha &
    "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"\", groups = \"\" }"

proc committedLock(coreUrl, coreSha, extraUrl, extraSha: string): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
  "[lock]\n" &
  "platform = \"x86_64-linux\"\n" &
  "optimal = true\n" &
  "inputs_digest = \"ds4-evidence-only\"\n" &
  "variants = []\n" &
  "packages = []\n" &
  "deps = [" & depInline("core", "core", coreUrl, coreSha) & ", " &
    depInline("extra", "extra", extraUrl, extraSha) & "]\n"

proc buildWorkspace(gitBin, scratch, coreOrigin, secretOrigin, extraOrigin,
                    name, coreSha, extraSha: string): string =
  ## One workspace: a PUBLIC `core` + `extra` pinned by the committed lock, and
  ## an evidence-only `secret-lib` routed to a reachable TEAM backend. Two
  ## independent copies are built so a mutating run in one cannot perturb the
  ## develop-override state the other observes.
  let ws = scratch / name
  createDir(ws)
  let manifestsRoot = ws / ".repro" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "mix.toml",
    projectToml(fileUrl(coreOrigin), fileUrl(secretOrigin)))
  writeFile(manifestsRoot / "repos" / "core.toml",
    repoFragment("core", "core-origin"))
  # The source-secret repo: it participates by evidence only.
  writeFile(manifestsRoot / "repos" / "secret-lib.toml",
    repoFragment("secret-lib", "secret-origin",
      participation = "evidence-only"))
  initGitRepo(gitBin, manifestsRoot)
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(manifestsRoot) &
    " commit -m manifests")
  cloneInto(gitBin, coreOrigin, ws / "core")
  writeWorkspaceBranch(ws, project = "mix", branch = "main")
  writeFile(ws / "repro.lock", committedLock(
    fileUrl(coreOrigin), coreSha, fileUrl(extraOrigin), extraSha))
  writeFile(ws / ".repro-workspace.toml",
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\n" &
    "url = \"https://example.invalid/manifests.git\"\n\n" &
    "[locking]\n" &
    "route = [{ visibility = \"team\", backend = \"git-checkout\", " &
    "path = \".repro/manifests\", repos = [\"secret-lib\"] }]\n")
  ws

suite "DS-4: evidence-only repos are excluded from the develop set":

  test "t_develop_excludes_evidence_only_repos":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let repro = absolutePath(reproBinary)
      let scratch = createTempDir("ds4-evidence-", "")
      defer: removeDir(scratch)

      let coreOrigin = scratch / "origin-core.git"
      let secretOrigin = scratch / "origin-secret.git"
      let extraOrigin = scratch / "origin-extra.git"
      let coreSha = seedGitOrigin(gitBin, coreOrigin, scratch / "seed-core")
      let extraSha = seedGitOrigin(gitBin, extraOrigin, scratch / "seed-extra")
      discard seedGitOrigin(gitBin, secretOrigin, scratch / "seed-secret")

      putEnv("REPROBUILD_SYSTEM_CONFIG", scratch / "no-system.toml")
      putEnv("REPROBUILD_USER_CONFIG", scratch / "no-user.toml")
      putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", scratch / "no-vcs.toml")
      defer:
        delEnv("REPROBUILD_SYSTEM_CONFIG")
        delEnv("REPROBUILD_USER_CONFIG")
        delEnv("REPROBUILD_VCS_PRIVATE_CONFIG")

      # ---- (1)+(2) excluded from the set, and NAMED. ---------------------
      let ws = buildWorkspace(gitBin, scratch, coreOrigin, secretOrigin,
        extraOrigin, "ws-all", coreSha, extraSha)
      let deps = scratch / "deps"
      let res = run(repro & " develop --all --into=" & q(deps) &
        " --tool-provisioning=path", cwd = ws)
      if res.code != 0:
        checkpoint("develop --all output: " & res.output)
      check res.code == 0
      check ("cloned core @ " & coreSha) in res.output
      check "cloned secret-lib" notin res.output
      check not dirExists(deps / "secret-lib")
      # The exclusion is reported with the state and the reason.
      check "excluded from the develop set" in res.output
      check "secret-lib" in res.output
      check "evidence-only" in res.output
      check "source-free evidence triple" in res.output

      # ---- (3) naming one explicitly is a LOUD error. --------------------
      let named = run(repro & " develop --only=secret-lib --into=" &
        q(scratch / "deps-named") & " --tool-provisioning=path", cwd = ws)
      if named.code != 2:
        checkpoint("--only=secret-lib output: " & named.output)
      check named.code == 2
      check "EVIDENCE-ONLY" in named.output
      check "never be placed into develop mode" in named.output
      check not dirExists(scratch / "deps-named" / "secret-lib")

      # ---- (4) --only is a real selector, and exact-name loud. -----------
      # A SECOND, untouched copy of the fixture: the run above already recorded
      # develop overrides in ``ws``, and re-developing the same node into a
      # different root is (correctly) refused, which would mask what this case
      # is actually asking.
      let ws2 = buildWorkspace(gitBin, scratch, coreOrigin, secretOrigin,
        extraOrigin, "ws-only", coreSha, extraSha)
      let depsOnly = scratch / "deps-only-core"
      let onlyCore = run(repro & " develop --only=core --into=" &
        q(depsOnly) & " --tool-provisioning=path", cwd = ws2)
      if onlyCore.code != 0:
        checkpoint("--only=core output: " & onlyCore.output)
      check onlyCore.code == 0
      check ("cloned core @ " & coreSha) in onlyCore.output
      check dirExists(depsOnly / "core")
      # --only NARROWS: the other public repo in the same lock set is not taken.
      check not dirExists(depsOnly / "extra")
      check "cloned extra" notin onlyCore.output

      let onlyUnknown = run(repro & " develop --only=not-a-repo --into=" &
        q(scratch / "deps-unknown") & " --tool-provisioning=path", cwd = ws2)
      check onlyUnknown.code == 2
      check "names no repo in this workspace's lock set" in onlyUnknown.output
