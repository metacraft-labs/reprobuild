import std/[json, os, osproc, strutils, unittest]
import repro_lock
import repro_multihash

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir
const reproBinary = repoRoot / "build/bin/repro".addFileExt(ExeExt)
const solverInputs = """package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc command(args: openArray[string]; cwd: string): tuple[output: string, code: int] =
  let executed = execCmdEx(quoteShellCommand(args), workingDir = cwd)
  (executed.output, executed.exitCode)

proc mustRun(args: openArray[string]; cwd: string): string =
  let executed = command(args, cwd)
  doAssert executed.code == 0, executed.output
  executed.output.strip

proc seedRepo(path: string; objectFormat = "sha1") =
  createDir(path)
  discard mustRun(["git", "init", "--object-format=" & objectFormat, "-b", "main"], path)
  discard mustRun(["git", "config", "user.name", "Lock fixture"], path)
  discard mustRun(["git", "config", "user.email", "lock@example.invalid"], path)
  writeFile(path / ".gitignore", "/.repro/\n/deps/\n")
  writeFile(path / "repro.solver", solverInputs)
  discard mustRun(["git", "add", ".gitignore", "repro.solver"], path)
  discard mustRun(["git", "commit", "-m", "Seed declarations"], path)

proc refresh(path: string) =
  discard mustRun([reproBinary, "lock", "refresh", path], path)

proc validate(path: string): tuple[code: int, report: JsonNode] =
  let executed = execCmdEx(quoteShellCommand(
    [reproBinary, "lock", "validate", path, "--json"]),
    workingDir = path, options = {poUsePath})
  (executed.exitCode, parseJson(executed.output))

proc commitLock(path: string) =
  let generated = readFile(path / "repro.lock")
  discard mustRun(["git", "add", "repro.lock"], path)
  discard mustRun(["git", "commit", "-m", "Record generated lock"], path)
  doAssert mustRun(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], path) == "repro.lock"
  doAssert mustRun(["git", "status", "--porcelain"], path) == ""
  doAssert mustRun(["git", "show", "HEAD:repro.lock"], path) == generated.strip
  doAssert readFile(path / "repro.lock") == generated

template withFixture(label: string; body: untyped) =
  doAssert findExe("git").len > 0, "Git is required by the registered lock fixture"
  doAssert fileExists(reproBinary), "Build the registered repro CLI prerequisite"
  let scratch {.inject.} = getTempDir() / ("root-lock-" & label & "-" & $getCurrentProcessId())
  createDir(scratch)
  defer: removeDir(scratch)
  let project {.inject.} = scratch / "app"
  seedRepo(project)
  body

suite "committed root provenance validation":
  test "lock-only commits preserve validity and historical root coordinates":
    withFixture("roundtrip"):
      discard mustRun([reproBinary, "hooks", "ensure", "--vcs", project], project)
      for round in 1 .. 2:
        let head = mustRun(["git", "rev-parse", "HEAD"], project)
        refresh(project)
        check validate(project).code == 0
        let lock = parseLockedDependencies(readFile(project / "repro.lock"))
        check lock.deps.len == 1
        check lock.deps[0].path == "."
        check lock.deps[0].coordinates.revision == head
        check lock.deps[0].integrity == "git-sha1:" & head
        commitLock(project)
        let after = validate(project)
        checkpoint($after.report)
        check after.code == 0
        check after.report["valid"].getBool

  test "linked worktree root verifies its recorded commit":
    withFixture("worktree"):
      let linked = scratch / "linked"
      discard mustRun(["git", "worktree", "add", "-b", "linked", linked], project)
      refresh(linked)
      commitLock(linked)
      check fileExists(linked / ".git")
      check validate(linked).code == 0
      var lock = parseLockedDependencies(readFile(linked / "repro.lock"))
      lock.deps[0].integrity = "git-sha1:" & repeat('0', 40)
      writeFile(linked / "repro.lock", serializeLockedDependencies(lock))
      check validate(linked).code == 2

  test "a linked worktree checks sibling integrity in the main checkout frame":
    # A committed lock places dependencies relative to the main worktree,
    # including when it is read from a deeply nested linked worktree. Both
    # readers must inspect the same real sibling, rather than silently skip
    # verification because a sibling of the invoking worktree is absent.
    # No doubles: the sibling, linked worktree and validation CLI are real.
    withFixture("sibling-worktree"):
      let sibling = scratch / "lib"
      seedRepo(sibling)
      let pinned = mustRun(["git", "rev-parse", "HEAD"], sibling)
      let linked = project / ".repro" / "linked" / "branch"
      discard mustRun(["git", "worktree", "add", "-b", "linked", linked], project)
      refresh(project)
      var lock = parseLockedDependencies(readFile(project / "repro.lock"))
      lock.deps.add(LockedDep(name: "lib", path: "../lib",
        coordinates: Coordinates(kind: ckVcs, url: "file://" & sibling,
          gitRef: "main", revision: pinned),
        integrity: "git-sha1:" & pinned, visibility: "public"))
      var body = serializeLockedDependencies(lock)
      # Keep this a v2 input fixture so the same test can interrogate the
      # pre-migration CLI as a negative control, even when the test itself
      # was compiled against the current path-free writer.
      if "reprobuild.solved-graph-lock.v3" in body:
        body = body.replace("reprobuild.solved-graph-lock.v3",
          "reprobuild.solved-graph-lock.v2")
          .replace("self = \"true\"", "path = \".\"")
          .replace("{ name = \"lib\",", "{ name = \"lib\", path = \"../lib\",")
      writeFile(project / "repro.lock", body)
      writeFile(linked / "repro.lock", body)
      check validate(project).code == 0
      check validate(linked).code == 0

      writeFile(sibling / "later.txt", "a different published identity\n")
      discard mustRun(["git", "add", "later.txt"], sibling)
      discard mustRun(["git", "commit", "-m", "Advance sibling"], sibling)
      let atRoot = validate(project)
      let inLinked = validate(linked)
      checkpoint($atRoot.report)
      checkpoint($inLinked.report)
      check atRoot.code == 2
      check "dep 'lib' integrity mismatch" in $atRoot.report
      check inLinked.code == 2
      check "dep 'lib' integrity mismatch" in $inLinked.report

  test "root integrity tampering remains a refusal":
    withFixture("tamper"):
      refresh(project)
      var lock = parseLockedDependencies(readFile(project / "repro.lock"))
      lock.deps[0].integrity = "git-sha1:" & repeat('0', 40)
      writeFile(project / "repro.lock", serializeLockedDependencies(lock))
      let after = validate(project)
      check after.code == 2
      check "integrity" in $after.report

  test "a moving revision alias is not the root commit integrity":
    withFixture("alias"):
      refresh(project)
      let realCommit = mustRun(["git", "rev-parse", "HEAD"], project)
      let fullHexAlias = repeat('a', 40)
      doAssert realCommit != fullHexAlias
      discard mustRun(["git", "branch", fullHexAlias], project)
      var lock = parseLockedDependencies(readFile(project / "repro.lock"))
      lock.deps[0].coordinates.revision = fullHexAlias
      lock.deps[0].integrity = "git-sha1:" & fullHexAlias
      doAssert isWellFormedMultihash(lock.deps[0].integrity)
      writeFile(project / "repro.lock", serializeLockedDependencies(lock))
      check validate(project).code == 2

      # Git treats a full-width hex name as an object ID. A shorter hex ref
      # resolves as a branch while also passing the current multihash parser.
      let aliasName = "deadbeef"
      discard mustRun(["git", "branch", aliasName], project)
      lock.deps[0].coordinates.revision = aliasName
      lock.deps[0].integrity = "git-sha1:" & aliasName
      doAssert isWellFormedMultihash(lock.deps[0].integrity)
      writeFile(project / "repro.lock", serializeLockedDependencies(lock))
      let after = validate(project)
      check after.code == 2
      check "recomputed integrity git-sha1:" & realCommit in $after.report

  test "SHA-256 root provenance survives a lock-only commit":
    withFixture("sha256"):
      let sha256Project = scratch / "sha256"
      seedRepo(sha256Project, "sha256")
      refresh(sha256Project)
      let lock = parseLockedDependencies(readFile(sha256Project / "repro.lock"))
      check lock.deps[0].integrity.startsWith("git-sha256:")
      commitLock(sha256Project)
      check validate(sha256Project).code == 0

  test "tracked staged root source drift is not a lock-only change":
    withFixture("staged-drift"):
      refresh(project)
      commitLock(project)
      writeFile(project / "payload.txt", "staged source\n")
      discard mustRun(["git", "add", "payload.txt"], project)
      let after = validate(project)
      check after.code == 2
      check "root source content differs" in $after.report

  test "ordinary root source commits do not become valid historical provenance":
    withFixture("source-drift"):
      refresh(project)
      commitLock(project)
      writeFile(project / "payload.txt", "changed root source\n")
      discard mustRun(["git", "add", "payload.txt"], project)
      discard mustRun(["git", "commit", "-m", "Change root source"], project)
      let after = validate(project)
      check after.code == 2
      check "root source content differs" in $after.report

  test "a mixed lock and source commit is not a lock-only change":
    withFixture("mixed-drift"):
      refresh(project)
      writeFile(project / "payload.txt", "new source alongside lock\n")
      discard mustRun(["git", "add", "repro.lock", "payload.txt"], project)
      discard mustRun(["git", "commit", "-m", "Record lock and source"], project)
      let after = validate(project)
      check after.code == 2
      check "root source content differs" in $after.report

  test "unavailable root revision remains a refusal":
    withFixture("missing"):
      refresh(project)
      var lock = parseLockedDependencies(readFile(project / "repro.lock"))
      lock.deps[0].coordinates.revision = repeat('f', 40)
      lock.deps[0].integrity = "git-sha1:" & repeat('f', 40)
      writeFile(project / "repro.lock", serializeLockedDependencies(lock))
      check validate(project).code == 2

  test "changed solver declarations remain stale after committing a lock":
    withFixture("inputs"):
      refresh(project)
      commitLock(project)
      writeFile(project / "repro.solver", solverInputs.replace("2.2.0", "2.4.0"))
      let after = validate(project)
      check after.code == 2
      check "inputs_digest mismatch" in $after.report

  test "non-root checkout drift remains a refusal":
    withFixture("sibling"):
      let sibling = project / "deps" / "sibling"
      seedRepo(sibling)
      writeFile(sibling / "repro.nim", "import repro_project_dsl\npackage sib:\n  build:\n    discard aggregate(\"sib\", actions = @[])\n")
      discard mustRun(["git", "add", "repro.nim"], sibling)
      discard mustRun(["git", "commit", "-m", "Declare sibling"], sibling)
      refresh(project)
      let lock = parseLockedDependencies(readFile(project / "repro.lock"))
      check lock.deps.len == 2
      commitLock(project)
      check validate(project).code == 0
      writeFile(sibling / "payload.txt", "changed sibling\n")
      discard mustRun(["git", "add", "payload.txt"], sibling)
      discard mustRun(["git", "commit", "-m", "Change sibling"], sibling)
      let after = validate(project)
      check after.code == 2
      check "dep 'sibling' integrity mismatch" in $after.report

  test "validation reports malformed v3 dependency metadata":
    withFixture("malformed-v3"):
      refresh(project)
      let generated = readFile(project / "repro.lock")
      var depsLine = ""
      for line in generated.splitLines():
        if line.startsWith("deps = ["): depsLine = line
      doAssert depsLine.len > 0
      for entries in [
          "{ name = \"same\", coord_kind = \"vcs\" }, { name = \"same\", coord_kind = \"vcs\" }",
          "{ name = \"pkg\", self = \"true\", coord_kind = \"store\" }"]:
        writeFile(project / "repro.lock", generated.replace(depsLine,
          "deps = [" & entries & "]"))
        let invalid = validate(project)
        check invalid.code == 2
        check not invalid.report["valid"].getBool()
        check "cannot read locked dependencies" in $invalid.report["problems"]
