## A tool, a library or a data file the build reaches through `/run` is an
## input when it is a file, and runtime objects under `/run` (sockets, FIFOs,
## device nodes) are dropped from the evidence, counted, and keep the record
## on this host.
##
## On NixOS the system `PATH` is `/run/current-system/sw/bin`, setuid
## wrappers are `/run/wrappers/bin`, and the GL/CUDA user-space drivers are
## loaded from `/run/opengl-driver/lib`. Every one of them is a symbolic link
## into the store, not runtime state. The volatile-runtime fold used to drop
## every read, exec, library load and probe under `/run` (less
## `/run/user/<uid>`, `/run/media` and the build's own trees) by PREFIX, so
## after a `nixos-rebuild switch` an edge that ran one of those tools kept
## hitting with the old tool's outputs. Now a path under `/run` is judged by
## what it is on disk: a regular file, a directory, a symbolic link or an
## absent path is an ordinary input; only a socket, a FIFO or a device node
## is dropped. Each drop is counted in the action's trace, and a record that
## dropped a runtime object under `/run` read host state no other host has, so
## it is not portable.
##
## The NixOS layout is recreated on a private mount at `/run/lock/<name>`:
## `current` is a symbolic link to `<scratch>/system-v1`, whose `bin/` holds a
## `helper` the edge's tool runs by bare name (the shell finds it on `PATH`
## through the link, as a tool is found under `/run/current-system/sw/bin`)
## and whose `share/` holds a data file the helper reads by an absolute path
## through the link, as a program loads `/run/opengl-driver/lib/<lib>`.
## Switching the link to another system directory is the
## `nixos-rebuild switch`. The edge's own tool lives inside the project, so
## that where it lives does not decide whether the record is portable.
##
## NO MOCKS: the built `repro`, a real provider compile, the real monitor,
## action cache and portable-record computation, read back from the engine's
## own `--write-report` trace. The mount needs a user and mount namespace of
## the test's own (`unshare -rm`, then a nested user namespace mapping back to
## the real uid so the build does not run as root), the arrangement
## `t_a_project_under_a_volatile_prefix_keeps_its_reads` uses; a host that
## does not allow one skips every case with the reason.
##
## Falsifiability:
## * Reverting the fold to the prefix rule (`dropsAsVolatileInput` answering
##   `dropsAsVolatileRuntimeState` alone) fails the switch case: the rebuild
##   after the link moves is a stale hit (`runs` stays put, the output keeps
##   the old generation's text): the exec is recorded at the OLD
##   generation's resolved path, which is still on disk and unchanged, and
##   the link under `/run` it went through was dropped. It also fails the
##   runtime-object case: nothing is counted, nothing is host-bound, and the
##   portable reason names no runtime object. This is what both cases
##   measured against the engine built at `b63ee570f`.
## * Making the file-type probe keep sockets and FIFOs fails the
##   runtime-object case's "dropped and counted" checks (the drop counter and
##   the host-bound reason are gone).
## * Removing the host-bound check from `finishPortableRecord` fails the
##   runtime-object case's portability reason only (the record is not
##   portable on a host whose toolchain is outside every logical root, but
##   the reason no longer names the socket or the FIFO).
## * Removing the trace event (`traceVolatileRuntimeDrops`) fails the counted
##   checks only.

import std/[json, net, os, osproc, strutils, tempfiles, unittest]

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

const
  Seen = "/run/lock/repro-run-profile"
    ## Where the private mount shows the backing directory: the stand-in for
    ## `/run` on NixOS.
  DataThroughRun = Seen & "/current/share/data.txt"
    ## Read by absolute path through the link, as a program reads
    ## `/run/opengl-driver/lib/<lib>`.

const toolInterface = "import repro_project_dsl\n\n" &
  "defineCliInterface runTool, \"run-tool\":\n" &
  "  call:\n" &
  "    flag data is string, alias = \"--data\", required = true\n" &
  "    flag helper is string, alias = \"--helper\", required = true\n" &
  "    flag fifo is string, alias = \"--fifo\", required = true\n" &
  "    flag sock is string, alias = \"--sock\", required = true\n" &
  "    flag output is string, alias = \"--output\", role = output, required = true\n" &
  "    flag marker is string, alias = \"--marker\", required = true\n" &
  "    outputs output\n"

const runTool = "#!/bin/sh\n" &
  "set -eu\n" &
  "if [ \"${1:-}\" = \"--version\" ]; then echo 'run-tool 1.0.0'; exit 0; fi\n" &
  "data= helper= fifo= sock= output= marker=\n" &
  "while [ \"$#\" -gt 0 ]; do\n" &
  "  case \"$1\" in\n" &
  "    --data) data=$2; shift 2 ;;\n" &
  "    --helper) helper=$2; shift 2 ;;\n" &
  "    --fifo) fifo=$2; shift 2 ;;\n" &
  "    --sock) sock=$2; shift 2 ;;\n" &
  "    --output) output=$2; shift 2 ;;\n" &
  "    --marker) marker=$2; shift 2 ;;\n" &
  "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
  "  esac\n" &
  "done\n" &
  "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
  "out=$(cd \"$(dirname \"$output\")\" && pwd)/$(basename \"$output\")\n" &
  "echo 'run-tool' > \"$out\"\n" &
  "if [ \"$helper\" = yes ]; then helper >> \"$out\"; fi\n" &
  "cat \"$data\" >> \"$out\"\n" &
  "if [ \"$fifo\" != none ]; then\n" &
  "  [ -p \"$fifo\" ] && echo 'fifo present' >> \"$out\"\n" &
  "  ls -l \"$fifo\" > /dev/null\n" &
  "fi\n" &
  "if [ \"$sock\" != none ]; then\n" &
  "  [ -S \"$sock\" ] && echo 'socket present' >> \"$out\"\n" &
  "  ls -l \"$sock\" > /dev/null\n" &
  "fi\n" &
  "printf 'ran\\n' >> \"$marker\"\n"
  ## The edge's tool, kept inside the project so that nothing about where
  ## IT lives keeps the record off other hosts. It writes its name, runs
  ## `helper` by bare name when asked (the shell finds it on `PATH`, as a
  ## NixOS tool is found under `/run/current-system/sw/bin`, so the engine
  ## never resolves it and only the monitor sees it run), reads `data`, and
  ## looks at a FIFO and a socket the way a program checks for a daemon's
  ## endpoint: by type, without reading them.

proc helperScript(label: string): string =
  ## The tool in a "system generation", reached through the link. It reads
  ## its data file by absolute path through the link, as a program loads
  ## `/run/opengl-driver/lib/<lib>`.
  "#!/bin/sh\n" &
  "echo " & quoteShell(label) & "\n" &
  "cat " & quoteShell(DataThroughRun) & "\n"

type Fixture = object
  scratch: string   ## everything on disk lives here
  backing: string   ## seen at `Seen` inside the namespace
  project: string
  path: string      ## the `PATH` entries put ahead of the ambient ones
  reports: int
  repro: string

proc marker(fx: Fixture): string = fx.project / ".repro" / "runs.log"
proc output(fx: Fixture): string = fx.project / "build" / "out.txt"

proc runs(fx: Fixture): int =
  if not fileExists(fx.marker):
    return 0
  for line in readFile(fx.marker).splitLines():
    if line == "ran":
      inc result

proc writeSystem(fx: Fixture; name, label, data: string) =
  ## One "system generation": `bin/helper` and `share/data.txt`.
  let root = fx.scratch / name
  writeExecutable(root / "bin" / "helper", helperScript(label))
  createDir(root / "share")
  writeFile(root / "share" / "data.txt", data)

proc switchTo(fx: Fixture; name: string) =
  ## `nixos-rebuild switch`: the link moves to another generation.
  let link = fx.backing / "current"
  if symlinkExists(link):
    removeFile(link)
  createSymlink(fx.scratch / name, link)

proc newFixture(throughRun: bool; fifo = "none"; sock = "none"): Fixture =
  ## `throughRun`: the edge runs `helper` found on `PATH` through
  ## `Seen/current/bin` and reads `DataThroughRun`, the NixOS layout.
  ## Otherwise its data is a project file, so the only paths under `/run`
  ## it touches are the runtime objects.
  result.scratch = createTempDir("repro-run-profile-", "")
  result.backing = result.scratch / "run-backing"
  result.project = result.scratch / "project"
  result.repro = reproBinary()
  createDir(result.backing)
  result.writeSystem("system-v1", "helper v1", "data v1\n")
  result.switchTo("system-v1")
  let tools = result.project / "tools" / "bin"
  writeExecutable(tools / "run-tool", runTool)
  result.path = tools
  if throughRun:
    result.path.add($PathSep & Seen / "current" / "bin")
  createDir(result.project / "src")
  writeFile(result.project / "src" / "data.txt", "project data v1\n")
  let data = if throughRun: DataThroughRun else: "src/data.txt"
  createDir(result.project / "reprobuild" / "packages")
  writeFile(result.project / "reprobuild" / "packages" / "run_tool.nim",
    toolInterface)
  writeFile(result.project / "repro.nim",
    "import repro_project_dsl\n\n" &
    "package runProfileProbe:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"run-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    discard runTool(actionId = \"through-run\",\n" &
    "      data = " & escape(data) & ",\n" &
    "      helper = " & escape(if throughRun: "yes" else: "no") & ",\n" &
    "      fifo = " & escape(fifo) & ",\n" &
    "      sock = " & escape(sock) & ",\n" &
    "      output = \"build/out.txt\",\n" &
    "      marker = \".repro/runs.log\")\n")

# ---------------------------------------------------------------------------
# The private mount.
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
    if not dirExists("/run/lock"):
      return "needs an existing /run/lock to mount a tmpfs on"
    let (uid, gid) = ids()
    let probe = execCmdEx("unshare -rm sh -c " & quoteShell(
      "mount -t tmpfs tmpfs /run/lock && exec unshare --map-user=" & uid &
      " --map-group=" & gid & " true") & " 2>&1")
    if probe.exitCode != 0:
      return "this host does not allow an unprivileged user and mount " &
        "namespace (unshare -rm): " & probe.output.strip()
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

type BuildRun = object
  code: int
  output: string
  report: JsonNode

proc trace(run: BuildRun; event: string): seq[string] =
  ## The details of every `event` the engine traced for the edge.
  if run.report.isNil:
    return
  for entry in run.report{"trace"}.getElems():
    if entry{"actionId"}.getStr() == "through-run" and
        entry{"event"}.getStr() == event:
      result.add(entry{"detail"}.getStr())

proc build(fx: var Fixture): BuildRun =
  ## One `repro build` in a fresh namespace in which `Seen` shows the
  ## backing directory, with the portable identity on (so whether the record
  ## could serve another host is computed and traced) and nothing published
  ## off this host.
  inc fx.reports
  let report = fx.scratch / ("report-" & $fx.reports & ".json")
  let (uid, gid) = ids()
  let mounts = "mount -t tmpfs tmpfs /run/lock && mkdir " & quoteShell(Seen) &
    " && mount --bind " & quoteShell(fx.backing) & " " & quoteShell(Seen)
  let inner = "cd " & quoteShell(fx.project) & " && " &
    bootstrapCompilerEnv() &
    "REPRO_PORTABLE_CACHE=1 REPRO_CACHE_DISABLE=1 " &
    "PATH=" & quoteShell(fx.path & $PathSep & getEnv("PATH")) & " " &
    quoteShell(fx.repro) & " build --tool-provisioning=path --daemon=off " &
    "--measure=trace,cache-evidence --write-report=" & quoteShell(report)
  let outer = mounts & " && exec unshare --map-user=" & uid &
    " --map-group=" & gid & " sh -c " & quoteShell(inner)
  let res = execCmdEx("unshare -rm sh -c " & quoteShell(outer) & " 2>&1")
  result = BuildRun(code: res.exitCode, output: res.output)
  if fileExists(report):
    result.report = parseJson(readFile(report))

proc describe(run: BuildRun): string =
  result = run.output
  for event in ["portable-fingerprint", "portable-fingerprint-unavailable",
                "volatile-runtime-dropped"]:
    for detail in run.trace(event):
      result.add("\n[trace] " & event & ": " & detail)

proc requireBuilt(fx: Fixture; label: string; run: BuildRun) =
  checkpoint(label & ":\n" & run.describe())
  check run.code == 0
  check fileExists(fx.output)

proc notPortableNaming(run: BuildRun; path: string): bool =
  for detail in run.trace("portable-fingerprint-unavailable"):
    if path in detail:
      return true
  false

proc dropCounts(run: BuildRun): tuple[runtimeState, kernelState: int;
                                      hostBound: string] =
  ## The counters of the `volatile-runtime-dropped` event:
  ## `run=<n> kernel=<n>[ host-bound=<path>]`.
  for detail in run.trace("volatile-runtime-dropped"):
    for field in detail.splitWhitespace():
      let eq = field.find('=')
      if eq <= 0:
        continue
      let (name, value) = (field[0 ..< eq], field[eq + 1 .. ^1])
      case name
      of "run": result.runtimeState = parseInt(value)
      of "kernel": result.kernelState = parseInt(value)
      of "host-bound": result.hostBound = value
      else: discard

proc portable(run: BuildRun): bool =
  ## Whether the engine computed a portable identity for the edge.
  run.trace("portable-fingerprint").len > 0

suite "a tool or file reached through /run":

  test "switching the link a PATH tool and a data file are reached through re-runs the edge, and the record stays on this host":
    let reason = namespaceReason()
    if reason.len > 0:
      skip(reason)
    else:
      var fx = newFixture(throughRun = true)
      defer: removeDir(fx.scratch)
      fx.writeSystem("system-v2", "helper v2", "data v1\n")
      fx.writeSystem("system-v3", "helper v2", "data v3\n")

      let first = fx.build()
      fx.requireBuilt("first build", first)
      check fx.runs == 1
      check "helper v1" in readFile(fx.output)
      # Inputs under `/run` that no tracked root names: the record serves
      # this host only, and its LOCAL record names them (the switches below
      # re-run the edge). Which reason the trace gives depends on the host:
      # where the toolchain's own store paths are outside every logical root
      # (as with `--tool-provisioning=path` on NixOS), that is named first.
      check not first.portable
      # An ordinary action that touches no socket, FIFO or device under
      # `/run` is never host-bound: only a runtime object makes it so.
      check first.dropCounts().hostBound == ""
      check first.dropCounts().runtimeState == 0

      fx.requireBuilt("nothing changed", fx.build())
      check fx.runs == 1

      # `nixos-rebuild switch` to a generation whose TOOL differs, the data
      # it reads staying the same.
      fx.switchTo("system-v2")
      fx.requireBuilt("switched to a new tool", fx.build())
      check fx.runs == 2
      check "helper v2" in readFile(fx.output)

      fx.requireBuilt("nothing changed after the switch", fx.build())
      check fx.runs == 2

      # A generation whose tool is byte-identical and whose DATA differs: a
      # driver update under `/run/opengl-driver/lib`.
      fx.switchTo("system-v3")
      fx.requireBuilt("switched to new data", fx.build())
      check fx.runs == 3
      check "data v3" in readFile(fx.output)

  test "a FIFO and a socket under /run the tool looks at are dropped, counted, and keep the record on this host":
    let reason = namespaceReason()
    if reason.len > 0:
      skip(reason)
    else:
      var fx = newFixture(throughRun = false,
        fifo = Seen / "state.fifo", sock = Seen / "daemon.sock")
      defer: removeDir(fx.scratch)
      # Made in the backing directory, so the same objects are there for
      # every build.
      doAssert mkfifo(cstring(fx.backing / "state.fifo"), Mode(0o600)) == 0
      let listener = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
        Protocol.IPPROTO_IP)
      listener.bindUnix(fx.backing / "daemon.sock")
      listener.close()

      let first = fx.build()
      fx.requireBuilt("first build", first)
      check fx.runs == 1
      check "fifo present" in readFile(fx.output)
      check "socket present" in readFile(fx.output)

      # Dropped: an endpoint is not fingerprinted, so nothing about it makes
      # every run a miss.
      fx.requireBuilt("nothing changed", fx.build())
      check fx.runs == 1

      # Counted, and the host state it stood for keeps the record here.
      let counts = first.dropCounts()
      check counts.runtimeState >= 2
      check counts.hostBound in [Seen / "state.fifo", Seen / "daemon.sock"]
      check not first.portable
      check first.notPortableNaming(Seen / "state.fifo") or
        first.notPortableNaming(Seen / "daemon.sock")

      # The project's own data is still an input.
      writeFile(fx.project / "src" / "data.txt", "project data v2\n")
      fx.requireBuilt("data edited", fx.build())
      check fx.runs == 2
      check "project data v2" in readFile(fx.output)
