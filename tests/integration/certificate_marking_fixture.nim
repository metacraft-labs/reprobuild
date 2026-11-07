## Shared fixture for the named-certificate tests (Test-Certificates TC-9a,
## Test-Certificates.md §"Marking a node").
##
## Each case writes a real project into a fresh temporary directory: a
## ``repro.nim`` whose ``build:`` body declares edges through a tiny typed
## tool, plus the tool itself as a shell script on ``PATH``. The project is
## driven through the built ``./build/bin/repro``, so every marking goes
## through the real provider compile and the real provider evaluation, and
## the certificate-export table is read back from the stored graph. Nothing
## is mocked.
##
## The tool copies ``--input`` to ``--output`` and appends the output path to
## ``--marker``, so a case can tell which edges a build ran.

import std/[json, os, osproc, strutils, tempfiles]

import repro_test_support

proc certificateReproBinary*(): string =
  ## ``repro`` is a build-graph artifact (``reprobuild.apps.repro``); drive
  ## the built one rather than compiling the CLI at test time.
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeCertTool*(binDir: string) =
  writeExecutable(binDir / "cert-tool",
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
    "cp \"$input\" \"$output\"\n" &
    "printf '%s\\n' \"$output\" >> \"$marker\"\n")

const certToolInterface = "import repro_project_dsl\n\n" &
  "defineCliInterface certTool, \"cert-tool\":\n" &
  "  call:\n" &
  "    flag input is string, alias = \"--input\", role = input, required = true\n" &
  "    flag output is string, alias = \"--output\", role = output, required = true\n" &
  "    flag marker is string, alias = \"--marker\", required = true\n" &
  "    outputs output\n"

proc edgeLine*(binding, stem: string): string =
  ## One ``build:`` line declaring an edge ``<stem>`` that copies
  ## ``src/<stem>.txt`` to ``build/<stem>-out``. Its implicit target name is
  ## ``<stem>-out`` (the output's basename).
  "    let " & binding & " = certTool(actionId = \"" & stem & "\",\n" &
    "      input = \"src/" & stem & ".txt\",\n" &
    "      output = \"build/" & stem & "-out\",\n" &
    "      marker = \".repro/runs.log\")\n"

proc writeCertProject*(projectRoot, packageName: string;
                       stems: openArray[string]; buildLines: string) =
  ## Write a project whose ``build:`` body declares one edge per stem (bound
  ## to a variable of the same name) followed by ``buildLines``.
  createDir(projectRoot / "src")
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "cert_tool.nim",
    certToolInterface)
  var body = ""
  for stem in stems:
    writeFile(projectRoot / "src" / (stem & ".txt"), stem & " v1\n")
    body.add(edgeLine(stem, stem))
  writeFile(projectRoot / "repro.nim",
    "import repro_project_dsl\n\n" &
    "package " & packageName & ":\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"cert-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" & body & buildLines)

proc lineOf*(path, needle: string): int =
  ## 1-based line of the first line of ``path`` containing ``needle``.
  var n = 0
  for line in lines(path):
    inc n
    if needle in line:
      return n
  raise newException(ValueError, needle & " not found in " & path)

type CertFixture* = object
  root*: string
  binDir*: string
  repro*: string

proc newCertFixture*(prefix: string): CertFixture =
  result.root = createTempDir(prefix, "")
  result.binDir = result.root / "bin"
  writeCertTool(result.binDir)
  result.repro = certificateReproBinary()

proc env*(fx: CertFixture): seq[tuple[name, value: string]] =
  @[("PATH", fx.binDir & $PathSep & getEnv("PATH"))]

proc runRepro*(fx: CertFixture; cwd: string; args: openArray[string]):
    tuple[code: int; output: string] =
  ## Run ``repro`` in ``cwd`` with the tool on ``PATH``; stdout and stderr
  ## are merged so a diagnostic can be matched wherever it is printed.
  var command = ""
  for (name, value) in fx.env:
    command.add(name & "=" & quoteShell(value) & " ")
  command.add(quoteShell(fx.repro))
  for arg in args:
    command.add(" " & quoteShell(arg))
  let res = execCmdEx(command & " 2>&1", workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc jsonTail*(output, schemaId: string): JsonNode =
  ## The JSON document a ``--json`` command printed, located by its
  ## ``schemaId`` so progress lines before it do not matter.
  let marker = "{\"schemaId\":\"" & schemaId & "\""
  let start = output.find(marker)
  if start < 0:
    raise newException(ValueError, "no " & schemaId & " document in:\n" &
      output)
  parseJson(output[start .. ^1].strip().splitLines()[0])

proc certificatesList*(fx: CertFixture; projectRoot: string): JsonNode =
  let res = fx.runRepro(projectRoot, ["certificates", "list", "--json",
    "--tool-provisioning=path"])
  if res.code != 0:
    raise newException(ValueError, "repro certificates list failed (exit " &
      $res.code & "):\n" & res.output)
  jsonTail(res.output, "reprobuild.certificates-list.v1")["certificates"]

proc certificatesPlan*(fx: CertFixture; projectRoot: string;
                       args: openArray[string]): JsonNode =
  var full = @["certificates", "plan", "--json", "--tool-provisioning=path"]
  for arg in args:
    full.add(arg)
  let res = fx.runRepro(projectRoot, full)
  if res.code != 0:
    raise newException(ValueError, "repro certificates plan failed (exit " &
      $res.code & "):\n" & res.output)
  jsonTail(res.output, "reprobuild.certificate-plan.v1")["nodes"]

proc names*(nodes: JsonNode): seq[string] =
  for node in nodes:
    result.add(node["name"].getStr())
