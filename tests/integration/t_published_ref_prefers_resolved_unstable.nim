## A committed lock's advisory `ref` prefers the repo's resolved `unstable`
## branch, then its resolved `mainline` branch — from the manifest's branch
## roles, with no branch name compiled into `repro` (Workspace-Branch-Roles.md
## §5 and §9, `published_ref_prefers_resolved_unstable`; Unified-Locking-And-
## Hooks.md §14.2).
##
## WHY. The preference used to be the constant `["agents", "dev"]`: one
## organisation's branch policy compiled into a generic tool. A workspace
## whose fresher branch is `edge` or whose mainline is `trunk` got no benefit
## from it, and a repo whose commit also sat on an unrelated `agents` branch
## recorded that. Every role name below is deliberately NOT `agents` or `dev`,
## and every commit the preference must pass over IS also on `agents` and
## `dev`, so a compiled-in preference cannot pass any case by accident.
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## (app → lib-b → lib-c) of real git repositories cloned from real bare
## origins, refreshed with the built `repro`; plus a standalone repository and
## the workspace ROOT made a git repository of its own.
##
## Cases:
##   * PRIMARY — lib-b's repo.v2 fragment declares `unstable = "edge"`,
##     `mainline = "trunk"`; its new commit is on `main`, `agents`, `dev`,
##     `trunk` and `edge` → `ref = "edge"`;
##   * the same repo's next commit is on everything but `edge` → `trunk` (the
##     resolved mainline is second);
##   * lib-c declares neither, but names a PROFILE declaring
##     `unstable = "canary"` → `canary`;
##   * the workspace ROOT repository resolves its roles from the settings
##     file's `[workspace]` (§3.4): `unstable = "edge"` → `edge`; a
##     `[records] branch` (`trunk`, even with the root as the store) is the
##     store's and no role of the root, so it is not preferred — the `ref`
##     falls to the remaining order (the checkout's own branch, `main`);
##   * NO RESOLUTION — a standalone repository with no workspace manifest and
##     no settings file prefers no branch by role: its commit is on `agents`,
##     `dev` and its own published branch `work`, and the `ref` is `work`, by
##     the remaining order (the checkout's own branch first).
##
## Mutation-checked: reinstating the compiled-in `["agents", "dev"]` ahead of
## the resolved roles in `committedLockRepoFactsPreferring` records
## `ref = "agents"` and fails the PRIMARY case on
## `check refOf(body, "lib-b") == "edge"`.
##
## NO MOCKS: real repositories, the real manifest and settings readers, the
## real `repro lock refresh`.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support
import ./committed_lock_siblings_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc field(entry, key: string): string =
  let k = key & " = \""
  let at = entry.find(k)
  if at < 0: return "<absent>"
  let stop = entry.find('"', at + k.len)
  entry[at + k.len ..< stop]

proc pinOf(lockBody, name: string): string =
  field(depEntry(lockBody, name), "revision")

proc refOf(lockBody, name: string): string =
  field(depEntry(lockBody, name), "ref")

proc refresh(fx: SiblingFixture; target: string):
    tuple[code: int; output: string] =
  ## `repro lock refresh <target>`, with `REPRO_ALLOW_PIN_REGRESSION` cleared
  ## so a value exported in the suite's environment cannot leak in; every case
  ## moves its repo forward.
  runCmd(AllowEnv & "= " & q(fx.repro) & " lock refresh " & q(target) &
    " 2>&1")

proc publishTo(fx: SiblingFixture; repo: string; branches: openArray[string]) =
  ## Push HEAD of `repo` to each of `branches` on `origin`, and fetch back, so
  ## the remote-tracking refs the writer reads contain it.
  var specs: seq[string]
  for b in branches: specs.add(q("HEAD:refs/heads/" & b))
  discard fx.git(repo, "push -q -f origin " & specs.join(" "))
  discard fx.git(repo, "fetch -q origin")

proc commitIn(fx: SiblingFixture; repo, label: string): string =
  writeFile(repo / "role-ref.txt", label & "\n")
  discard fx.git(repo, "add role-ref.txt")
  discard fx.git(repo, "commit -q -m " & q(label))
  fx.headOf(repo)

proc v2Fragment(name, keys: string; depends: seq[string]): string =
  result = "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\n" & keys
  if depends.len > 0:
    result.add("depends = [\"" & depends.join("\", \"") & "\"]\n")

const SettingsV1 = "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
  "[workspace]\nmainline = \"main\"\nunstable = \"edge\"\n\n" &
  "[profiles.flow]\nmainline = \"main\"\nunstable = \"canary\"\n"

suite "a committed lock's ref prefers the resolved unstable branch":

  test "published_ref_prefers_resolved_unstable":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      var fx = setupSiblingFixture("role-ref")
      defer: removeDir(fx.scratch)
      let libB = fx.ws / "lib-b"
      let libC = fx.ws / "lib-c"
      writeFile(fx.ws / "repro-workspace.toml", SettingsV1)
      writeFile(fx.ws / "repos" / "lib-b.toml", v2Fragment("lib-b",
        "mainline = \"trunk\"\nunstable = \"edge\"\nrevision = \"main\"\n",
        @["lib-c"]))
      writeFile(fx.ws / "repos" / "lib-c.toml", v2Fragment("lib-c",
        "profile = \"flow\"\nrevision = \"main\"\n", @[]))
      fx.refreshAndPublishLock()

      # PRIMARY: the resolved `unstable` wins over every other branch that
      # contains the commit — `agents` and `dev` included.
      let first = fx.advance("lib-b")
      fx.publishTo(libB, ["agents", "dev", "trunk", "edge"])
      var r = fx.refresh(fx.app)
      checkpoint(r.output)
      check r.code == 0
      var body = readFile(fx.app / "repro.lock")
      checkpoint(body)
      check pinOf(body, "lib-b") == first
      check refOf(body, "lib-b") == "edge"

      # Not on `edge`: the resolved `mainline` is next.
      let second = fx.advance("lib-b")
      fx.publishTo(libB, ["agents", "dev", "trunk"])
      r = fx.refresh(fx.app)
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.app / "repro.lock")
      check pinOf(body, "lib-b") == second
      check refOf(body, "lib-b") == "trunk"

      # A role the fragment does not declare, supplied by its profile.
      let third = fx.advance("lib-c")
      fx.publishTo(libC, ["agents", "dev", "canary"])
      r = fx.refresh(fx.app)
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.app / "repro.lock")
      check pinOf(body, "lib-c") == third
      check refOf(body, "lib-c") == "canary"

  test "the workspace root repository prefers its declared roles":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      var fx = setupSiblingFixture("role-ref-root")
      defer: removeDir(fx.scratch)
      # The ROOT becomes a published repository of its own, with the solver
      # inputs a lock refresh needs, its members ignored.
      let rootOrigin = fx.scratch / "origin-root.git"
      discard requireCmd(q(fx.gitBin) & " init --bare -b main " &
        q(rootOrigin))
      discard requireCmd(q(fx.gitBin) & " init -q -b main " & q(fx.ws))
      discard fx.git(fx.ws, "config user.email tester@example.invalid")
      discard fx.git(fx.ws, "config user.name \"Lock Tester\"")
      discard fx.git(fx.ws, "config commit.gpgsign false")
      discard fx.git(fx.ws, "remote add origin " & q(fileUrl(rootOrigin)))
      writeFile(fx.ws / ".gitignore",
        "/.repro/\n/app/\n/lib-b/\n/lib-c/\n/lib-d/\n")
      copyFile(fx.app / "repro.solver", fx.ws / "repro.solver")
      writeFile(fx.ws / "repro-workspace.toml", SettingsV1)
      discard fx.git(fx.ws, "add -A")
      discard fx.git(fx.ws, "commit -q -m seed")
      discard fx.git(fx.ws, "push -q origin main")

      # settings.v1: `[workspace] unstable = "edge"`.
      let first = fx.commitIn(fx.ws, "root on edge")
      fx.publishTo(fx.ws, ["main", "agents", "dev", "edge"])
      var r = fx.refresh(fx.ws)
      checkpoint(r.output)
      check r.code == 0
      var body = readFile(fx.ws / "repro.lock")
      checkpoint(body)
      check pinOf(body, ".") == first
      check refOf(body, ".") == "edge"

      # `[records]` naming the root itself on `trunk`, and no `[workspace]`
      # roles: the store's branch is not the root's mainline, so nothing is
      # preferred by role and the checkout's own published branch wins.
      removeFile(fx.ws / "repro-workspace.toml")
      writeFile(fx.ws / "repro-workspace.toml",
        "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
        "[records]\nurl = \"" & fileUrl(rootOrigin) & "\"\n" &
        "branch = \"trunk\"\n")
      discard fx.git(fx.ws, "add -A")
      let second = fx.commitIn(fx.ws, "root on trunk")
      fx.publishTo(fx.ws, ["main", "agents", "dev", "edge", "trunk"])
      r = fx.refresh(fx.ws)
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.ws / "repro.lock")
      check pinOf(body, ".") == second
      check refOf(body, ".") != "trunk"
      check refOf(body, ".") == "main"

  test "with no declared roles no branch is preferred by name":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      var fx = setupSiblingFixture("role-ref-none")
      defer: removeDir(fx.scratch)
      # A standalone repository: no workspace manifest, no settings file.
      let origin = fx.scratch / "origin-solo.git"
      let solo = fx.scratch / "solo"
      discard requireCmd(q(fx.gitBin) & " init --bare -b main " & q(origin))
      discard requireCmd(q(fx.gitBin) & " clone -q " & q(fileUrl(origin)) &
        " " & q(solo))
      discard fx.git(solo, "config user.email tester@example.invalid")
      discard fx.git(solo, "config user.name \"Lock Tester\"")
      discard fx.git(solo, "config commit.gpgsign false")
      copyFile(fx.app / "repro.solver", solo / "repro.solver")
      writeFile(solo / ".gitignore", ".repro/\n")
      discard fx.git(solo, "add -A")
      discard fx.git(solo, "commit -q -m seed")
      discard fx.git(solo, "push -q origin main")
      discard fx.git(solo, "checkout -q -b work")
      let head = fx.commitIn(solo, "work")
      fx.publishTo(solo, ["agents", "dev", "work"])
      let r = fx.refresh(solo)
      checkpoint(r.output)
      check r.code == 0
      let body = readFile(solo / "repro.lock")
      checkpoint(body)
      check pinOf(body, ".") == head
      check refOf(body, ".") == "work"
