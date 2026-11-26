## Cross-Repo-Source-Consumption §4.2a.2a — required gitlink source
## artifacts for a consumed Nim library.
##
## A producer library whose exported source compiles a vendored tree from a
## git submodule declares it::
##
##   library greetlib:
##     sourceGitlinks:
##       "src/greetlib/vend"
##
## and a consumer of that library must compile against the exported tree
## WITH the submodule's content beside the Nim file that reads it
## (``currentSourcePath``-relative), without the engine running any producer
## action and without initializing or changing the producer checkout.
##
## Fixture (black-box, the built ``build/bin/repro``; every path in a fresh
## scratch directory; real ``git`` repositories with real gitlinks):
##
##   remotes/vendorlib     the submodule's repository: ``vendor.txt``
##   remotes/vendorlib-nested   the same, itself carrying an UNINITIALIZED
##                         gitlink (for the nested-gitlink refusal)
##   greetlib              the producer checkout: ``src/greetlib.nim``
##                         imports ``greetlib/vend_bindings``, which
##                         ``staticRead``s ``vend/vendor.txt`` next to itself;
##                         ``src/greetlib/vend`` is a gitlink (mode 160000)
##                         bound by ``.gitmodules`` to ``remotes/vendorlib``,
##                         left UNINITIALIZED (an empty directory). Its
##                         default action FAILS and names a pool no daemon
##                         has, so executing it would fail the build.
##   consumer              ``uses: "greetlib"``; one typed ``nim.c`` edge
##                         compiling ``import greetlib`` plus a run edge that
##                         writes ``greeting()`` to ``build/app-out.txt``.
##
## What is asserted, each against the spec's "Real validation required
## before acceptance" list:
##
##   1. Cold, uninitialized submodule (develop mode): the build succeeds and
##      the consumer sees the vendored stamp at the EXACT committed gitlink
##      commit (the remote's later commit is not taken); the producer
##      checkout -- working tree, index bytes, HEAD, ``.git/modules`` -- is
##      unchanged; the producer's failing default action never ran.
##   2. Lock-pinned mode against the same source: same output, and the
##      composed artifact's content digest equals the develop one (identity
##      parity where the source agrees).
##   3. Invalidation: editing a Nim module the consumer imports rebuilds it;
##      adding a file nothing reads keeps the consumer compile cached.
##   4. Initialized dirty develop view: an edit inside the initialized
##      submodule reaches the consumer; parent and submodule working trees,
##      indexes and HEADs are byte-identical before and after.
##   5. Refusals, each BEFORE the consumer compiler runs (no binary is
##      produced): a gitlink commit the remote does not have, an
##      uncommitted ``.gitmodules`` url change, a staged gitlink change, a
##      nested unresolved gitlink, an absolute symlink in the develop view,
##      an unavailable remote, a path outside the exported root and a path
##      that is not a gitlink.
##   6. Negative control: the identical producer WITHOUT the declaration
##      fails the consumer compile on the missing vendored file -- the
##      failure this feature exists to remove.
##
## Test-double policy: NO mocks. Real git, the real engine binary, the real
## Nim compiler; the "remotes" are local repositories because a network
## fetch would make the suite depend on a host it does not control, and the
## fetch path exercised (``git fetch <url> <commit>``) is the same.
##
## Requires ``git`` on PATH and a built ``build/bin/repro``; it fails rather
## than skips without them.

import std/[os, osproc, strutils, unittest]

import repro_lock

const ReprobuildRepoRoot =
  currentSourcePath().parentDir().parentDir().parentDir()
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const vendorStamp = "VENDOR-AT-COMMITTED-GITLINK-5e1a"
const vendorStampLater = "VENDOR-LATER-COMMIT-NOT-SELECTED-77c0"
const vendorStampDirty = "VENDOR-DIRTY-DEVELOP-VIEW-a93d"

proc producerRepro(declare: bool; gitlinkPath = "src/greetlib/vend"): string =
  result = """
import repro_project_dsl

package greetlib:
  defaultToolProvisioning "path"

  uses:
    "sh"

  library greetlib:
    kind: static
"""
  if declare:
    result.add("    sourceGitlinks:\n      \"" & gitlinkPath & "\"\n")
  result.add("""

  build:
    # Executing the producer's default closure would FAIL the build: it
    # exits 1, writes a marker first, and needs a pool the consumer's daemon
    # does not have. Source consumption must never run it.
    discard buildPool("greetlib.private-serial", 1'u32)
    discard buildAction(
      id = "greetlib.test.must-not-run",
      call = inlineExecCall(@["sh", "-c",
        "mkdir -p build && printf ran > build/PRODUCER-DEFAULT-RAN.marker; exit 1"]),
      outputs = @["build/PRODUCER-DEFAULT-RAN.marker"],
      pool = "greetlib.private-serial",
      cacheable = false,
      toolIdentityRefs = @["sh"])
""")

proc greetlibModule(suffix: string): string =
  "import std/strutils\nimport greetlib/vend_bindings\n" &
    "proc greeting*(): string = vendorText.strip() & \"" & suffix & "\"\n"

const vendBindings = """
# Reads the vendored tree beside this file, as isonim's yoga_bindings.nim
# compiles Yoga from ``currentSourcePath``-relative paths.
const vendRoot = currentSourcePath()[0 .. ^(len("vend_bindings.nim") + 1)] &
  "vend"
const vendorText* = staticRead(vendRoot & "/vendor.txt")
"""

const consumerApp = """
import greetlib

when isMainModule:
  writeFile("build/app-out.txt", greeting())
"""

const consumerRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "clang"
    "sh"
    "mkdir"
    "greetlib"

  build:
    let compiled = nim.c(
      source = "src/app.nim",
      binary = "build/bin/app",
      cc = "clang",
      parallelBuild = 1)
    discard shell(
      command = "mkdir -p build && ./build/bin/app",
      actionId = "consumer.run.app",
      extraInputs = @["build/bin/app"],
      extraOutputs = @["build/app-out.txt"],
      cacheable = false)
"""

proc q(value: string): string = quoteShell(value)

var gitBin = ""

proc git(repo: string; args: varargs[string]): string =
  var cmd = q(gitBin) & " -C " & q(repo) &
    " -c user.email=gitlinks@example.invalid -c user.name=Gitlinks" &
    " -c protocol.file.allow=always"
  for a in args:
    cmd.add(" ")
    cmd.add(q(a))
  let r = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut})
  doAssert r.exitCode == 0, "git " & args.join(" ") & " in " & repo &
    " failed: " & r.output
  r.output.strip()

proc newRepo(dir: string) =
  createDir(dir)
  discard git(dir, "init", "--quiet")

proc commitAll(dir, message: string): string =
  discard git(dir, "add", "-A")
  discard git(dir, "commit", "--quiet", "--allow-empty", "-m", message)
  git(dir, "rev-parse", "HEAD")

proc addGitlink(repo, path, url, commit: string) =
  ## Record ``path`` as a gitlink at ``commit`` bound to ``url``, left
  ## uninitialized (an empty directory), as a fresh clone leaves it.
  writeFile(repo / ".gitmodules", "[submodule \"" & path & "\"]\n" &
    "\tpath = " & path & "\n\turl = " & url & "\n")
  discard git(repo, "update-index", "--add", "--cacheinfo",
    "160000," & commit & "," & path)
  createDir(repo / path)

proc writeProducer(root, vendorUrl, vendorCommit: string; declare = true;
                   gitlinkPath = "src/greetlib/vend") =
  newRepo(root)
  createDir(root / "src/greetlib")
  writeFile(root / "repro.nim", producerRepro(declare, gitlinkPath))
  writeFile(root / "src/greetlib.nim", greetlibModule("+nim"))
  writeFile(root / "src/greetlib/vend_bindings.nim", vendBindings)
  discard git(root, "add", "-A")
  addGitlink(root, "src/greetlib/vend", vendorUrl, vendorCommit)
  discard commitAll(root, "producer with a required gitlink")

proc writeConsumer(root: string; developPath = "") =
  createDir(root / "src")
  writeFile(root / "repro.nim", consumerRepro)
  writeFile(root / "src/app.nim", consumerApp)
  if developPath.len > 0:
    createDir(root / ".repro")
    writeFile(root / ".repro/develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "greetlib"
local_path = """ & "\"" & developPath & "\"" & """

state = "editable"
created_at = "2026-11-23T00:00:00Z"
""")

proc writeLock(root, url, revision: string) =
  var ld = LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    platform: currentPlatformId(), optimal: true,
    inputsDigest: inputsDigestOf("gitlink-fixture"))
  ld.deps.add(LockedDep(name: "greetlib",
    coordinates: Coordinates(kind: ckVcs, url: url, revision: revision),
    integrity: gitObjectMultihash("sha1", revision), visibility: "public"))
  writeFile(root / "repro.lock", serializeLockedDependencies(ld))

proc build(consumer, cache: string): tuple[code: int; output: string] =
  let cmd = q(absolutePath(reproBinary)) & " build " &
    q(consumer / "repro.nim") &
    " --tool-provisioning=path --daemon=off --log=quiet --progress=quiet" &
    " --measure=none --action-cache-root=" & q(cache)
  let r = execCmdEx(cmd, workingDir = ReprobuildRepoRoot)
  (r.exitCode, r.output)

proc appOut(consumer: string): string =
  let marker = consumer / "build/app-out.txt"
  if fileExists(marker): readFile(marker).strip() else: "<absent>"

proc repoState(repo: string): string =
  ## Everything a composition must not change in a checkout: HEAD, the
  ## index bytes, the working tree status and every file under it.
  result = "HEAD=" & git(repo, "rev-parse", "HEAD") & "\n"
  # Status first, and without optional locks, so this probe itself never
  # refreshes the index it is about to hash.
  let status = git(repo, "--no-optional-locks", "status", "--porcelain=v1",
    "--untracked-files=all", "--ignore-submodules=none")
  let index = repo / ".git/index"
  if fileExists(index):
    result.add("index=" & readFile(index).len.`$` & ":" &
      git(repo, "hash-object", "--no-filters", index) & "\n")
  result.add("modules=" & $dirExists(repo / ".git/modules") & "\n")
  result.add("status=" & status & "\n")
  for path in walkDirRec(repo, relative = true, skipSpecial = true):
    if path.startsWith(".git") or path.contains("/.git"):
      continue
    result.add(path & "=" & readFile(repo / path).len.`$` & "\n")

proc artifactDigest(consumer: string): string =
  let descriptor = consumer /
    ".repro/cross-repo-producers/.source-artifacts/greetlib/greetlib.descriptor"
  if not fileExists(descriptor):
    return "<no descriptor>"
  for line in readFile(descriptor).splitLines():
    if line.startsWith("artifact-content="):
      return line

suite "§4.2a.2a: required gitlink source artifacts":
  test "t_cross_repo_nim_library_required_gitlink_source":
    gitBin = findExe("git")
    require gitBin.len > 0
    require fileExists(reproBinary)
    block:
      let scratch = absolutePath(getTempDir() / ("gitlink-src-" &
        $getCurrentProcessId()))
      removeDir(scratch)
      createDir(scratch)
      defer:
        # The composed artifacts are read-only by design.
        discard execCmdEx("chmod -R u+w " & q(scratch))
        removeDir(scratch)

      # The submodule's repository: the committed gitlink names `selected`;
      # a LATER commit exists that must not be taken.
      let vendor = scratch / "remotes/vendorlib"
      newRepo(vendor)
      writeFile(vendor / "vendor.txt", vendorStamp & "\n")
      let selected = commitAll(vendor, "vendor at the selected commit")
      writeFile(vendor / "vendor.txt", vendorStampLater & "\n")
      discard commitAll(vendor, "a later vendor commit")

      # ---------------------------------------------------------------
      # 6. Negative control: no declaration, so nothing composes the tree.
      # ---------------------------------------------------------------
      block negativeControl:
        let root = scratch / "control"
        writeProducer(root / "greetlib", vendor, selected, declare = false)
        writeConsumer(root / "consumer", "../greetlib")
        let r = build(root / "consumer", scratch / "cache-control")
        checkpoint("control: " & r.output)
        check r.code != 0
        check r.output.contains("vendor.txt")
        check not fileExists(root / "consumer/build/bin/app")

      # ---------------------------------------------------------------
      # 1. + 3. Develop mode, cold uninitialized submodule.
      # ---------------------------------------------------------------
      let dev = scratch / "develop"
      let producer = dev / "greetlib"
      let consumer = dev / "consumer"
      writeProducer(producer, vendor, selected)
      writeConsumer(consumer, "../greetlib")
      let before = repoState(producer)
      block cold:
        let r = build(consumer, scratch / "cache-dev")
        checkpoint("develop cold: " & r.output)
        check r.code == 0
        check appOut(consumer) == vendorStamp & "+nim"
        check repoState(producer) == before
        check not fileExists(producer / "build/PRODUCER-DEFAULT-RAN.marker")
        check not r.output.contains("greetlib.private-serial")
        let composed = consumer / ".repro/cross-repo-producers" /
          ".source-artifacts/greetlib/greetlib/src/greetlib/vend/vendor.txt"
        check fileExists(composed)
        if fileExists(composed):
          check getFilePermissions(composed) * {fpUserWrite} == {}

      block invalidation:
        let app = consumer / "build/bin/app"
        let compiledAt = getLastModificationTime(app)
        # A file nothing reads: the consumer compile stays cached.
        sleep(1100)
        writeFile(producer / "src/greetlib/UNREAD-NOTES.txt", "unread\n")
        var r = build(consumer, scratch / "cache-dev")
        checkpoint("develop unread change: " & r.output)
        check r.code == 0
        check getLastModificationTime(app) == compiledAt
        check appOut(consumer) == vendorStamp & "+nim"
        # A module the consumer imports: the compile reruns.
        writeFile(producer / "src/greetlib.nim", greetlibModule("+edited"))
        r = build(consumer, scratch / "cache-dev")
        checkpoint("develop read change: " & r.output)
        check r.code == 0
        check appOut(consumer) == vendorStamp & "+edited"
        check getLastModificationTime(app) != compiledAt
        writeFile(producer / "src/greetlib.nim", greetlibModule("+nim"))
        removeFile(producer / "src/greetlib/UNREAD-NOTES.txt")
        r = build(consumer, scratch / "cache-dev")
        check r.code == 0
        check appOut(consumer) == vendorStamp & "+nim"

      # ---------------------------------------------------------------
      # 2. Lock-pinned mode against the same committed source.
      # ---------------------------------------------------------------
      block lockPinned:
        let lp = scratch / "lockpinned/consumer"
        writeConsumer(lp)
        writeLock(lp, producer, git(producer, "rev-parse", "HEAD"))
        let r = build(lp, scratch / "cache-lp")
        checkpoint("lock-pinned: " & r.output)
        check r.code == 0
        check appOut(lp) == vendorStamp & "+nim"
        check artifactDigest(lp) == artifactDigest(consumer)
        check artifactDigest(lp).startsWith("artifact-content=")
        check repoState(producer) == before

      # ---------------------------------------------------------------
      # 4. Initialized, dirty develop view.
      # ---------------------------------------------------------------
      block dirtyDevelopView:
        let root = scratch / "dirty"
        writeProducer(root / "greetlib", vendor, selected)
        let sub = root / "greetlib/src/greetlib/vend"
        removeDir(sub)
        discard git(root / "greetlib", "clone", "--quiet", vendor, sub)
        discard git(sub, "checkout", "--quiet", "--detach", selected)
        writeFile(sub / "vendor.txt", vendorStampDirty & "\n")
        writeConsumer(root / "consumer", "../greetlib")
        let parentBefore = repoState(root / "greetlib")
        let subBefore = repoState(sub)
        let r = build(root / "consumer", scratch / "cache-dirty")
        checkpoint("dirty develop view: " & r.output)
        check r.code == 0
        check appOut(root / "consumer") == vendorStampDirty & "+nim"
        check repoState(root / "greetlib") == parentBefore
        check repoState(sub) == subBefore

      # ---------------------------------------------------------------
      # 5. Refusals before the consumer compiler runs.
      # ---------------------------------------------------------------
      proc refused(tag: string; setup: proc (producer: string) {.closure.};
                   expected: string; declarePath = "src/greetlib/vend";
                   commit = "") =
        let root = scratch / ("refuse-" & tag)
        writeProducer(root / "greetlib", vendor,
          (if commit.len > 0: commit else: selected),
          gitlinkPath = declarePath)
        setup(root / "greetlib")
        writeConsumer(root / "consumer", "../greetlib")
        let r = build(root / "consumer", scratch / ("cache-" & tag))
        checkpoint(tag & ": " & r.output)
        check r.code != 0
        check r.output.contains("sourceGitlinks")
        check r.output.contains(expected)
        check not fileExists(root / "consumer/build/bin/app")

      proc noSetup(p: string) = discard
      proc changeUrlUncommitted(p: string) =
        writeFile(p / ".gitmodules", readFile(p / ".gitmodules").replace(
          vendor, vendor & "-elsewhere"))
      proc stageOtherGitlink(p: string) =
        discard git(p, "update-index", "--cacheinfo",
          "160000," & git(vendor, "rev-parse", "HEAD") &
          ",src/greetlib/vend")
      proc absoluteSymlink(p: string) =
        let sub = p / "src/greetlib/vend"
        removeDir(sub)
        discard git(p, "clone", "--quiet", vendor, sub)
        discard git(sub, "checkout", "--quiet", "--detach", selected)
        createSymlink("/etc/hostname", sub / "leak")
      proc unavailableRemote(p: string) =
        writeFile(p / ".gitmodules", readFile(p / ".gitmodules").replace(
          vendor, scratch / "remotes/does-not-exist"))
        discard git(p, "add", ".gitmodules")
        discard git(p, "commit", "--quiet", "-m", "unavailable url")

      refused("missing-commit", noSetup, "could not be acquired",
        commit = "0123456789abcdef0123456789abcdef01234567")
      refused("url-authority", changeUrlUncommitted, ".gitmodules in")
      refused("staged-gitlink", stageOtherGitlink, "the index of")
      block nested:
        let nestedRemote = scratch / "remotes/vendorlib-nested"
        newRepo(nestedRemote)
        writeFile(nestedRemote / "vendor.txt", vendorStamp & "\n")
        discard git(nestedRemote, "add", "-A")
        addGitlink(nestedRemote, "inner", vendor, selected)
        let nestedCommit = commitAll(nestedRemote, "vendor with a gitlink")
        proc pointAtNested(p: string) =
          writeFile(p / ".gitmodules", readFile(p / ".gitmodules").replace(
            vendor, nestedRemote))
          discard git(p, "add", ".gitmodules")
          discard git(p, "commit", "--quiet", "-m", "point at nested")
        refused("nested", pointAtNested, "nested gitlink",
          commit = nestedCommit)
      refused("symlink-escape", absoluteSymlink, "symlink escape")
      refused("unavailable", unavailableRemote, "could not be acquired")
      refused("outside-export", noSetup,
        "is not inside the library's exported root", declarePath = "vend")
      refused("not-a-gitlink", noSetup, "not a gitlink",
        declarePath = "src/greetlib")
