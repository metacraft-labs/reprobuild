## An observed input that cannot be read is evidence, not a build failure
## (Filesystem-Policy-And-Observed-Inputs.md; Monitor-Hook-Shim.md
## §"Failure Semantics", "fail the monitored action OR make it
## non-cacheable").
##
## THE DEFECT THIS PINS. A host whose `/nix/store` held a few stale
## home-manager symlinks (targets deleted) could not build anything: the
## provider compile lists the store, the monitor recorded the `stat` of each
## dangling entry as a probe, and the publish step OPENED every observed path
## to hash it under the edge's content-keyed policy. The open failed and the
## `IOError` (`cannot open: /nix/store/...-hm_gitconfig`) escaped and aborted
## the build.
##
## THE SHAPE REPRODUCED HERE, without touching `/nix/store`: a real project
## whose one edge runs a tiny tool that lists a temporary directory and tests
## each entry with `[ -e ]` (a following `stat`, exactly what `walkDir` does
## for a symlink entry). The directory is populated per case with the entity
## under test. Everything goes through the built `./build/bin/repro` -- a real
## provider compile, a real monitored launch, a real action cache. The tool
## appends to a marker file on every run, so a case can tell an executed edge
## from a cache hit, and writes what it saw, so a case can tell which state it
## ran against.
##
## The recorded form each case asserts:
##
##   dangling link  `ffkUnresolvedSymlink`: the link's own size and mtime,
##                  and (content-keyed policies) a hash of its `readlink`
##                  text and why it does not resolve. The edge is cached;
##                  the link gaining a target re-runs it, under the default
##                  timestamp policy as well as under `checksum`.
##   link loop      the same kind (`ELOOP`); breaking the loop re-runs it.
##   EACCES file    exists, cannot be read: a content-keyed record cannot
##                  describe it, so the result is not published and the edge
##                  re-runs on the next build. The build itself succeeds.
##   project tree   a dangling link inside the project (beside `repro.nim`
##                  and inside the listed directory) is no different.
##
## MOCK POLICY: none. The only stand-in is the listing tool, a shell script on
## `PATH`, which is the ordinary way a project declares a tool; it is the
## workload, not a replacement for anything under test.

import std/[os, osproc, strutils, tempfiles, unittest]

when defined(posix):
  import std/posix

import repro_test_support

proc reproBinary(): string =
  ## `repro` is a build-graph artifact (`reprobuild.apps.repro`); drive the
  ## built one rather than compiling the CLI at test time.
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

const listerInterface = "import repro_project_dsl\n\n" &
  "defineCliInterface dirLister, \"dir-lister\":\n" &
  "  call:\n" &
  "    flag dir is string, alias = \"--dir\", required = true\n" &
  "    flag output is string, alias = \"--output\", role = output, required = true\n" &
  "    flag marker is string, alias = \"--marker\", required = true\n" &
  "    outputs output\n"

type Fixture = object
  root: string
  binDir: string
  project: string
  listed: string
  repro: string

proc output(fx: Fixture): string = fx.project / "build" / "listing.txt"
proc marker(fx: Fixture): string = fx.project / ".repro" / "runs.log"

proc runs(fx: Fixture): int =
  ## How many times the edge has executed.
  if not fileExists(fx.marker):
    return 0
  for line in readFile(fx.marker).splitLines():
    if line == "ran":
      inc result

proc newFixture(prefix: string; listedInsideProject = false;
                policy = ""): Fixture =
  ## A project with one edge listing `listed`. `policy` is spliced into the
  ## call as `actionCachePolicy = <policy>` when non-empty.
  result.root = createTempDir(prefix, "")
  result.binDir = result.root / "bin"
  result.project = result.root / "project"
  result.listed =
    if listedInsideProject: result.project / "data"
    else: result.root / "listed"
  result.repro = reproBinary()
  createDir(result.listed)
  writeFile(result.listed / "plain.txt", "plain\n")
  writeExecutable(result.binDir / "dir-lister",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'dir-lister 1.0.0'; exit 0; fi\n" &
    "dir= output= marker=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --dir) dir=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    --marker) marker=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    ": > \"$output\"\n" &
    "for entry in \"$dir\"/*; do\n" &
    "  if [ -e \"$entry\" ]; then state=present; else state=absent; fi\n" &
    "  printf '%s %s\\n' \"${entry##*/}\" \"$state\" >> \"$output\"\n" &
    "done\n" &
    "printf 'ran\\n' >> \"$marker\"\n")
  createDir(result.project / "reprobuild" / "packages")
  writeFile(result.project / "reprobuild" / "packages" / "dir_lister.nim",
    listerInterface)
  let policyArg =
    if policy.len > 0: ",\n      actionCachePolicy = " & policy
    else: ""
  writeFile(result.project / "repro.nim",
    "import repro_project_dsl\n\n" &
    "package danglingProbe:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"dir-lister >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    discard dirLister(actionId = \"listing\",\n" &
    "      dir = " & escape(result.listed) & ",\n" &
    "      output = \"build/listing.txt\",\n" &
    "      marker = \".repro/runs.log\"" & policyArg & ")\n")

proc build(fx: Fixture): tuple[code: int; output: string] =
  ## `repro build` in the project, the tool on `PATH`, stdout and stderr
  ## merged so a diagnostic is matched wherever it is printed.
  let command = "PATH=" & quoteShell(fx.binDir & $PathSep & getEnv("PATH")) &
    " " & quoteShell(fx.repro) & " build --tool-provisioning=path " &
    "--daemon=off 2>&1"
  let res = execCmdEx(command, workingDir = fx.project)
  (code: res.exitCode, output: res.output)

proc requireBuilt(fx: Fixture; label: string) =
  ## The primary assertion of every case: the build SUCCEEDS. Before the
  ## fix the failure was `repro build: error: cannot open: <path>`.
  let res = fx.build()
  checkpoint(label & ":\n" & res.output)
  check res.code == 0
  check "cannot open" notin res.output
  check fileExists(fx.output)

proc listing(fx: Fixture): string =
  if fileExists(fx.output): readFile(fx.output) else: ""

suite "t_dangling_symlink_in_observed_directory_does_not_abort":

  test "a dangling link in a listed directory: content-keyed edge builds, is cached, re-runs when the link gains a target":
    let fx = newFixture("repro-dangling-checksum-", policy = "acfpChecksum")
    defer: removeDir(fx.root)
    let target = fx.root / "target-that-does-not-exist-yet.txt"
    createSymlink(target, fx.listed / "dangling")

    fx.requireBuilt("first build, dangling link present")
    check fx.runs == 1
    check "dangling absent" in fx.listing

    # Nothing changed: the dangling link was RECORDED (not refused), so the
    # edge is served from its record rather than re-run.
    fx.requireBuilt("second build, nothing changed")
    check fx.runs == 1

    # The link gains a target. Its own `lstat` is byte-identical before and
    # after; only the recorded unresolved-link identity can see this.
    writeFile(target, "now it resolves\n")
    fx.requireBuilt("third build, the link's target exists")
    check fx.runs == 2
    check "dangling present" in fx.listing

  test "a dangling link whose target appears re-runs the edge under the default policy":
    # The default (timestamp) policy never reads content, so it never
    # aborted; what it lacked was the invalidation, because the link's own
    # metadata does not move when its target appears.
    let fx = newFixture("repro-dangling-timestamp-")
    defer: removeDir(fx.root)
    let target = fx.root / "late-target.txt"
    createSymlink(target, fx.listed / "dangling")

    fx.requireBuilt("first build, dangling link present")
    check fx.runs == 1
    check "dangling absent" in fx.listing
    fx.requireBuilt("second build, nothing changed")
    check fx.runs == 1

    writeFile(target, "appeared\n")
    fx.requireBuilt("third build, the link's target exists")
    check fx.runs == 2
    check "dangling present" in fx.listing

  test "a symlink loop in a listed directory builds, and breaking the loop re-runs the edge":
    let fx = newFixture("repro-dangling-loop-", policy = "acfpChecksum")
    defer: removeDir(fx.root)
    let a = fx.listed / "loop-a"
    let b = fx.listed / "loop-b"
    createSymlink(b, a)
    createSymlink(a, b)

    fx.requireBuilt("first build, loop present")
    check fx.runs == 1
    check "loop-a absent" in fx.listing
    fx.requireBuilt("second build, nothing changed")
    check fx.runs == 1

    # Break the loop: `loop-b` now names a real file, so `loop-a` resolves
    # through it. Neither link's target TEXT for `loop-a` changed.
    removeFile(b)
    createSymlink(fx.listed / "plain.txt", b)
    fx.requireBuilt("third build, the loop is broken")
    check fx.runs == 2
    check "loop-a present" in fx.listing

  # POSIX only: the case is defined by a mode-000 file, which Windows
  # permissions do not express. Declared conditionally rather than skipped.
  when defined(posix):
    test "an unreadable file in a listed directory builds and is not cached":
      let fx = newFixture("repro-dangling-eacces-", policy = "acfpChecksum")
      defer:
        setFilePermissions(fx.listed / "secret.txt", {fpUserRead, fpUserWrite})
        removeDir(fx.root)
      writeFile(fx.listed / "secret.txt", "secret\n")
      setFilePermissions(fx.listed / "secret.txt", {})
      # Root reads a mode-000 file anyway, and then there is no unreadable
      # input to test. Say so instead of passing vacuously.
      let unreadable = posix.access((fx.listed / "secret.txt").cstring, R_OK) != 0
      checkpoint("mode-000 file is unreadable to this user: " & $unreadable)
      require unreadable

      fx.requireBuilt("first build, unreadable file present")
      check fx.runs == 1
      check "secret.txt present" in fx.listing

      # A content-keyed record cannot describe a file whose bytes it cannot
      # read, so nothing was published: the edge runs again rather than
      # being served -- the "make it non-cacheable" arm.
      fx.requireBuilt("second build, nothing changed")
      check fx.runs == 2

      # Positive control: once the file is readable the record CAN be
      # published, and the build after that is a hit. Without this, a
      # change that simply stopped caching this edge would pass the case.
      setFilePermissions(fx.listed / "secret.txt", {fpUserRead, fpUserWrite})
      fx.requireBuilt("third build, file readable")
      check fx.runs == 3
      fx.requireBuilt("fourth build, nothing changed")
      check fx.runs == 3

  test "a dangling link inside the project tree does not abort the build":
    let fx = newFixture("repro-dangling-in-project-",
      listedInsideProject = true, policy = "acfpChecksum")
    defer: removeDir(fx.root)
    let target = fx.root / "gone.txt"
    createSymlink(target, fx.listed / "dangling")
    createSymlink(target, fx.project / "dangling-beside-repro-nim")
    createSymlink(target, fx.project / "reprobuild" / "packages" /
      "dangling.nim")

    fx.requireBuilt("first build, dangling links in the project tree")
    check fx.runs == 1
    check "dangling absent" in fx.listing

    writeFile(target, "present\n")
    fx.requireBuilt("second build, the links resolve")
    check fx.runs == 2
    check "dangling present" in fx.listing
