## ``repro health`` looks for a project's siblings where they are, and
## ``--fix`` clones only into the workspace it was run for.
##
## The layout this protects (CLI/health.md §"Dependencies / siblings";
## Workspace-Manifests.md §"The locked-dependency model", the placement rule):
##
## ```
## <home>/                       a workspace root: settings, state, repos/*.toml
## <home>/m/dev/                 a plain directory, no workspace markers
## <home>/m/dev/app/             a checkout with a committed repro.lock
## <home>/m/dev/lib-a, lib-b/    its siblings, the one-level `../<name>` layout
## ```
##
## ``repro health`` run in ``<home>/m/dev/app`` resolves the project from that
## checkout's committed lock and places every locked dependency by the one
## placement rule. That rule consults "the enclosing workspace's declared
## membership", and the nearest marked ancestor here is ``<home>``, a
## workspace the checkout is NOT a member of (it declares ``app`` at
## ``<home>/app``). Consulting it anyway put each sibling at ``<home>/<name>``:
## the row reported ``missing checkouts: ../../../lib-a, ../../../lib-b`` while
## both sat next to the checkout, and ``--fix`` cloned them into ``<home>``.
## Measured on a workstation, where the outer workspace was the home directory
## and the clones (nearly a gigabyte) landed there.
##
## What is asserted:
##
##   1. a checkout that is not a member of the workspace above it finds its
##      siblings at ``../<name>``: the row is ``ok`` and ``--fix`` creates
##      nothing in the outer workspace;
##   2. a checkout that IS a declared member still has its siblings placed by
##      that membership (a path that differs from the name is followed), so the
##      condition in (1) does not switch the membership rule off;
##   3. a sibling that is really missing is cloned where it belongs, and the
##      plan and the clone line name that absolute directory;
##   4. a destination outside the workspace (here a develop override naming a
##      directory elsewhere) is refused by ``--fix``, naming the directory,
##      and nothing is created there;
##   5. the outer workspace's develop overrides do not place a non-member's
##      siblings either (they speak for that workspace's checkouts only);
##   6. membership still applies to a checkout some fragment declares although
##      no enabled project includes it, and to a nested ``deps/<name>``
##      checkout inside a member;
##   7. a project checkout that carries a workspace state file of its own is
##      still a committed-lock-only workspace: its ``../<name>`` siblings are
##      cloned, not refused.
##
## Test doubles: none. The production ``repro`` binary, real git, real bare
## origins reached by ``file://`` URLs, and a hand-written committed lock in
## the ``reprobuild.solved-graph-lock.v3`` format.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[output: string; code: int] =
  let res = execCmdEx(command, workingDir = cwd)
  (res.output, res.exitCode)

proc requireOk(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code & "\n" &
      res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const repoNames = ["app", "lib-a", "lib-b"]

type Fixture = object
  gitBin: string
  scratch: string
  home: string          ## the outer workspace root
  dev: string           ## the plain directory holding the checkouts
  shas: seq[string]

proc originUrl(fx: Fixture; name: string): string =
  fileUrl(fx.scratch / ("origin-" & name & ".git"))

proc git(fx: Fixture; args: string; cwd = ""): string =
  requireOk(q(fx.gitBin) & " " & args, cwd)

proc seedOrigin(fx: var Fixture; name: string) =
  let origin = fx.scratch / ("origin-" & name & ".git")
  let seed = fx.scratch / ("seed-" & name)
  discard fx.git("init -q --bare -b main " & q(origin))
  discard fx.git("init -q -b main " & q(seed))
  discard fx.git("-C " & q(seed) & " config user.email t@example.invalid")
  discard fx.git("-C " & q(seed) & " config user.name \"Sibling Tester\"")
  writeFile(seed / "README.md", name & "\n")
  discard fx.git("-C " & q(seed) & " add README.md")
  discard fx.git("-C " & q(seed) & " commit -q -m seed")
  discard fx.git("-C " & q(seed) & " push -q " & q(origin) & " main")
  fx.shas.add(fx.git("-C " & q(seed) & " rev-parse HEAD").strip())

proc lockDep(fx: Fixture; i: int; self: bool; depends: string): string =
  let name = repoNames[i]
  "{ name = \"" & name & "\", " & (if self: "self = \"true\", " else: "") &
    "coord_kind = \"vcs\", url = \"" & fx.originUrl(name) &
    "\", revision = \"" & fx.shas[i] & "\", integrity = \"git-sha1:" &
    fx.shas[i] & "\", version = \"\", visibility = \"public\", " &
    "participation = \"\", depends = \"" & depends & "\", tags = \"\" }"

proc committedLock(fx: Fixture): string =
  "schema = \"reprobuild.solved-graph-lock.v3\"\n\n[lock]\ndeps = [" &
    fx.lockDep(0, true, "lib-a,lib-b") & ", " & fx.lockDep(1, false, "") &
    ", " & fx.lockDep(2, false, "") & "]\n"

proc writeOuterWorkspace(fx: Fixture; paths: openArray[string];
    activeOnly: openArray[string] = []) =
  ## ``<home>`` as a declared workspace whose project ``app`` places
  ## ``repoNames[i]`` at ``paths[i]``. ``activeOnly`` non-empty enables a
  ## project ``other`` that includes only those repositories instead.
  createDir(fx.home / "projects")
  createDir(fx.home / "repos")
  createDir(fx.home / ".repro")
  var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"app\"\n\n"
  for name in repoNames:
    project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fx.originUrl(name) & "\"\n\n")
  project.add("includes = [\"repos/app.toml\", \"repos/lib-a.toml\", " &
    "\"repos/lib-b.toml\"]\n")
  writeFile(fx.home / "projects" / "app.toml", project)
  for i, name in repoNames:
    writeFile(fx.home / "repos" / (name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" &
      name & "\"\npath = \"" & paths[i] & "\"\nremote = \"" & name &
      "-origin\"\nmainline = \"main\"\n")
  var active = "app"
  if activeOnly.len > 0:
    active = "other"
    var other = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "[project]\nname = \"other\"\n\n"
    var includes: seq[string]
    for name in activeOnly:
      other.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
        fx.originUrl(name) & "\"\n\n")
      includes.add("\"repos/" & name & ".toml\"")
    other.add("includes = [" & includes.join(", ") & "]\n")
    writeFile(fx.home / "projects" / "other.toml", other)
  writeFile(fx.home / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n[workspace]\n" &
    "project = \"" & active & "\"\n")

proc cloneApp(fx: Fixture; dest: string) =
  ## A checkout of ``app`` carrying the committed lock, committed.
  discard fx.git("clone -q " & q(fx.originUrl("app")) & " " & q(dest))
  discard fx.git("-C " & q(dest) & " config user.email t@example.invalid")
  discard fx.git("-C " & q(dest) & " config user.name \"Sibling Tester\"")
  writeFile(dest / "repro.lock", fx.committedLock())
  discard fx.git("-C " & q(dest) & " add repro.lock")
  discard fx.git("-C " & q(dest) & " commit -q -m lock")

proc cloneSibling(fx: Fixture; name, dest: string) =
  discard fx.git("clone -q " & q(fx.originUrl(name)) & " " & q(dest))

proc setupFixture(prefix: string): Fixture =
  result.gitBin = findExe("git")
  result.scratch = createTempDir(prefix, "")
  result.home = result.scratch / "home"
  result.dev = result.home / "m" / "dev"
  createDir(result.dev)
  for name in repoNames:
    result.seedOrigin(name)

proc health(fx: Fixture; root: string; fix: bool):
    tuple[output: string; code: int] =
  run(q(reproBinary()) & " health --offline" & (if fix: " --fix" else: "") &
    " --workspace-root=" & q(root) & " 2>&1", root)

proc siblingsRow(output: string): string =
  for line in output.splitLines():
    if line.startsWith("siblings "):
      return line
  ""

suite "repro health places missing siblings where the workspace has them":

  test "a checkout outside the workspace above it finds its ../ siblings":
    if findExe("git").len == 0:
      skip("git not on PATH; this case builds real repositories")
    else:
      let fx = setupFixture("repro-health-sib-outer-")
      defer: removeDir(fx.scratch)
      fx.writeOuterWorkspace(["app", "lib-a", "lib-b"])
      let app = fx.dev / "app"
      fx.cloneApp(app)
      fx.cloneSibling("lib-a", fx.dev / "lib-a")
      fx.cloneSibling("lib-b", fx.dev / "lib-b")

      let diag = fx.health(app, fix = false)
      checkpoint("health:\n" & diag.output)
      let row = siblingsRow(diag.output)
      check row.len > 0
      check " ok " in row
      check "../../../" notin diag.output

      let fixed = fx.health(app, fix = true)
      checkpoint("health --fix:\n" & fixed.output)
      check siblingsRow(fixed.output).len > 0
      check "cloning missing sibling" notin fixed.output
      # Nothing was cloned into the workspace the checkout does not belong to.
      check not dirExists(fx.home / "lib-a")
      check not dirExists(fx.home / "lib-b")

  test "a declared member's siblings are still placed by the membership":
    if findExe("git").len == 0:
      skip("git not on PATH; this case builds real repositories")
    else:
      let fx = setupFixture("repro-health-sib-member-")
      defer: removeDir(fx.scratch)
      # lib-a's declared path differs from its name: only the membership
      # says it is under libs/.
      fx.writeOuterWorkspace(["app", "libs/lib-a", "lib-b"])
      let app = fx.home / "app"
      fx.cloneApp(app)
      fx.cloneSibling("lib-a", fx.home / "libs" / "lib-a")
      fx.cloneSibling("lib-b", fx.home / "lib-b")

      let diag = fx.health(app, fix = false)
      checkpoint("health:\n" & diag.output)
      let row = siblingsRow(diag.output)
      check row.len > 0
      check " ok " in row

  test "a missing sibling is cloned beside the checkout, named absolutely":
    if findExe("git").len == 0:
      skip("git not on PATH; this case builds real repositories")
    else:
      let fx = setupFixture("repro-health-sib-clone-")
      defer: removeDir(fx.scratch)
      fx.writeOuterWorkspace(["app", "lib-a", "lib-b"])
      let app = fx.dev / "app"
      fx.cloneApp(app)
      fx.cloneSibling("lib-a", fx.dev / "lib-a")
      let dest = fx.dev / "lib-b"

      let fixed = fx.health(app, fix = true)
      checkpoint("health --fix:\n" & fixed.output)
      # ``--fix`` prints the table it re-diagnoses after acting, so the
      # missing sibling is named by the plan, not by the row.
      check "siblings: clone 1 missing repository over the network " &
        "(../lib-b) into " & dest in fixed.output
      var planLine, cloneLine = ""
      for line in fixed.output.splitLines():
        if line.startsWith("fix: plan:") and " siblings: " in line: planLine = line
        if "fix: cloning missing sibling" in line: cloneLine = line
      check dest in planLine
      check dest in cloneLine
      check dirExists(dest / ".git")
      check not dirExists(fx.home / "lib-b")
      check "fix: siblings: cloned 1, failed 0" in fixed.output

  test "a destination outside the workspace is refused, and named":
    if findExe("git").len == 0:
      skip("git not on PATH; this case builds real repositories")
    else:
      let fx = setupFixture("repro-health-sib-refuse-")
      defer: removeDir(fx.scratch)
      fx.writeOuterWorkspace(["app", "lib-a", "lib-b"])
      let app = fx.dev / "app"
      fx.cloneApp(app)
      fx.cloneSibling("lib-a", fx.dev / "lib-a")
      # A develop override places lib-b far from the checkout and its
      # siblings; nothing is checked out there.
      let elsewhere = fx.scratch / "elsewhere" / "lib-b"
      createDir(app / ".repro")
      writeFile(app / ".repro" / "develop-overrides.toml",
        "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
        "[[override]]\npackage = \"lib-b\"\nlocal_path = \"" & elsewhere &
        "\"\nstate = \"editable\"\ncreated_at = \"2026-11-27T00:00:00Z\"\n")

      let fixed = fx.health(app, fix = true)
      checkpoint("health --fix:\n" & fixed.output)
      check "missing checkouts:" in siblingsRow(fixed.output)
      var planLine = ""
      for line in fixed.output.splitLines():
        if line.startsWith("fix: plan:") and " siblings: " in line: planLine = line
      check "refuse 1" in planLine
      check elsewhere in planLine
      var refusal = ""
      for line in fixed.output.splitLines():
        if line.startsWith("fix: refusing to clone"): refusal = line
      check elsewhere in refusal
      check "outside the workspace" in refusal
      check not dirExists(elsewhere)
      check not dirExists(fx.scratch / "elsewhere")
      check "cloning missing sibling" notin fixed.output

  test "the outer workspace's develop overrides do not place a non-member":
    if findExe("git").len == 0:
      skip("git not on PATH; this case builds real repositories")
    else:
      let fx = setupFixture("repro-health-sib-outer-override-")
      defer: removeDir(fx.scratch)
      fx.writeOuterWorkspace(["app", "lib-a", "lib-b"])
      # The home workspace overrides lib-b for ITS checkouts.
      writeFile(fx.home / ".repro" / "develop-overrides.toml",
        "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
        "[[override]]\npackage = \"lib-b\"\nlocal_path = \"forks/lib-b\"" &
        "\nstate = \"editable\"\ncreated_at = \"2026-11-27T00:00:00Z\"\n")
      let app = fx.dev / "app"
      fx.cloneApp(app)
      fx.cloneSibling("lib-a", fx.dev / "lib-a")
      fx.cloneSibling("lib-b", fx.dev / "lib-b")

      let fixed = fx.health(app, fix = true)
      checkpoint("health --fix:\n" & fixed.output)
      check " ok " in siblingsRow(fixed.output)
      check "cloning missing sibling" notin fixed.output
      check not dirExists(fx.home / "forks")

  test "membership applies to a declared but inactive checkout and to deps/":
    if findExe("git").len == 0:
      skip("git not on PATH; this case builds real repositories")
    else:
      let fx = setupFixture("repro-health-sib-inactive-")
      defer: removeDir(fx.scratch)
      # The enabled project holds lib-a and lib-b, not app: app is declared
      # only by its fragment. lib-b's declared path differs from its name, so
      # only the membership can place it.
      fx.writeOuterWorkspace(["app", "lib-a", "libs/lib-b"],
        activeOnly = ["lib-a", "lib-b"])
      let app = fx.home / "app"
      fx.cloneApp(app)
      fx.cloneSibling("lib-a", fx.home / "lib-a")
      fx.cloneSibling("lib-b", fx.home / "libs" / "lib-b")

      let diag = fx.health(app, fix = false)
      checkpoint("health (inactive member):\n" & diag.output)
      check " ok " in siblingsRow(diag.output)

      # A nested develop checkout inside the member belongs to the workspace
      # through that member.
      let nested = app / "deps" / "app"
      fx.cloneApp(nested)
      let nestedDiag = fx.health(nested, fix = false)
      checkpoint("health (nested deps/):\n" & nestedDiag.output)
      check " ok " in siblingsRow(nestedDiag.output)

  test "a project checkout with its own state file still clones ../ siblings":
    if findExe("git").len == 0:
      skip("git not on PATH; this case builds real repositories")
    else:
      let fx = setupFixture("repro-health-sib-statefile-")
      defer: removeDir(fx.scratch)
      let app = fx.dev / "app"
      fx.cloneApp(app)
      createDir(app / ".repro")
      writeFile(app / ".repro" / "workspace-state.toml",
        "schema = \"reprobuild.workspace.state.v1\"\n\n[workspace]\n" &
        "project = \"app\"\n")
      fx.cloneSibling("lib-a", fx.dev / "lib-a")
      let dest = fx.dev / "lib-b"

      let fixed = fx.health(app, fix = true)
      checkpoint("health --fix:\n" & fixed.output)
      check "siblings: clone 1 missing repository over the network " &
        "(../lib-b) into " & dest in fixed.output
      check "refusing to clone" notin fixed.output
      check dirExists(dest / ".git")
      check "fix: siblings: cloned 1, failed 0" in fixed.output
