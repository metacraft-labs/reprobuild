## Shared fixture for the shared-branch-policy tests (Test-Certificates TC-9b,
## Test-Certificates.md §"Named certificates and the shared branch policy").
##
## Deliberately not a ``t_*.nim`` file, so the suite generator never compiles
## it as a test of its own.
##
## A real workspace directory with two real git repositories side by side:
##
##   <root>/
##     certpolicy/                the SHARED policy package
##       repro.nim                ``package certpolicy``; imports and
##                                re-exports ``policy/team_policy``
##       policy/team_policy.nim   ``import repro_certificates`` and the
##                                ``const`` policies
##     consumer/                  a repository that adopts a policy
##       repro.nim                ``uses: "certpolicy"`` and
##                                ``enactCertificatePolicy <policy>``
##
## The consumer carries no copy of the policy: it reaches it through its
## ``uses:`` entry, which resolves to the sibling package (the ordinary
## workspace-producer import) and pins the package's revision in the
## consumer's ``repro.lock`` like any other dependency. Every case drives the
## built ``./build/bin/repro``: the real provider compile, the real
## ``repro lock refresh`` writer and the real ``repro certificates policy``
## reader. Nothing is mocked.

import std/[json, os, osproc, strutils, tempfiles]

import repro_test_support

proc policyReproBinary*(): string =
  ## ``repro`` is a build-graph artifact (``reprobuild.apps.repro``); drive
  ## the built one rather than compiling the CLI at test time.
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

type
  PolicyRun* = tuple[code: int; output: string]

  PolicyWorkspace* = object
    root*: string        ## the directory holding both repositories
    policyPkg*: string   ## <root>/certpolicy
    consumer*: string    ## <root>/consumer
    repro*: string
    gitBin*: string

const policyPackageRecipe* = "import repro_project_dsl\n" &
  "import ./policy/team_policy\n" &
  "export team_policy\n\n" &
  "package certpolicy:\n" &
  "  build:\n" &
  "    discard aggregate(\"certpolicy-noop\", actions = @[])\n"

proc run*(command: string; cwd: string): PolicyRun =
  let res = execCmdEx(command & " 2>&1", workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git*(ws: PolicyWorkspace; repo: string; args: varargs[string]): string =
  ## A git command in ``repo`` that must succeed; returns its output.
  var command = quoteShell(ws.gitBin) & " -C " & quoteShell(repo)
  for a in args:
    command.add(" " & quoteShell(a))
  let res = run(command, repo)
  doAssert res.code == 0, "git " & @args.join(" ") & " failed in " & repo &
    ":\n" & res.output
  res.output

proc headOf*(ws: PolicyWorkspace; repo: string): string =
  ws.git(repo, "rev-parse", "HEAD").strip()

proc initRepo(ws: PolicyWorkspace; dir: string) =
  createDir(dir)
  discard ws.git(dir, "init", "-q", "-b", "main")
  discard ws.git(dir, "config", "user.email", "tester@example.invalid")
  discard ws.git(dir, "config", "user.name", "Policy Tester")
  discard ws.git(dir, "config", "commit.gpgsign", "false")

proc commitAll*(ws: PolicyWorkspace; repo, message: string) =
  discard ws.git(repo, "add", "-A")
  discard ws.git(repo, "commit", "-q", "-m", message)

proc writePolicyModule*(ws: PolicyWorkspace; body: string;
                        message = "policy") =
  ## Replace the shared package's policy module with ``body`` (after its
  ## ``import repro_certificates``) and commit it.
  writeFile(ws.policyPkg / "policy" / "team_policy.nim",
    "import repro_certificates\n\n" & body)
  ws.commitAll(ws.policyPkg, message)

proc consumerRecipe*(enact: string; certificates: openArray[string]): string =
  ## The consumer's ``repro.nim``: ``uses: "certpolicy"``, the enacted
  ## policy, and one ``certificate`` per name, each over an aggregate of the
  ## same name (no edge needs to run for a lock refresh).
  result = "import repro_project_dsl\n\n" &
    "package consumer:\n" &
    "  uses:\n" &
    "    \"certpolicy\"\n"
  if enact.len > 0:
    result.add("  enactCertificatePolicy " & enact & "\n")
  result.add("  build:\n")
  if certificates.len == 0:
    result.add("    discard aggregate(\"consumer-noop\", actions = @[])\n")
  for name in certificates:
    result.add("    certificate \"" & name & "\", aggregate(\"" & name &
      "\", actions = @[])\n")

proc writeConsumer*(ws: PolicyWorkspace; recipe: string; message = "recipe") =
  writeFile(ws.consumer / "repro.nim", recipe)
  ws.commitAll(ws.consumer, message)

proc newPolicyWorkspace*(label, policyModule, consumer: string;
                         root = ""): PolicyWorkspace =
  ## Both repositories under ``root`` (a fresh temporary directory by
  ## default), each committed once.
  result.root = if root.len > 0: root else: createTempDir("repro-" & label &
    "-", "")
  result.gitBin = findExe("git")
  result.repro = policyReproBinary()
  result.policyPkg = result.root / "certpolicy"
  result.consumer = result.root / "consumer"
  result.initRepo(result.policyPkg)
  createDir(result.policyPkg / "policy")
  writeFile(result.policyPkg / "repro.nim", policyPackageRecipe)
  result.writePolicyModule(policyModule, "seed")
  result.initRepo(result.consumer)
  writeFile(result.consumer / ".gitignore", ".repro/\nbuild/\n")
  result.writeConsumer(consumer, "seed")

proc reproIn*(ws: PolicyWorkspace; cwd: string;
              args: varargs[string]): PolicyRun =
  var command = quoteShell(ws.repro)
  for a in args:
    command.add(" " & quoteShell(a))
  run(command, cwd)

proc refresh*(ws: PolicyWorkspace; repo = ""): PolicyRun =
  ## ``repro lock refresh`` of ``repo`` (the consumer by default).
  let target = if repo.len > 0: repo else: ws.consumer
  ws.reproIn(target, "lock", "refresh", target)

proc lockOf*(repo: string): string =
  let path = repo / "repro.lock"
  if fileExists(path): readFile(path) else: ""

proc policyReport*(ws: PolicyWorkspace; repo: string;
                   branch = ""): tuple[code: int; output: string;
                                       report: JsonNode] =
  ## ``repro certificates policy --json`` in ``repo`` (``--branch`` when
  ## given); ``report`` is the parsed document, or nil.
  let res =
    if branch.len > 0:
      ws.reproIn(repo, "certificates", "policy", "--json", "--branch", branch)
    else:
      ws.reproIn(repo, "certificates", "policy", "--json")
  result.code = res.code
  result.output = res.output
  let start = res.output.find("{\"schemaId\":\"reprobuild.certificate-" &
    "policy-report.v1\"")
  if start >= 0:
    result.report = parseJson(res.output[start .. ^1].strip().splitLines()[0])

proc depLine*(lockBody, name: string): string =
  ## The ``deps`` inline table of ``name``, or "".
  let key = "{ name = \"" & name & "\", path = "
  let at = lockBody.find(key)
  if at < 0: return ""
  let close = lockBody.find('}', at)
  if close < 0: return ""
  lockBody[at .. close]
