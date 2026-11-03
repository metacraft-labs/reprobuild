## A project whose tree is under a prefix that otherwise holds runtime state
## (`/dev/shm`, `/run`) gets the same answer as anywhere else, and one whose
## root cannot be told apart from that state is refused.
##
## The fold that keeps runtime state out of cache keys used to decide by path
## prefix alone, with carve-outs for the places projects had been found
## (a directory under `/dev/shm`, `/run/media`). Every other layout lost its
## reads silently: the listing of a project at `/dev/shm/<name>` was dropped,
## so a file added there was a cache hit, and a project on a mount at
## `/run/<dir>` had no inputs at all, so an edit was a hit too. Now the
## invocation's own roots decide: a read inside them is kept whatever the
## prefix, and a root such as `/dev/shm` itself, where a project file and a
## shared-memory object are the same shape of path, is refused before anything
## runs. Outside the roots, the places that hold only ordinary files (a
## directory under `/dev/shm`, `/run/media`) stay inputs: a dependency
## checkout or a sibling repository there is under none of the build's roots.
## The rest of the volatile prefixes is still dropped there.
##
## NO MOCKS: the built `repro`, a real provider compile, the real monitor and
## action cache. The edge's tool is a shell script on `PATH`, the ordinary
## way a project declares one. The `/dev/shm` cases use the real tmpfs. The
## `/run/<dir>` and root-is-`/dev/shm` cases need a mount there, which an
## unprivileged user gets in a user and mount namespace of its own
## (`unshare -rm`, then a nested user namespace mapping back to the real uid
## so the build does not run as root); a host that does not allow one skips
## those two cases with the reason.
##
## Falsifiability: making `dropsAsVolatileRuntimeState` ignore the scope (the
## prefix-only fold) fails the added-file case on `/dev/shm` and both
## `/run/<dir>` checks; making it drop nothing fails the shared-memory-object
## case; removing the `volatileRootRefusals` call from `runBuild` fails the
## refusal case; dropping the ordinary-file places outside the scope fails the
## dependency-checkout case (an edit there is a stale hit).

import std/[os, osproc, strutils, tempfiles, unittest]

when defined(posix):
  import std/posix

import repro_test_support
import repro_test_support/reasoned_skip

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

const listerInterface = "import repro_project_dsl\n\n" &
  "defineCliInterface shmLister, \"shm-lister\":\n" &
  "  call:\n" &
  "    flag dir is string, alias = \"--dir\", required = true\n" &
  "    flag read is string, alias = \"--read\", required = true\n" &
  "    flag runtime is string, alias = \"--runtime\", required = true\n" &
  "    flag output is string, alias = \"--output\", role = output, required = true\n" &
  "    flag marker is string, alias = \"--marker\", required = true\n" &
  "    outputs output\n"

type Fixture = object
  scratch: string    ## outside every volatile prefix: the tool lives here
  binDir: string
  project: string    ## where the files are on disk
  runtimeObject: string
  repro: string

proc marker(fx: Fixture): string = fx.project / ".repro" / "runs.log"
proc output(fx: Fixture): string = fx.project / "build" / "listing.txt"

proc runs(fx: Fixture): int =
  if not fileExists(fx.marker):
    return 0
  for line in readFile(fx.marker).splitLines():
    if line == "ran":
      inc result

proc newFixture(project: string; runtimeObject = "";
                 read = "src/input.txt"): Fixture =
  ## One edge, run in the project root: it lists the project ROOT itself,
  ## reads `read` (`src/input.txt`, or a file outside the project), and reads
  ## `runtimeObject` (when given) the way a tool touches a shared-memory
  ## object.
  result.scratch = createTempDir("repro-volatile-tool-", "")
  result.binDir = result.scratch / "bin"
  result.project = project
  result.runtimeObject = runtimeObject
  result.repro = reproBinary()
  writeExecutable(result.binDir / "shm-lister",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'shm-lister 1.0.0'; exit 0; fi\n" &
    "dir= read= runtime= output= marker=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --dir) dir=$2; shift 2 ;;\n" &
    "    --read) read=$2; shift 2 ;;\n" &
    "    --runtime) runtime=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    --marker) marker=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    "ls -1 \"$dir\" > \"$output\"\n" &
    "cat \"$read\" >> \"$output\"\n" &
    "if [ \"$runtime\" != none ] && [ -e \"$runtime\" ]; then cat \"$runtime\" > /dev/null; fi\n" &
    "printf 'ran\\n' >> \"$marker\"\n")
  createDir(project / "src")
  writeFile(project / "src" / "input.txt", "input v1\n")
  createDir(project / "reprobuild" / "packages")
  writeFile(project / "reprobuild" / "packages" / "shm_lister.nim",
    listerInterface)
  let runtimeArg = if runtimeObject.len > 0: runtimeObject else: "none"
  writeFile(project / "repro.nim",
    "import repro_project_dsl\n\n" &
    "package volatileProbe:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"shm-lister >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    discard shmLister(actionId = \"listing\",\n" &
    "      dir = \".\",\n" &
    "      read = " & escape(read) & ",\n" &
    "      runtime = " & escape(runtimeArg) & ",\n" &
    "      output = \"build/listing.txt\",\n" &
    "      marker = \".repro/runs.log\")\n")

proc buildCommand(fx: Fixture): string =
  "PATH=" & quoteShell(fx.binDir & $PathSep & getEnv("PATH")) & " " &
    quoteShell(fx.repro) & " build --tool-provisioning=path --daemon=off"

proc build(fx: Fixture): tuple[code: int; output: string] =
  let res = execCmdEx(fx.buildCommand() & " 2>&1", workingDir = fx.project)
  (code: res.exitCode, output: res.output)

proc requireBuilt(fx: Fixture; label: string;
                  res: tuple[code: int; output: string]) =
  checkpoint(label & ":\n" & res.output)
  check res.code == 0
  check fileExists(fx.output)

# ---------------------------------------------------------------------------
# A private mount, for the layouts that need one.
# ---------------------------------------------------------------------------

proc ids(): tuple[uid, gid: string] =
  when defined(posix):
    ($getuid(), $getgid())
  else:
    ("", "")

proc namespaceReason(): string =
  ## "" when this host lets an unprivileged user mount in a namespace of its
  ## own and map back to its real uid; otherwise why not.
  when not defined(linux):
    return "needs Linux user and mount namespaces"
  else:
    if findExe("unshare").len == 0:
      return "needs unshare(1) for a private mount"
    let (uid, gid) = ids()
    let probe = execCmdEx("unshare -rm sh -c " & quoteShell(
      "mount -t tmpfs tmpfs /dev/shm && exec unshare --map-user=" & uid &
      " --map-group=" & gid & " true") & " 2>&1")
    if probe.exitCode != 0:
      return "this host does not allow an unprivileged user and mount " &
        "namespace (unshare -rm): " & probe.output.strip()
    if not dirExists("/run/lock"):
      return "needs an existing /run/lock to mount a tmpfs on"
    ""

proc bootstrapCompilerEnv(): string =
  ## The recipe compile's C and Nim compilers, named explicitly. Otherwise
  ## they are provisioned through the per-user Nix daemon, which runs OUTSIDE
  ## the namespace and cannot see the private mount the build runs in.
  let cc = findExe("cc")
  let nim = findExe("nim")
  if cc.len > 0:
    result.add("REPRO_BOOTSTRAP_CC=" & quoteShell(cc) & " ")
  if nim.len > 0:
    result.add("REPRO_NIM_COMPILER=" & quoteShell(nim) & " ")

proc buildInNamespace(fx: Fixture; mounts, workDir: string):
    tuple[code: int; output: string] =
  ## `mounts` runs as root of a fresh user and mount namespace; the build
  ## then runs in `workDir`, back under the real uid and gid.
  let (uid, gid) = ids()
  let inner = "cd " & quoteShell(workDir) & " && " & bootstrapCompilerEnv() &
    fx.buildCommand()
  let outer = mounts & " && exec unshare --map-user=" & uid &
    " --map-group=" & gid & " sh -c " & quoteShell(inner)
  let res = execCmdEx("unshare -rm sh -c " & quoteShell(outer) & " 2>&1")
  (code: res.exitCode, output: res.output)

proc devShmUsable(): bool =
  try:
    removeDir(createTempDir("repro-probe-", "", "/dev/shm"))
    true
  except CatchableError, OSError:
    false

suite "a project under a volatile runtime prefix":

  test "a project at /dev/shm/<name> re-runs on a file added to its listed root and on an edit, and a shm object it reads is not an input":
    if not defined(linux) or not devShmUsable():
      skip("needs a writable /dev/shm; this case builds a project on that " &
        "tmpfs")
    else:
      let project = createTempDir("repro-volatile-", "", "/dev/shm")
      # A flat entry of /dev/shm, outside the project: what a POSIX
      # shared-memory object looks like by path.
      let runtimeObject = "/dev/shm/repro-volatile-object-" &
        $getCurrentProcessId()
      writeFile(runtimeObject, "state 1\n")
      let fx = newFixture(project, runtimeObject)
      defer:
        removeDir(fx.scratch)
        removeDir(project)
        removeFile(runtimeObject)

      fx.requireBuilt("first build", fx.build())
      check fx.runs == 1

      # The runtime object changes, as another process's state does. It is
      # outside the project, so it is not an input: still a hit.
      writeFile(runtimeObject, "state 2, longer\n")
      fx.requireBuilt("runtime object changed", fx.build())
      check fx.runs == 1

      # The listing of the project ROOT, `/dev/shm/<name>`, is an input. By
      # path alone it is indistinguishable from a shared-memory object.
      writeFile(project / "added.txt", "new\n")
      fx.requireBuilt("file added to the listed project root", fx.build())
      check fx.runs == 2
      check "added.txt" in readFile(fx.output)

      # An edit of the same length: only the content differs.
      writeFile(project / "src" / "input.txt", "input v2\n")
      fx.requireBuilt("input edited", fx.build())
      check fx.runs == 3
      check "input v2" in readFile(fx.output)

  test "a file the build reads from a dependency checkout under /dev/shm/<dir>, outside every root of the build, is an input":
    # A sibling repository of the workspace, or a dependency checkout, is
    # under none of THIS build's roots (project, repository, work, store,
    # output). It is still a directory of ordinary files: dropping its reads
    # made an edit there a cache hit.
    if not defined(linux) or not devShmUsable():
      skip("needs a writable /dev/shm; this case reads a dependency " &
        "checkout on that tmpfs")
    else:
      let checkout = createTempDir("repro-volatile-dep-", "", "/dev/shm")
      let project = createTempDir("repro-volatile-consumer-", "")
      let depInput = checkout / "lib" / "input.txt"
      createDir(depInput.parentDir)
      writeFile(depInput, "dep v1\n")
      let fx = newFixture(project, read = depInput)
      defer:
        removeDir(fx.scratch)
        removeDir(project)
        removeDir(checkout)

      fx.requireBuilt("first build", fx.build())
      check fx.runs == 1
      fx.requireBuilt("nothing changed", fx.build())
      check fx.runs == 1

      # An edit of the same length in the dependency checkout.
      writeFile(depInput, "dep v2\n")
      fx.requireBuilt("dependency input edited", fx.build())
      check fx.runs == 2
      check "dep v2" in readFile(fx.output)

  test "a project on a mount at /run/<dir> re-runs on an edit and on a file added to its listed root":
    let reason = namespaceReason()
    if reason.len > 0:
      skip(reason)
    else:
      # The files live in an ordinary directory and are seen at
      # `/run/lock/<name>` through a bind mount on a private tmpfs, a stand-in
      # for a disk an administrator mounted under `/run`.
      let backing = createTempDir("repro-volatile-run-", "")
      let fx = newFixture(backing)
      defer:
        removeDir(fx.scratch)
        removeDir(backing)
      let seen = "/run/lock/repro-volatile-project"
      let mounts = "mount -t tmpfs tmpfs /run/lock && mkdir " &
        quoteShell(seen) & " && mount --bind " & quoteShell(backing) & " " &
        quoteShell(seen)

      fx.requireBuilt("first build", fx.buildInNamespace(mounts, seen))
      check fx.runs == 1
      fx.requireBuilt("nothing changed", fx.buildInNamespace(mounts, seen))
      check fx.runs == 1

      writeFile(backing / "src" / "input.txt", "input v2\n")
      fx.requireBuilt("input edited", fx.buildInNamespace(mounts, seen))
      check fx.runs == 2
      check "input v2" in readFile(fx.output)

      writeFile(backing / "added.txt", "new\n")
      fx.requireBuilt("file added to the listed project root",
        fx.buildInNamespace(mounts, seen))
      check fx.runs == 3

  test "a project whose root is /dev/shm itself is refused, naming the root and why, and nothing runs":
    let reason = namespaceReason()
    if reason.len > 0:
      skip(reason)
    else:
      # The project's files ARE the entries of /dev/shm, in a private mount
      # where nothing else lives.
      let backing = createTempDir("repro-volatile-root-", "")
      let fx = newFixture(backing)
      defer:
        removeDir(fx.scratch)
        removeDir(backing)
      let res = fx.buildInNamespace("mount --bind " & quoteShell(backing) &
        " /dev/shm", "/dev/shm")
      checkpoint(res.output)
      check res.code != 0
      check "refusing to build" in res.output
      check "/dev/shm" in res.output
      check "flat namespace of runtime objects" in res.output
      check fx.runs == 0
      check not fileExists(fx.output)
