## Shared fixture for the TC-8e tests: certificate issuance on the real
## ``repro test`` path (Test-Certificates.md §"Issuance", §"Marking a node").
##
## Builds on ``certify_working_tree_fixture``: a real manifest workspace with
## four real git repositories (app → lib-b → lib-c, lib-d), a committed
## ``repro.lock`` in ``app``, a scratch local certificate store and a
## registered daemon signing key. On top of it, ``app`` gets a real
## ``repro.nim`` whose ``build:`` body declares edges through a one-flag typed
## tool (a shell script on ``PATH``), so ``repro test`` runs them through the
## real provider compile, the real build engine and the real filesystem
## monitor. No ``--fixture-from``: this is the workspace path a developer
## runs.
##
## The tool copies ``--input`` to ``--output`` and appends the output path to
## ``.repro/runs.log``, so a test can tell which edges executed. An input whose
## content starts with ``FAIL`` makes it exit 1, which is how a test makes a
## member fail.
##
## Certificates are read back from the scratch store and, where coverage is
## asserted, judged by the production verifier. Nothing is mocked.

import std/[os, strutils]

import repro_test_support
import repro_cas_store
import repro_local_store
import repro_peer_cache
import repro_cli_support
import ./certify_working_tree_fixture

export certify_working_tree_fixture

proc writeExecutable(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

const certToolInterface = "import repro_project_dsl\n\n" &
  "defineCliInterface certTool, \"cert-tool\":\n" &
  "  call:\n" &
  "    flag input is string, alias = \"--input\", role = input, required = true\n" &
  "    flag output is string, alias = \"--output\", role = output, required = true\n" &
  "    flag marker is string, alias = \"--marker\", required = true\n" &
  "    outputs output\n"

proc edgeLine(stem: string): string =
  ## A ``build:`` line binding ``<stem>`` to an edge with action id
  ## ``<stem>`` that copies ``src/<stem>.txt`` to ``build/<stem>-out``.
  "    let " & stem & " = certTool(actionId = \"" & stem & "\",\n" &
    "      input = \"src/" & stem & ".txt\",\n" &
    "      output = \"build/" & stem & "-out\",\n" &
    "      marker = \".repro/runs.log\")\n"

type WorkspaceCertifyFixture* = object
  cf*: CertifyFixture
  binDir*: string

proc app*(fx: WorkspaceCertifyFixture): string = fx.cf.sib.app

proc setupWorkspaceCertifyFixture*(label: string; stems: openArray[string];
                                   buildLines: string;
                                   untrackedStems: openArray[string] = []):
    WorkspaceCertifyFixture =
  ## The TC-8d workspace with ``app`` turned into a project: one edge per
  ## stem, then ``buildLines``. Every file is committed and pushed except the
  ## inputs of ``untrackedStems``, which are left untracked in the working
  ## tree. The committed ``repro.lock`` is the one the TC-8d fixture refreshed
  ## (it pins the siblings; the tool comes from ``PATH``, which no lock
  ## pins), so the project needs no second refresh.
  result.cf = setupCertifyFixture(label)
  result.binDir = result.cf.sib.scratch / "bin"
  writeExecutable(result.binDir / "cert-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'cert-tool 1.0.0'; exit 0; fi\n" &
    "input= output= marker=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --input) input=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    --marker) marker=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    "printf '%s\\n' \"$output\" >> \"$marker\"\n" &
    "case \"$(head -c 4 \"$input\")\" in FAIL) echo \"$input says FAIL\" >&2; exit 1 ;; esac\n" &
    "cp \"$input\" \"$output\"\n")
  let app = result.cf.sib.app
  createDir(app / "src")
  createDir(app / "reprobuild" / "packages")
  writeFile(app / "reprobuild" / "packages" / "cert_tool.nim",
    certToolInterface)
  var body = ""
  for stem in stems:
    writeFile(app / "src" / (stem & ".txt"), stem & " v1\n")
    body.add(edgeLine(stem))
  writeFile(app / "repro.nim",
    "import repro_project_dsl\n\n" &
    "package app:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"cert-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" & body & buildLines)
  # Build outputs and the run log are not part of the content.
  writeFile(app / ".gitignore", ".repro/\nbuild/\n")
  discard result.cf.gitIn(app, "add -A")
  for stem in untrackedStems:
    discard result.cf.gitIn(app, "rm -q --cached " &
      quoteShell("src/" & stem & ".txt"))
  discard result.cf.gitIn(app, "commit -q -m project")
  discard result.cf.gitIn(app, "push -q origin main")

proc reproIn*(fx: WorkspaceCertifyFixture; args: openArray[string]):
    CmdResult =
  ## The built ``repro`` in ``app`` with the tool on ``PATH`` and the daemon
  ## key handed to issuance.
  var env = daemonKeyEnv(fx.cf.daemonKey, certifyKeyId)
  env.add((name: "PATH", value: fx.binDir & $PathSep & getEnv("PATH")))
  var argv = @[fx.cf.sib.repro]
  for arg in args:
    argv.add(arg)
  runShell(shellCommand(argv, env), fx.app)

proc executedOutputs*(fx: WorkspaceCertifyFixture): seq[string] =
  ## The outputs the tool wrote, one per executed edge, in run order.
  let log = fx.app / ".repro" / "runs.log"
  if fileExists(log):
    for line in readFile(log).splitLines():
      if line.strip().len > 0:
        result.add(line.strip())

proc contentNow*(fx: WorkspaceCertifyFixture): string =
  fx.cf.workingTreeContentId(fx.app)

proc certificatesFor*(fx: WorkspaceCertifyFixture; content,
                      name: string): seq[TestCertificate] =
  ## The certificates the scratch store holds for ``content`` whose targets
  ## are exactly ``[name]``.
  for cert in fx.cf.issuedFor(content):
    if cert.targets == @[name]:
      result.add(cert)

proc storedCount*(fx: WorkspaceCertifyFixture): int =
  if not dirExists(fx.cf.certStore / "v1"): return 0
  for path in walkDirRec(fx.cf.certStore / "v1"):
    if path.endsWith(".toml"): inc result

proc commandOutputs*(cert: TestCertificate): seq[string] =
  ## The ``--output`` value of each recorded command, in record order.
  for command in cert.commands:
    let at = command.argv.find("--output")
    if at >= 0 and at + 1 < command.argv.len:
      result.add(command.argv[at + 1])

proc installAsPeerRecord*(fx: WorkspaceCertifyFixture; stem: string): string =
  ## Re-install the action-cache record of edge ``<stem>``'s last execution
  ## through the peer cache's own installer (``installActionBundle``), exactly
  ## as a fetch from a LAN peer installs one. The record's bytes are what this
  ## host recorded, so the edge still hits; what changes is its provenance,
  ## which is what issuance must judge. Returns "" on success, else why not.
  ##
  ## Not a mock: the record is the engine's own (read back from the
  ## dependency-evidence file it writes beside every recorded execution), and
  ## it goes into the real cache root through the production install path. No
  ## second peer process is started, because the property under test is what
  ## the installed record looks like to the next lookup, not the transport.
  var evidence = ""
  for path in walkDirRec(fx.app / ".repro"):
    if path.parentDir.extractFilename == "dependency-evidence" and
        path.extractFilename.startsWith(stem & "-") and
        path.endsWith(".rbar"):
      evidence = path
  if evidence.len == 0:
    return "no dependency-evidence record for " & stem
  let raw = readFile(evidence)
  let record = decodeActionResultRecord(raw.toOpenArrayByte(0, raw.high))
  let root = resolveActionCacheRoot()
  var cas = openCasStore(root)
  defer: cas.close()
  var cache = openActionCache(root / "action-cache", attachShm = false)
  defer: cache.closeShmTier()
  let installed = installActionBundle(cas, cache,
    materializeActionBundle(cas, record))
  if not installed.ok:
    return installed.reason
  ""
