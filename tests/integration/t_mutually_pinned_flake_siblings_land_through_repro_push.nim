## Two repos that must land together CAN be landed: a dependency whose
## `flake.lock` pins its own dependent, and `repro push` from that dependent.
##
## Issue: reprobuild-pm `issues/2026-10-15-codetracer-and-reprobuild-pre-push-
## gates-deadlock-and-repro-push-cannot-break-it.md`. Spec: CLI/push.md §"The
## closure is what the gate requires published" and §"Mutually pinned flakes,
## and the order that terminates"; Nix-Flake-Coexistence.md §3.1a.
##
## ## Topology (the issue's, reduced)
##
##     app  --depends-->  lib  --depends-->  core
##      ^                                     |
##      +------- core/flake.nix pins app -----+   (`app-src`, rev-pinned,
##                                                 `flake = false`)
##
## `app` plays `codetracer`, `lib` plays `nim-shm-queue` (the intermediate
## whose `depends = ["reprobuild"]` closes the loop) and `core` plays
## `reprobuild`, whose `codetracer-src` input pins codetracer by revision.
## `other` is a sibling `core`'s flake ALSO pins but that does not depend on
## `core` — the negative control for the deferral rule.
##
## `core`'s flake input is substituted by the `app` checkout only because an
## EXPLICIT develop override says so (`substituteAppInCore`). A recipe input
## pinned by exact revision is compared with its sibling checkout only when an
## explicit override substitutes it (Unified-Locking-And-Hooks.md §16.5): a
## bulk override, or membership in the develop set alone, leaves the pin to the
## lock checks and the gate does not compare it. Every case that needs the
## pre-push flake stage to compare `app-src` therefore records that override.
##
## `app` carries its own committed `repro.lock`, as `codetracer` does. That lock
## puts `app` in the develop set, which by itself does not substitute the
## rev-pinned input. It is what made the issue's `repro push` resolve a
## different workspace than its hook: a committed
## `repro.lock` is a workspace marker (MO-2), and a bare `repro push` used the
## current directory as the workspace root, so it computed the closure from
## `app`'s lock (`app -> lib`, no `core`) while the managed hook walked up to
## the real workspace (`app -> lib -> core`). Measured on the unfixed tree:
## `repro push: closure app, lib (push order: lib → app)`, then `app` refused
## by its own hook over `core: unpublished`.
##
## ## What is asserted
##
##   * `repro push` from `app` — both the bare form and the explicit
##     `--workspace-root`/`--current-repo` form the hook uses — publishes
##     `core`, `lib`, `app` in that order and exits 0, without committing any
##     `flake.lock` refresh (mutual pins have no fixpoint);
##   * the raw `git push` of `core` passes with a NOTICE naming the order that
##     terminates, and never prescribes `app`'s push, which `app`'s own gate
##     provably refuses until `core` is published;
##   * negative controls — each still refuses exactly as before: a pin that lags
##     an unpublished sibling that does NOT depend on `core`; a pin that lags a
##     PUBLISHED sibling; a sibling BEHIND its pin; a DIVERGED sibling; an
##     ahead sibling whose PIN itself is unpublished (a lock nobody could
##     reproduce must not be published, cycle or no cycle); and a pushed repo
##     whose HEAD is already published elsewhere (the sibling's gate then
##     accepts it, so the sibling can go first and there is no cycle);
##   * `repro push` also publishes a develop override that names a declared
##     workspace repo, ahead of every closure member, because each member's own
##     gate refuses over every override (stage 3), not only those inside the
##     `depends` closure.
##
## ## Develop overrides and linked worktrees (third suite)
##
## Stage 3 reads the WHOLE override file, so two unpublished overrides — or an
## override whose `depends` reaches a closure member or the pushed repo — refused
## each other in every order at reprobuild a8a6e51f58. The gate now defers such
## an override exactly when it provably cannot go first, is outside the pushed
## repo's closure, and is not pinned at its unpublished HEAD by the pushed repo's
## committed locks (Workspace-And-Develop-Mode.md §"Develop overrides that wait
## on the push"); any other unpublished override still refuses. And
## `repro push` from a linked worktree outside the declared path used to widen
## to the whole workspace and never push the worktree (CLI/push.md §"Scope");
## from a worktree outside the workspace directory it lands through the gate,
## which follows the git common directory back to the workspace.
##
## ## Test-double policy: NO mocks, doubles or fakes
##
## Real bare origins, real clones, real commits, the real `flake.lock` on-disk
## shape (its `original.rev` is how nix records a rev-pinned input), the real
## built `repro` binary, and the REAL managed hooks installed by
## `repro hooks ensure --vcs`, fired by git itself during real `git push`es.
## `nix` is not run: the gate reads `flake.lock` and never evaluates it, and
## the `narHash` values are inert placeholders for the same reason the NF-2
## fixture's are. The explicit override document is written by hand in the
## exact shape `repro develop <input> --into=…` writes, because that verb needs
## a `repro.nim` in both checkouts and these repos carry none
## (`substituteAppInCore` says why it is that document and not the workspace
## override file).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath},
    workingDir = cwd)
  (res.exitCode, res.output)

proc require(command: string): string =
  let res = run(command)
  if res.code != 0:
    stderr.writeLine("FIXTURE ABORT: command failed: " & command & "\n" &
      res.output)
    quit 1
  res.output

proc root(): string = currentSourcePath().parentDir.parentDir.parentDir
proc reproBinary(): string =
  requireBinary(root() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const Repos = ["app", "lib", "core", "other", "extra"]
  ## `extra` is a second repo outside every closure, used as a develop override.

type Fixture = object
  git, repro, scratch, workspace, manifests: string
  seed: array[Repos.len, string]   ## seed revision of each repo, in `Repos` order

proc dir(fx: Fixture; name: string): string = fx.workspace / name
proc bare(fx: Fixture; name: string): string = fx.scratch / (name & ".git")
proc url(fx: Fixture; name: string): string = fileUrl(fx.bare(name))
proc gitIn(fx: Fixture; repo, args: string): string =
  require(q(fx.git) & " -C " & q(repo) & " " & args)
proc head(fx: Fixture; repo: string): string =
  fx.gitIn(repo, "rev-parse HEAD").strip()
proc remoteHead(fx: Fixture; name: string): string =
  fx.gitIn(fx.bare(name), "rev-parse refs/heads/main").strip()
proc seedOf(fx: Fixture; name: string): string = fx.seed[Repos.find(name)]

proc configure(fx: Fixture; path: string) =
  discard fx.gitIn(path, "config user.email tester@example.invalid")
  discard fx.gitIn(path, "config user.name 'Mutual Pin Tester'")

proc commitFile(fx: Fixture; repo, file, content, message: string): string =
  writeFile(repo / file, content)
  discard fx.gitIn(repo, "add -A")
  discard fx.gitIn(repo, "commit -q -m " & q(message))
  fx.head(repo)

proc lockDep(fx: Fixture; name, path, sha, depends: string): string =
  "{ name = \"" & name & "\", path = \"" & path &
    "\", coord_kind = \"vcs\", url = \"" & fx.url(name) &
    "\", ref = \"main\", revision = \"" & sha & "\", integrity = \"git-sha1:" &
    sha & "\", version = \"\", visibility = \"public\", participation = \"\"" &
    ", depends = \"" & depends & "\", groups = \"\" }"

proc committedLock(deps: seq[string]): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
    "platform = \"x86_64-linux\"\noptimal = true\n" &
    "inputs_digest = \"mutual-pin-fixture\"\nvariants = []\npackages = []\n" &
    "deps = [" & deps.join(", ") & "]\n"

proc flakeNode(fx: Fixture; input, repo, rev: string; revPinned: bool): string =
  ## One `flake = false` git input node in nix's on-disk shape. `original.rev`
  ## is present exactly when `flake.nix` pins the input BY REVISION.
  "    \"" & input & "\": {\n" &
  "      \"flake\": false,\n" &
  "      \"locked\": {\n" &
  "        \"lastModified\": 1787946353,\n" &
  "        \"narHash\": \"sha256-fv2PzTwKsfeBptF8u/G0w9eh6GDsib/62l5cyuKNGYM=\",\n" &
  "        \"rev\": \"" & rev & "\",\n" &
  "        \"revCount\": 1,\n" &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"" & fx.url(repo) & "\"\n" &
  "      },\n" &
  "      \"original\": {\n" &
  (if revPinned: "        \"rev\": \"" & rev & "\",\n" else: "") &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"" & fx.url(repo) & "\"\n" &
  "      }\n" &
  "    }"

proc writeCoreFlake(fx: Fixture; appPin, otherPin: string) =
  ## `app-src` is pinned BY REVISION (the issue's `codetracer-src` shape);
  ## `other-src` floats, so its refusal names the ordinary push+refresh remedy.
  writeFile(fx.dir("core") / "flake.nix",
    "{\n  inputs = {\n" &
    "    app-src = {\n      url = \"git+" & fx.url("app") & "?rev=" & appPin &
      "\";\n      flake = false;\n    };\n" &
    "    other-src = {\n      url = \"git+" & fx.url("other") &
      "?ref=main\";\n      flake = false;\n    };\n" &
    "  };\n  outputs = _: { };\n}\n")
  writeFile(fx.dir("core") / "flake.lock",
    "{\n  \"nodes\": {\n" &
    fx.flakeNode("app-src", "app", appPin, true) & ",\n" &
    fx.flakeNode("other-src", "other", otherPin, false) & ",\n" &
    "    \"root\": {\n      \"inputs\": {\n" &
    "        \"app-src\": \"app-src\",\n        \"other-src\": \"other-src\"\n" &
    "      }\n    }\n  },\n  \"root\": \"root\",\n  \"version\": 7\n}\n")

proc repoToml(name: string; depends: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nmainline = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [\"" & depends.join("\", \"") & "\"]\n")

proc setup(slug: string; libDependsOnCore = true;
    extraDependsOnCore = false): Fixture =
  ## The published starting state: every repo at its seed, `core`'s flake
  ## pinning the seeds of `app` and `other`, and every pin AT its sibling.
  result.git = findExe("git")
  result.repro = reproBinary()
  # Canonical: `git rev-parse --show-toplevel` answers with the resolved path
  # (`/private/var/…` on macOS), so the fixture speaks the same spelling.
  result.scratch = expandFilename(createTempDir("repro-mutual-pin-" & slug &
    "-", ""))
  result.workspace = result.scratch / "workspace"
  result.manifests = result.workspace / ".repro" / "manifests"
  var fx = result
  for i, name in Repos:
    let seedDir = fx.scratch / ("seed-" & name)
    discard require(q(fx.git) & " init -q --bare -b main " & q(fx.bare(name)))
    discard require(q(fx.git) & " init -q -b main " & q(seedDir))
    fx.configure(seedDir)
    # `.repro/` is per-checkout tool state in every real repo, never content.
    writeFile(seedDir / ".gitignore", ".repro/\n")
    writeFile(seedDir / "README.md", name & "\n")
    # A substituted sibling must be a flake (NF-1), exactly like codetracer.
    if name in ["app", "other"]:
      writeFile(seedDir / "flake.nix", "{ outputs = _: { }; }\n")
      # Its own committed lock is the record that puts it in the develop set
      # (a repo's committed lock contributes its ROOT entry), which is what
      # makes `core`'s flake input really substituted by this checkout.
      writeFile(seedDir / "repro.lock", committedLock(@[
        fx.lockDep(name, ".", "0000000000000000000000000000000000000001", "")]))
    discard fx.gitIn(seedDir, "add -A")
    discard fx.gitIn(seedDir, "commit -q -m " & q("seed " & name))
    discard fx.gitIn(seedDir, "remote add origin " & q(fx.bare(name)))
    discard fx.gitIn(seedDir, "push -q origin main")
    fx.seed[i] = fx.head(seedDir)
  result = fx
  createDir(result.manifests / "projects")
  createDir(result.manifests / "repos")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\n\n"
  for name in Repos:
    project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fx.url(name) & "\"\n\n")
  project.add("includes = [\"repos/app.toml\", \"repos/lib.toml\", " &
    "\"repos/core.toml\", \"repos/other.toml\", \"repos/extra.toml\"]\n")
  writeFile(result.manifests / "projects" / "app.toml", project)
  writeFile(result.manifests / "repos" / "app.toml", repoToml("app", @["lib"]))
  # `libDependsOnCore = false` breaks the cycle, for the `repro.lock` stage's
  # non-cyclic negative control.
  writeFile(result.manifests / "repos" / "lib.toml",
    repoToml("lib", if libDependsOnCore: @["core"] else: @[]))
  writeFile(result.manifests / "repos" / "core.toml", repoToml("core", @[]))
  writeFile(result.manifests / "repos" / "other.toml", repoToml("other", @[]))
  # `extraDependsOnCore` makes `extra` an override whose own `depends` reaches a
  # member of `app`'s closure.
  writeFile(result.manifests / "repos" / "extra.toml",
    repoToml("extra", if extraDependsOnCore: @["core"] else: @[]))
  discard require(q(fx.git) & " init -q --bare -b main " &
    q(fx.scratch / "manifest.git"))
  discard require(q(fx.git) & " init -q -b main " & q(fx.manifests))
  fx.configure(fx.manifests)
  discard fx.gitIn(fx.manifests, "add projects repos")
  discard fx.gitIn(fx.manifests, "commit -q -m 'seed manifest'")
  discard fx.gitIn(fx.manifests, "remote add origin " &
    q(fx.scratch / "manifest.git"))
  discard fx.gitIn(fx.manifests, "push -q -u origin main")
  for name in Repos:
    discard require(q(fx.git) & " clone -q " & q(fx.url(name)) & " " &
      q(fx.dir(name)))
    fx.configure(fx.dir(name))
  writeWorkspaceBranch(result.workspace, project = "app", branch = "main")
  writeFile(result.workspace / "repro-workspace.toml",
    "schema = \"reprobuild.workspace.settings.v1\"\n\n[records]\n" &
    "url = \"" & fileUrl(fx.scratch / "manifest.git") & "\"\n" &
    "publish_locks = true\n")
  fx.writeCoreFlake(fx.seedOf("app"), fx.seedOf("other"))
  discard fx.gitIn(fx.dir("core"), "add -A")
  discard fx.gitIn(fx.dir("core"), "commit -q -m 'core flake pins app and other'")
  discard fx.gitIn(fx.dir("core"), "push -q origin HEAD:main")
  putEnv("REPROBUILD_SYSTEM_CONFIG", fx.scratch / "no-system.toml")
  putEnv("REPROBUILD_USER_CONFIG", fx.scratch / "no-user.toml")
  putEnv("REPROBUILD_VCS_PRIVATE_CONFIG", fx.scratch / "no-vcs.toml")
  putEnv("REPROBUILD_REPRO", fx.repro)

proc release(fx: Fixture) =
  for name in ["REPROBUILD_SYSTEM_CONFIG", "REPROBUILD_USER_CONFIG",
      "REPROBUILD_VCS_PRIVATE_CONFIG", "REPROBUILD_REPRO"]:
    delEnv(name)
  removeDir(fx.scratch)

proc pinLibInCoreLock(fx: Fixture; libPin: string) =
  ## Give `core` a committed `repro.lock` pinning `lib` — the issue's other
  ## mutual pin: `reprobuild/repro.lock` pins `nim-shm-queue`, whose
  ## `depends = ["reprobuild"]`. Committed and PUBLISHED, so the pin itself is
  ## obtainable; the case then moves `lib` and commits in `core`.
  writeFile(fx.dir("core") / "repro.lock", committedLock(@[
    fx.lockDep("core", ".", "0000000000000000000000000000000000000001", ""),
    fx.lockDep("lib", "../lib", libPin, "")]))
  discard fx.gitIn(fx.dir("core"), "add -A")
  discard fx.gitIn(fx.dir("core"), "commit -q -m 'core repro.lock pins lib'")
  discard fx.gitIn(fx.dir("core"), "push -q origin HEAD:main")

proc commitAppWork(fx: Fixture; label: string): string =
  ## A new `app` commit carrying `app`'s committed `repro.lock`, written the way
  ## its pre-commit hook writes it: the root entry plus every sibling at the
  ## revision it is checked out at. Its `depends` edges are `app`'s OWN view
  ## (`app -> lib`, nothing further) — which is what made the lock-rooted
  ## closure miss `core` in the issue.
  writeFile(fx.dir("app") / "repro.lock", committedLock(@[
    fx.lockDep("app", ".", fx.seedOf("app"), "lib"),
    fx.lockDep("lib", "../lib", fx.head(fx.dir("lib")), ""),
    fx.lockDep("core", "../core", fx.head(fx.dir("core")), ""),
    fx.lockDep("other", "../other", fx.head(fx.dir("other")), "")]))
  fx.commitFile(fx.dir("app"), "work.txt", label & "\n", label)

proc installHooks(fx: Fixture) =
  for target in [fx.workspace, fx.manifests]:
    let ensured = runShell(shellCommand(@[fx.repro, "hooks", "ensure", "--vcs",
      "--workspace-root=" & target]))
    if ensured.code != 0:
      stderr.writeLine("hook ensure failed for " & target & ":\n" &
        ensured.output)
      quit 1

proc rawPush(fx: Fixture; name: string): tuple[code: int; output: string] =
  ## A plain `git push`, so the REAL managed pre-push hook decides.
  run(q(fx.git) & " -C " & q(fx.dir(name)) & " push origin HEAD:main")

proc reproPush(fx: Fixture; name: string; explicit: bool):
    tuple[code: int; output: string] =
  ## `repro push` exactly as typed in the repo (`explicit = false`: no location
  ## flag, so the command must find the workspace the way its hook does), or
  ## with the two location flags the hook itself passes to the gate.
  var args = @[fx.repro, "push", "--no-certify", "--write-report"]
  if explicit:
    args.add("--workspace-root=" & fx.workspace)
    args.add("--current-repo=" & fx.dir(name))
  runShell(shellCommand(args), cwd = fx.dir(name))

proc registerOverrides(fx: Fixture; names: openArray[string]) =
  ## Register declared checkouts as develop overrides, as `repro develop` does.
  var overrides = newDevelopOverrides()
  for name in names:
    overrides = addOverride(overrides, DevelopOverrideEntry(package: name,
      local_path: fx.dir(name), state: "editable",
      created_at: "2026-10-16T00:00:00Z"))
  writeDevelopOverridesFile(fx.workspace, overrides)

proc substituteAppInCore(fx: Fixture) =
  ## Substitute `core`'s rev-pinned `app-src` input with the `app` checkout by
  ## an EXPLICIT develop override: `core`'s per-project override document, the
  ## record `repro develop app-src --into=<app>` keeps in `core`'s git
  ## directory. Written in that document's exact on-disk shape, because the
  ## verb itself needs a `repro.nim` in both checkouts and this fixture's repos
  ## carry none (the gate matches an override by name or by checkout path, so
  ## the path is what names `app` here).
  ##
  ## Not the workspace `.repro/develop-overrides.toml` with `--only`
  ## provenance, although that is equally explicit: stage 3 reads THAT file,
  ## and over an unpublished `app` it would defer the override (adding a
  ## second `DEFERRED` notice) or, once `core`'s HEAD is published, refuse
  ## before the flake stage runs at all. These cases assert on the flake
  ## stage, so the substitution is recorded where only the flake stage reads
  ## it, and stage 3 sees no override, exactly as before §16.5.
  let path = fx.dir("core") / ".git" / "reprobuild" / "develop-overrides.json"
  createDir(parentDir(path))
  writeFile(path, pretty(%*{
    "schemaId": "reprobuild.develop-overrides.v1",
    "projectRoot": fx.dir("core"),
    "overrides": [{"node": "app-src", "path": fx.dir("app")}]}) & "\n")

proc pushReport(fx: Fixture): JsonNode =
  let path = fx.workspace / ".repro" / "build" / "reports" / "push-report.json"
  if fileExists(path): parseFile(path) else: newJObject()

proc orderOf(report: JsonNode): seq[string] =
  if report.kind == JObject and report.hasKey("order"):
    for n in report["order"]: result.add(n.getStr())

proc arrangeTheDeadlock(fx: Fixture): tuple[core, lib, app: string] =
  ## The issue's state: `core` and `app` (and `lib`, so every hop of the closure
  ## is a real publication) each carry one unpublished commit, and `core`'s
  ## `flake.lock` pins `app`'s PUBLISHED seed, which the new `app` HEAD is
  ## 1 commit ahead of.
  result.core = fx.commitFile(fx.dir("core"), "work.txt", "core work\n",
    "core: unpublished work")
  result.lib = fx.commitFile(fx.dir("lib"), "work.txt", "lib work\n",
    "lib: unpublished work")
  result.app = fx.commitAppWork("app: unpublished work")

proc gateRefused(output, property, repo: string): bool =
  ("repro check: " & repo & ": " & property) in output

suite "mutually pinned flake siblings land through repro push":

  test "bare repro push from the dependent publishes core, lib, app in order":
    let fx = setup("bare")
    defer: fx.release()
    let heads = fx.arrangeTheDeadlock()
    let coreLock = readFile(fx.dir("core") / "flake.lock")
    fx.substituteAppInCore()
    fx.installHooks()
    let pushed = fx.reproPush("app", explicit = false)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.remoteHead("core") == heads.core
    check fx.remoteHead("lib") == heads.lib
    check fx.remoteHead("app") == heads.app
    check fx.pushReport().orderOf() == @["core", "lib", "app"]
    # No fixpoint exists, so nothing was refreshed or committed behind the
    # operator's back: `core` published exactly the commit it had.
    check fx.head(fx.dir("core")) == heads.core
    check readFile(fx.dir("core") / "flake.lock") == coreLock

  test "explicit-location repro push publishes the same closure":
    let fx = setup("explicit")
    defer: fx.release()
    let heads = fx.arrangeTheDeadlock()
    fx.substituteAppInCore()
    fx.installHooks()
    let pushed = fx.reproPush("app", explicit = true)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.remoteHead("core") == heads.core
    check fx.remoteHead("app") == heads.app
    check fx.pushReport().orderOf() == @["core", "lib", "app"]

  test "raw core push defers the cyclic pin and names the terminating order":
    let fx = setup("raw")
    defer: fx.release()
    let heads = fx.arrangeTheDeadlock()
    fx.substituteAppInCore()
    fx.installHooks()
    # The dependent first: refused over core, as it must be (invariant 2).
    let appFirst = fx.rawPush("app")
    checkpoint("raw app push:\n" & appFirst.output)
    check appFirst.code != 0
    check gateRefused(appFirst.output, "unpublished", "lib") or
      gateRefused(appFirst.output, "unpublished", "core")
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code == 0
    check not gateRefused(core.output, "flake_lock_stale", "core")
    check fx.remoteHead("core") == heads.core
    # The notice names the deferral and the sequence that terminates...
    check "DEFERRED" in core.output
    check "'app' (flake input 'app-src')" in core.output
    check ("repro push") in core.output
    # ...and never prescribes the push its own evidence proves blocked.
    check ("git -C " & fx.dir("app") & " push") notin core.output
    check fx.rawPush("lib").code == 0
    let appAfter = fx.rawPush("app")
    checkpoint("raw app push after core:\n" & appAfter.output)
    check appAfter.code == 0
    check fx.remoteHead("app") == heads.app

  test "a lag behind an unpublished sibling outside the cycle still refuses":
    let fx = setup("unrelated")
    defer: fx.release()
    let otherHead = fx.commitFile(fx.dir("other"), "work.txt", "other\n",
      "other: unpublished work")
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check gateRefused(core.output, "flake_lock_stale", "core")
    check "input=other-src" in core.output
    check "unpublished=true" in core.output
    check "DEFERRED" notin core.output
    # Unchanged remedy: `other` can be published first, so its push is named.
    check ("git -C " & fx.dir("other") & " push origin " & otherHead) in
      core.output

  test "a lag behind a published sibling still refuses":
    let fx = setup("published")
    defer: fx.release()
    discard fx.commitFile(fx.dir("app"), "work.txt", "app\n", "app work")
    discard fx.gitIn(fx.dir("app"), "push -q origin HEAD:main")
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    fx.substituteAppInCore()
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check gateRefused(core.output, "flake_lock_stale", "core")
    check "input=app-src" in core.output
    check "relation=ahead" in core.output
    check "unpublished=true" notin core.output
    check "DEFERRED" notin core.output

  test "behind and diverged cyclic siblings still refuse":
    let fx = setup("behind-diverged")
    defer: fx.release()
    # BEHIND: the pin names a newer published `app` revision than the checkout.
    let newer = fx.commitFile(fx.dir("app"), "work.txt", "app 2\n", "app 2")
    discard fx.gitIn(fx.dir("app"), "push -q origin HEAD:main")
    discard fx.gitIn(fx.dir("app"), "reset -q --hard " & fx.seedOf("app"))
    fx.writeCoreFlake(newer, fx.seedOf("other"))
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    fx.substituteAppInCore()
    fx.installHooks()
    let behind = fx.rawPush("core")
    checkpoint("behind:\n" & behind.output)
    check behind.code != 0
    check gateRefused(behind.output, "flake_lock_stale", "core")
    check "relation=behind" in behind.output
    check "DEFERRED" notin behind.output
    # DIVERGED: an unpublished `app` commit off the seed, pin on `newer`.
    discard fx.commitFile(fx.dir("app"), "side.txt", "side\n", "app side")
    let diverged = fx.rawPush("core")
    checkpoint("diverged:\n" & diverged.output)
    check diverged.code != 0
    check gateRefused(diverged.output, "flake_lock_stale", "core")
    check "relation=diverged" in diverged.output
    check "DEFERRED" notin diverged.output
    # `app` depends on `core`, so `app`'s push is blocked until this one lands
    # and must not be the remedy.
    check ("git -C " & fx.dir("app") & " push") notin diverged.output

  test "an ahead cyclic sibling whose pin is unpublished still refuses":
    let fx = setup("unpublished-pin")
    defer: fx.release()
    let localPin = fx.commitFile(fx.dir("app"), "work.txt", "app 2\n",
      "app: never pushed")
    discard fx.commitFile(fx.dir("app"), "work.txt", "app 3\n", "app: ahead")
    fx.writeCoreFlake(localPin, fx.seedOf("other"))
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    fx.substituteAppInCore()
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check gateRefused(core.output, "flake_lock_stale", "core")
    check "relation=ahead" in core.output
    check "DEFERRED" notin core.output
    check ("git -C " & fx.dir("app") & " push") notin core.output

  test "a cyclic pin still refuses once the pushed HEAD is already published":
    let fx = setup("self-published")
    defer: fx.release()
    # `core`'s HEAD is already on its remote (another branch), so `app`'s own
    # gate no longer refuses over `core` and `app` CAN be published first: the
    # cycle is not there, and the ordinary refusal and remedy apply.
    let heads = fx.arrangeTheDeadlock()
    discard fx.gitIn(fx.dir("core"), "push -q origin HEAD:refs/heads/side")
    fx.substituteAppInCore()
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check gateRefused(core.output, "flake_lock_stale", "core")
    check "input=app-src" in core.output
    check "DEFERRED" notin core.output
    check ("git -C " & fx.dir("app") & " push origin " & heads.app) in
      core.output

  test "repro push publishes a develop override its own gate requires":
    let fx = setup("override")
    defer: fx.release()
    # `other` is NOT in `lib`'s `depends` closure, but it is a develop override,
    # and the gate refuses over every override (stage 3).
    let otherHead = fx.commitFile(fx.dir("other"), "work.txt", "other\n",
      "other: unpublished override work")
    # `core`'s flake also pins `other`; record the override's HEAD there so the
    # flake stage agrees and this case isolates stage 3 (the override file).
    fx.writeCoreFlake(fx.seedOf("app"), otherHead)
    let coreHead = fx.commitFile(fx.dir("core"), "work.txt", "core\n",
      "core work")
    let libHead = fx.commitFile(fx.dir("lib"), "work.txt", "lib\n", "lib work")
    var overrides = newDevelopOverrides()
    overrides = addOverride(overrides, DevelopOverrideEntry(package: "other",
      local_path: fx.dir("other"), state: "editable",
      created_at: "2026-10-16T00:00:00Z"))
    writeDevelopOverridesFile(fx.workspace, overrides)
    fx.installHooks()
    # Explicit locations, so this case isolates the override rule from the
    # workspace-root rule the first case covers.
    let pushed = fx.reproPush("lib", explicit = true)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.remoteHead("other") == otherHead
    check fx.remoteHead("core") == coreHead
    check fx.remoteHead("lib") == libHead
    # FIRST, not merely before `lib`: stage 3 reads the whole override file, so
    # `core`'s own gate refuses too while `other` is unpublished.
    check fx.pushReport().orderOf() == @["other", "core", "lib"]

suite "mutually pinned repro.lock siblings (stage 3c) land through repro push":

  test "raw core push defers a cyclic repro.lock pin and repro push lands both":
    let fx = setup("lock-cycle")
    defer: fx.release()
    fx.pinLibInCoreLock(fx.seedOf("lib"))
    let coreHead = fx.commitFile(fx.dir("core"), "work.txt", "core\n",
      "core: unpublished work")
    let libHead = fx.commitFile(fx.dir("lib"), "work.txt", "lib\n",
      "lib: unpublished work ahead of core's pin")
    fx.installHooks()
    # The dependent first: refused over core (invariant 2).
    let libFirst = fx.rawPush("lib")
    checkpoint("raw lib push:\n" & libFirst.output)
    check libFirst.code != 0
    check gateRefused(libFirst.output, "unpublished", "core")
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code == 0
    check not gateRefused(core.output, "committed_lock_sibling_pin_stale",
      "core")
    check "repro.lock pin DEFERRED" in core.output
    check "deferred=mutual-pin" in core.output
    check ("repro push --current-repo=" & fx.dir("lib")) in core.output
    check fx.remoteHead("core") == coreHead
    let lib = fx.rawPush("lib")
    checkpoint("raw lib push after core:\n" & lib.output)
    check lib.code == 0
    check fx.remoteHead("lib") == libHead

  test "repro push from the dependent lands a cyclic repro.lock pin":
    let fx = setup("lock-cycle-push")
    defer: fx.release()
    fx.pinLibInCoreLock(fx.seedOf("lib"))
    let coreHead = fx.commitFile(fx.dir("core"), "work.txt", "core\n",
      "core: unpublished work")
    let libHead = fx.commitFile(fx.dir("lib"), "work.txt", "lib\n",
      "lib: unpublished work ahead of core's pin")
    fx.installHooks()
    let pushed = fx.reproPush("lib", explicit = true)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.remoteHead("core") == coreHead
    check fx.remoteHead("lib") == libHead
    check fx.pushReport().orderOf() == @["core", "lib"]

  test "a repro.lock pin of an unpublished non-cyclic sibling still refuses":
    let fx = setup("lock-unrelated", libDependsOnCore = false)
    defer: fx.release()
    fx.pinLibInCoreLock(fx.seedOf("lib"))
    discard fx.commitFile(fx.dir("lib"), "work.txt", "lib\n", "lib work")
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check gateRefused(core.output, "committed_lock_sibling_pin_stale", "core")
    check "DEFERRED" notin core.output
    check ("repro lock refresh " & fx.dir("core")) in core.output

  test "a repro.lock pin of a published cyclic sibling still refuses":
    let fx = setup("lock-published")
    defer: fx.release()
    fx.pinLibInCoreLock(fx.seedOf("lib"))
    discard fx.commitFile(fx.dir("lib"), "work.txt", "lib\n", "lib work")
    discard fx.gitIn(fx.dir("lib"), "push -q origin HEAD:main")
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check gateRefused(core.output, "committed_lock_sibling_pin_stale", "core")
    check "(ahead)" in core.output
    check "DEFERRED" notin core.output
    check ("repro lock refresh " & fx.dir("core")) in core.output

  test "a cyclic repro.lock pin still refuses once the pushed HEAD is published":
    let fx = setup("lock-self-published")
    defer: fx.release()
    fx.pinLibInCoreLock(fx.seedOf("lib"))
    discard fx.commitFile(fx.dir("lib"), "work.txt", "lib\n", "lib work")
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    discard fx.gitIn(fx.dir("core"), "push -q origin HEAD:refs/heads/side")
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check gateRefused(core.output, "committed_lock_sibling_pin_stale", "core")
    check "DEFERRED" notin core.output
    check ("repro lock refresh " & fx.dir("core")) in core.output

  test "a repro.lock pin a cyclic sibling is behind still refuses":
    let fx = setup("lock-behind")
    defer: fx.release()
    let newer = fx.commitFile(fx.dir("lib"), "work.txt", "lib 2\n", "lib 2")
    discard fx.gitIn(fx.dir("lib"), "push -q origin HEAD:main")
    discard fx.gitIn(fx.dir("lib"), "reset -q --hard " & fx.seedOf("lib"))
    fx.pinLibInCoreLock(newer)
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check gateRefused(core.output, "committed_lock_sibling_pin_stale", "core")
    check "(behind)" in core.output
    check "DEFERRED" notin core.output

suite "develop overrides and worktrees land through repro push":

  test "two unpublished develop overrides land through repro push":
    # Each override's gate refuses over every OTHER unpublished override
    # (stage 3), so without the deferral no order of pushes passes.
    let fx = setup("two-overrides")
    defer: fx.release()
    let otherHead = fx.commitFile(fx.dir("other"), "work.txt", "other\n",
      "other: unpublished override")
    let extraHead = fx.commitFile(fx.dir("extra"), "work.txt", "extra\n",
      "extra: unpublished override")
    # `core`'s flake pins `other`; record its HEAD so stage 3b agrees.
    fx.writeCoreFlake(fx.seedOf("app"), otherHead)
    let coreHead = fx.commitFile(fx.dir("core"), "work.txt", "core\n",
      "core work")
    fx.registerOverrides(["other", "extra"])
    fx.installHooks()
    let pushed = fx.reproPush("core", explicit = true)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.remoteHead("other") == otherHead
    check fx.remoteHead("extra") == extraHead
    check fx.remoteHead("core") == coreHead
    let order = fx.pushReport().orderOf()
    check order.len == 3 and order[^1] == "core"

  test "an override whose depends reaches a closure member lands":
    # `extra` depends on `core`, which is in `app`'s closure: `core`'s gate
    # refuses over the unpublished override, and `extra`'s gate refuses until
    # `core` is published.
    let fx = setup("override-depends", extraDependsOnCore = true)
    defer: fx.release()
    let heads = fx.arrangeTheDeadlock()
    let extraHead = fx.commitFile(fx.dir("extra"), "work.txt", "extra\n",
      "extra: unpublished override depending on core")
    fx.registerOverrides(["extra"])
    fx.installHooks()
    let pushed = fx.reproPush("app", explicit = true)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.remoteHead("core") == heads.core
    check fx.remoteHead("extra") == extraHead
    check fx.remoteHead("app") == heads.app
    check fx.pushReport().orderOf() == @["core", "extra", "lib", "app"]

  test "an override that depends on the pushed repo lands after it":
    # `app` (an override) depends on `lib`, the pushed repo.
    let fx = setup("override-on-pushed")
    defer: fx.release()
    let heads = fx.arrangeTheDeadlock()
    fx.registerOverrides(["app"])
    fx.installHooks()
    let pushed = fx.reproPush("lib", explicit = true)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.remoteHead("core") == heads.core
    check fx.remoteHead("lib") == heads.lib
    check fx.remoteHead("app") == heads.app
    check fx.pushReport().orderOf() == @["core", "lib", "app"]

  test "raw push of one of two unpublished overrides defers the other":
    # The gate's own output: the deferral is a NOTICE naming the order.
    let fx = setup("two-overrides-raw")
    defer: fx.release()
    let otherHead = fx.commitFile(fx.dir("other"), "work.txt", "other\n",
      "other: unpublished override")
    discard fx.commitFile(fx.dir("extra"), "work.txt", "extra\n",
      "extra: unpublished override")
    fx.registerOverrides(["other", "extra"])
    fx.installHooks()
    let other = fx.rawPush("other")
    checkpoint("raw other push:\n" & other.output)
    check other.code == 0
    check fx.remoteHead("other") == otherHead
    check "develop override DEFERRED" in other.output
    check "deferred=override-awaits-push" in other.output
    check ("repro push --current-repo=" & fx.dir("extra")) in other.output
    let extra = fx.rawPush("extra")
    checkpoint("raw extra push:\n" & extra.output)
    check extra.code == 0

  test "an unpublished override the pushed repo does not block still refuses":
    # `core` is no override and `other` does not depend on it, so `other` CAN
    # be published first: the gate keeps refusing, as before.
    let fx = setup("override-unrelated")
    defer: fx.release()
    discard fx.commitFile(fx.dir("extra"), "work.txt", "extra\n",
      "extra: unpublished override")
    discard fx.commitFile(fx.dir("core"), "work.txt", "core\n", "core work")
    fx.registerOverrides(["extra"])
    fx.installHooks()
    let core = fx.rawPush("core")
    checkpoint("raw core push:\n" & core.output)
    check core.code != 0
    check "develop_override_unpublished" in core.output
    check "DEFERRED" notin core.output

  test "repro push from a linked worktree publishes that worktree's closure":
    # A linked worktree of `lib` inside the workspace but not at the declared
    # path: the gate identifies it by its git common directory, so `repro push`
    # (typed in the worktree, no location flags) must too.
    let fx = setup("linked-worktree")
    defer: fx.release()
    let coreHead = fx.commitFile(fx.dir("core"), "work.txt", "core\n",
      "core work")
    let wt = fx.workspace / "lib-feature"
    discard fx.gitIn(fx.dir("lib"), "worktree add -q -b feature " & q(wt))
    let wtHead = fx.commitFile(wt, "work.txt", "lib feature\n",
      "lib: feature work in a linked worktree")
    # `extra`, not `other`: `core`'s flake pins `other`, so unpublished work
    # there would (rightly) stop `core` at the flake stage.
    let extraHead = fx.commitFile(fx.dir("extra"), "unrelated.txt", "x\n",
      "extra: unrelated unpublished work")
    fx.installHooks()
    let pushed = runShell(shellCommand(@[fx.repro, "push", "--no-certify",
      "--write-report"]), cwd = wt)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.pushReport().orderOf() == @["core", "lib"]
    check fx.remoteHead("core") == coreHead
    # Not `gitIn`: an absent branch is a FAILED check, not a fixture abort.
    check run(q(fx.git) & " -C " & q(fx.bare("lib")) &
      " rev-parse --verify -q refs/heads/feature").output.strip() == wtHead
    # The unrelated repo is outside the closure and must not be published.
    check fx.remoteHead("extra") != extraHead

  test "repro push from a worktree outside the workspace lands it through its gate":
    # A linked worktree parked OUTSIDE the workspace directory. Its managed
    # pre-push hook finds the workspace by following the worktree's git common
    # directory back to `lib` (`enclosingWorkspaceRoot`, reprobuild 37946561),
    # so the gate ENFORCES there, and `repro push` publishes the closure as it
    # does from any other checkout of `lib` (CLI/push.md §"Scope"). Both halves
    # are asserted: without the first, a push that lands could be one nothing
    # gated, which is the state the push-side stop existed to prevent.
    let fx = setup("outside-worktree")
    defer: fx.release()
    let coreHead = fx.commitFile(fx.dir("core"), "work.txt", "core\n",
      "core work")
    let wt = fx.scratch / "lib-outside"
    discard fx.gitIn(fx.dir("lib"), "worktree add -q -b outside " & q(wt))
    let wtHead = fx.commitFile(wt, "work.txt", "lib outside\n", "lib: outside")
    let extraHead = fx.commitFile(fx.dir("extra"), "unrelated.txt", "x\n",
      "extra: unrelated unpublished work")
    fx.installHooks()
    # 1. The hook gates the outside worktree: `lib` depends on `core`, whose
    #    HEAD is unpublished, so a raw push from there is refused by the gate
    #    rather than no-oped as "not a workspace".
    let raw = run(q(fx.git) & " -C " & q(wt) & " push origin HEAD:outside")
    checkpoint("raw push output:\n" & raw.output)
    check raw.code != 0
    check not raw.output.contains("not a workspace")
    # The refusal is the gate's own verdict on the closure, not some other
    # failure of the push: the gate ran, and it named `core` as unpublished.
    check raw.output.contains("mode=pre-push")
    check raw.output.contains("core: unpublished")
    check run(q(fx.git) & " -C " & q(fx.bare("lib")) &
      " rev-parse --verify -q refs/heads/outside").code != 0
    # 2. `repro push` publishes the closure in order, the worktree's own branch
    #    included, and nothing outside it.
    let pushed = runShell(shellCommand(@[fx.repro, "push", "--no-certify",
      "--write-report", "--workspace-root=" & fx.workspace,
      "--current-repo=" & wt]), cwd = wt)
    checkpoint("repro push output:\n" & pushed.output)
    check pushed.code == 0
    check fx.pushReport().orderOf() == @["core", "lib"]
    check fx.remoteHead("core") == coreHead
    check run(q(fx.git) & " -C " & q(fx.bare("lib")) &
      " rev-parse --verify -q refs/heads/outside").output.strip() == wtHead
    check fx.remoteHead("extra") != extraHead

  test "an override the pushed repo's flake.lock pins at its unpublished HEAD still refuses":
    # `core` and `other` are both unpublished overrides, so the deferral's
    # other conditions hold — but `core`'s flake.lock names `other`'s HEAD,
    # which stage 3b sees as agreeing. Deferring would publish a lock nobody
    # can fetch; publishing `other` first is the order that works.
    let fx = setup("override-flake-pinned")
    defer: fx.release()
    let otherHead = fx.commitFile(fx.dir("other"), "work.txt", "other\n",
      "other: unpublished override")
    fx.writeCoreFlake(fx.seedOf("app"), otherHead)
    let coreHead = fx.commitFile(fx.dir("core"), "work.txt", "core\n",
      "core: unpublished override pinning other")
    fx.registerOverrides(["other", "core"])
    fx.installHooks()
    let coreFirst = fx.rawPush("core")
    checkpoint("raw core push:\n" & coreFirst.output)
    check coreFirst.code != 0
    check gateRefused(coreFirst.output, "develop_override_unpublished", "other")
    check "DEFERRED" notin coreFirst.output
    check fx.remoteHead("core") != coreHead
    let other = fx.rawPush("other")
    checkpoint("raw other push:\n" & other.output)
    check other.code == 0
    check fx.remoteHead("other") == otherHead
    let core = fx.rawPush("core")
    checkpoint("raw core push after other:\n" & core.output)
    check core.code == 0
    check fx.remoteHead("core") == coreHead

  test "an override the pushed repo's repro.lock pins at its unpublished HEAD still refuses":
    let fx = setup("override-lock-pinned")
    defer: fx.release()
    let extraHead = fx.commitFile(fx.dir("extra"), "work.txt", "extra\n",
      "extra: unpublished override")
    writeFile(fx.dir("core") / "repro.lock", committedLock(@[
      fx.lockDep("core", ".", "0000000000000000000000000000000000000001", ""),
      fx.lockDep("extra", "../extra", extraHead, "")]))
    let coreHead = fx.commitFile(fx.dir("core"), "work.txt", "core\n",
      "core: unpublished override pinning extra")
    fx.registerOverrides(["extra", "core"])
    fx.installHooks()
    let coreFirst = fx.rawPush("core")
    checkpoint("raw core push:\n" & coreFirst.output)
    check coreFirst.code != 0
    check gateRefused(coreFirst.output, "develop_override_unpublished", "extra")
    check "DEFERRED" notin coreFirst.output
    check fx.remoteHead("core") != coreHead
